# windows11-update-manager

Gestor de actualizaciones de un Windows 11 independiente, ejecutado desde **AWX** con Ansible.
Cubre Windows Update, aplicaciones y componentes Microsoft (WinGet) con un flujo
**consulta → confirmación → instalación** y un informe estructurado por job.

> **Estado honesto de la validación.** Todo lo de este repositorio pasó `yamllint`,
> `ansible-playbook --syntax-check` y pruebas con **resultados simulados** (no contra un
> Windows real). Lo que depende de AWX y de Windows (WinGet bajo la identidad de AWX,
> códigos de salida reales, categorías de Windows Update de tu equipo, reinicios) está
> **pendiente de validar** con la primera ejecución real. Ver [Qué está probado](#qué-está-probado).

## Principios

- **Consultar primero.** Cada playbook de instalación exige una confirmación explícita.
- **Nada de `winget upgrade --all`.** Solo IDs exactos de WinGet.
- **Conservador por defecto.** Sin reinicio, sin drivers, sin feature packs, sin upgrades de
  versión, sin cierre de procesos, respetando WSUS/política (`server_selection: default`).
- **Evidencia, no texto.** Se guardan `rc`, stdout y stderr por paso y se verifica el resultado
  después; no se declara éxito por frases localizadas como "Upgraded".
- **Ningún resultado global "correcto" si falla una fase crítica.**
- **Sin secretos en Git, logs ni informes.** Ver [docs/SECURITY.md](docs/SECURITY.md).

## Estructura

```text
ansible-windows11-updates/
├── preflight.yaml              # comprobaciones previas de SOLO LECTURA
├── check_updates.yaml          # consulta (preflight + Windows Update + WinGet), no instala
├── update_windows11.yaml       # instalación; bloqueado sin update_manager_confirm: INSTALL
├── roles/
│   ├── preflight/              # PowerShell efectivo, identidad, SO, servicios, disco, WinGet
│   ├── windows_updates/        # win_updates: consulta, instalación, reinicio, verificación
│   ├── application_updates/    # lista de apps + motor WinGet (tasks/engine.yaml, files/*.ps1)
│   ├── ms_components/          # lista de componentes Microsoft; usa el motor de application_updates
│   └── reporting/              # consolida fases y publica el informe con set_stats
└── docs/
    ├── AWX_SETUP.md
    ├── TROUBLESHOOTING.md
    └── SECURITY.md
```

**Los playbooks están junto a `roles/` a propósito.** Sin `ansible.cfg`, Ansible solo busca roles
en `<carpeta del playbook>/roles`; en una subcarpeta `playbooks/` fallaría con "role not found".
En AWX se seleccionan como `ansible-windows11-updates/<playbook>.yaml`.

## Flujo recomendado

1. **`preflight.yaml`** — demuestra conectividad, versión efectiva de PowerShell, identidad y
   privilegios, y si WinGet funciona bajo esa identidad. No cambia nada.
2. **`check_updates.yaml`** — consulta Windows Update (`state: searched`) y WinGet. No instala ni reinicia.
   Ejecuta `preflight` primero y se detiene si este falla.
3. Revisar el informe. Solo entonces:
4. **`update_windows11.yaml`** con `update_manager_confirm: INSTALL`. Primera vez: limitar el
   alcance (`application_updates_limit_ids`, `ms_components_limit_ids`) y dejar el reinicio apagado.

## Playbooks

| Playbook | Cambia el equipo | Puerta |
|---|---|---|
| `preflight.yaml` | No | — |
| `check_updates.yaml` | No (rechaza modos de instalación y reinicio) | Si `preflight` falla, omite las demás fases |
| `update_windows11.yaml` | Sí | `update_manager_confirm: INSTALL`, sin `--check`; si `preflight` falla no instala nada; si `windows_updates` falla omite las apps |

`update_manager_continue_on_failure: true` salta las puertas (no la confirmación).
Cada fase se puede desactivar: `update_manager_run_preflight`, `..._windows_updates`,
`..._application_updates`, `..._ms_components` (por defecto todas `true`).

## Roles

| Rol | Qué hace | Publica |
|---|---|---|
| `preflight` | 9 comprobaciones de solo lectura (PowerShell, identidad/admin, SO, servicios, reinicio pendiente, disco, políticas de Windows Update, sesión interactiva, WinGet) | `preflight_results`, `preflight_summary` |
| `windows_updates` | Busca; instala solo en modo `install`; reinicio opcional; nueva búsqueda para verificar | `windows_updates_results`, `windows_updates_summary` |
| `application_updates` | Evalúa/actualiza cada app por ID exacto, con timeout propio y verificación posterior | `application_updates_results`, `application_updates_summary` |
| `ms_components` | Igual, para componentes Microsoft. No cierra procesos | `ms_components_results`, `ms_components_summary` |
| `reporting` | Calcula el estado global y publica `update_manager_report_<host>` | artefacto de AWX (`set_stats`) |

El motor de WinGet usa su propio espacio de nombres (`winget_engine_*`) para que una variable de
AWX pensada para una fase no se cuele en otra. **No definas `winget_engine_*` en AWX.**

## Variables principales

| Variable | Defecto | Efecto |
|---|---|---|
| `update_manager_confirm` | (vacío) | Debe ser `INSTALL` para instalar |
| `update_manager_hosts` | `windows` | Grupo/host destino |
| `update_manager_continue_on_failure` | `false` | Salta las puertas de preflight/Windows Update |
| `windows_updates_reboot` | `false` | Reinicio automático |
| `windows_updates_extra_categories` | `[]` | Categorías además de Security, Critical, Definition y Rollups |
| `windows_updates_include_drivers` / `_feature_packs` / `_upgrades` | `false` | Opt-in explícito |
| `windows_updates_use_become` | `false` | Ejecutar `win_updates` como SYSTEM si la tarea programada falla |
| `windows_updates_log_path` | vacío | Log del módulo en Windows (opcional) |
| `application_updates_limit_ids` / `ms_components_limit_ids` | `[]` | Limitar a estos IDs |
| `application_updates_close_processes` / `_force_close` | `false` | Cierre ordenado / forzado de procesos (opt-in) |
| `preflight_require_winget` | `false` | Si `true`, que WinGet no funcione es un fallo |
| `preflight_min_free_gb` | `10` | Espacio libre mínimo en la unidad del sistema |
| `reporting_include_raw_output` | `false` | Incluir stdout/stderr crudo en el artefacto |

Las listas de apps y componentes están en `roles/application_updates/defaults/main.yaml` y
`roles/ms_components/defaults/main.yaml`, con IDs tomados de tu `winget list`.

## Resultado global del informe

| Estado | Cuándo |
|---|---|
| `correcto` | Hay evidencia, todas las fases ejecutadas están `ok` y no falta ninguna fase requerida |
| `parcial` | Alguna fase terminó `partial`, o falló una fase no crítica |
| `fallido` | Falla una fase crítica (`preflight`, `windows_updates`), falta una fase requerida, el playbook registró un fallo, o no hay ninguna evidencia |

Si el resultado es `fallido`, el job termina como `failed` **después** de publicar el informe.
El informe está en el log del job ("INFORME update-manager") y en el artefacto
`update_manager_report_<host>`.

## Qué está probado

| Prueba | Estado |
|---|---|
| `yamllint` y `--syntax-check` de los 5 roles y 3 playbooks (ansible-core 2.15, `ansible.windows` 2.4.0) | Hecho |
| Sintaxis de los 2 scripts PowerShell y ausencia de construcciones exclusivas de PowerShell 7 | Hecho (con PowerShell 7 como parser; **no** es un intérprete 5.1) |
| Guardas de confirmación y de entrada | Hecho |
| Lógica de resumen, puertas y `reporting` con resultados **simulados** | Hecho |
| Scripts PowerShell contra un `winget` falso en Linux (ramas de decisión) | Hecho; no valida los códigos reales de WinGet |
| `winget` y permisos bajo la identidad de AWX; códigos de salida reales | **Pendiente (AWX + Windows)** |
| Categorías reales de Windows Update, instalación y reinicio | **Pendiente (AWX + Windows)** |
| Carpeta `tests/` automatizada en el repo | No creada |

## Migración desde el proyecto heredado

| Antes | Ahora |
|---|---|
| `playbook.yaml` | `check_updates.yaml` / `update_windows11.yaml` |
| `vars.yaml` → `winget_apps` (nombres) | `application_updates_apps` (IDs exactos) |
| `vars.yaml` → `ms_components` | `ms_components_ids` |
| `vars.yaml` → `log_path` | `windows_updates_log_path` (opcional) |
| `vars.yaml` → `report_file` | Eliminado: el informe va a los artefactos del job |
| `roles/winget_updates/` | `roles/application_updates/` |
| `roles/reporting/main.yaml` | `roles/reporting/tasks/main.yaml` |

Eliminar `playbook.yaml`, `vars.yaml` y `roles/winget_updates/` **solo después** de una consulta
real satisfactoria. Hasta entonces, el Job Template antiguo ("Actualizar windows 11") apunta al
playbook heredado, que instala y reinicia: no lo ejecutes.

## Rollback

Los cambios del repositorio se revierten con `git revert`. Las actualizaciones ya instaladas en
Windows **no** tienen rollback automatizado (ver [docs/SECURITY.md](docs/SECURITY.md)).