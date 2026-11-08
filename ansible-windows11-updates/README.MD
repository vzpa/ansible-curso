# windows11-update-manager

Gestor de actualizaciones de un Windows 11 independiente, ejecutado desde **AWX** con Ansible.
Cubre Windows Update, aplicaciones y componentes Microsoft (WinGet) con un flujo
**consulta → confirmación → instalación** y un informe estructurado por job.

> **Estado de la validación (actualizado 2026-11-08).** El proyecto se probó en un AWX real contra
> un Windows 11 real (VZPAW11) con consultas, instalaciones limitadas y una instalación de driver.
> Lo que NO se ha probado en real (reinicio automático, cierre de procesos, la rama de fallo de
> `verify_paths`, categorías extra, etc.) está marcado en [Qué está probado](#qué-está-probado).

## Principios

- **Consultar primero.** Cada playbook de instalación exige una confirmación explícita.
- **Nada de `winget upgrade --all`.** Solo IDs exactos de WinGet.
- **Conservador por defecto.** Sin reinicio, sin drivers, sin feature packs, sin upgrades de
  versión, sin cierre de procesos, respetando WSUS/política (`server_selection: default`).
- **Evidencia, no texto.** Se guardan `rc`, stdout y stderr por paso y se verifica el resultado
  después; no se declara éxito por frases localizadas como "Upgraded".
- **Un `rc 0` no basta.** Tras actualizar se vuelve a consultar WinGet y, si la app declara
  `verify_paths`, se comprueba que sus archivos existan.
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
4. **`update_windows11.yaml`** con `update_manager_confirm: INSTALL`. Para una app concreta, limitar
   con `application_updates_limit_ids` y **cerrar antes esa app** (una app abierta puede dejar el
   upgrade a medias: `still_outdated`). Dejar el reinicio apagado salvo que se decida lo contrario.

### Uso mensual

| Paso | Plantilla de AWX | Extra vars |
|---|---|---|
| 1. Consultar | WU Manager - Consulta | ninguna |
| 2. Si hay pendientes, cerrar las apps abiertas y continuar | WU Manager - Instalacion | `update_manager_confirm: INSTALL` |
| 3. Leer el informe | — | lo que no esté en `upgraded` o `up_to_date` necesita atención |

La guía de todas las extra vars (con ejemplos, riesgo y estado de verificación) está en el
libro `guia_extra_vars_windows11_update_manager.xlsx` que se entrega aparte.

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
| `windows_updates` | Busca; instala solo en modo `install`; reinicio opcional; nueva búsqueda para verificar. Las actualizaciones que el catálogo ofrece pero el alcance descarta (p. ej. drivers) salen como filas `filtered` | `windows_updates_results`, `windows_updates_summary` |
| `application_updates` | Evalúa/actualiza cada app por ID exacto, con timeout propio, verificación posterior y `verify_paths` opcional | `application_updates_results`, `application_updates_summary` |
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
| `windows_updates_include_drivers` / `_feature_packs` / `_upgrades` | `false` | Opt-in explícito. Con drivers, `windows_updates_skip_optional` debe ser `false` |
| `windows_updates_accept_list` / `_reject_list` | `[]` | Filtra por título o KB. **Cada entrada es una expresión regular**: escapa `(`, `)` y `.` y usa comillas simples |
| `windows_updates_use_become` | `false` | Ejecutar `win_updates` como SYSTEM si la tarea programada falla |
| `windows_updates_log_path` | vacío | Log del módulo en Windows (opcional) |
| `application_updates_limit_ids` / `ms_components_limit_ids` | `[]` | Limitar a estos IDs |
| `application_updates_close_processes` / `_force_close` | `false` | Cierre ordenado / forzado de procesos (opt-in) |
| `preflight_require_winget` | `false` | Si `true`, que WinGet no funcione es un fallo |
| `preflight_min_free_gb` | `10` | Espacio libre mínimo en la unidad del sistema |
| `reporting_include_raw_output` | `false` | Incluir stdout/stderr crudo en el artefacto (solo en el artefacto, no en el log) |

Las listas de apps y componentes están en `roles/application_updates/defaults/main.yaml` y
`roles/ms_components/defaults/main.yaml`, con IDs tomados de tu `winget list`.

### Apps de la lista con `verify_paths`

Cada app puede declarar archivos que deben existir tras actualizar:

```yaml
- id: Ejemplo.App
  verify_paths:
    - '%ProgramFiles%\Ejemplo\app.exe'
```

Si falta alguno, la app queda como `verify_failed` (entra en los problemas). No hay reparación
automática: reinstalar es decisión del operador.

### Apps excluidas a propósito (con nota en el defaults)

| App | Motivo |
|---|---|
| `Baidu.TeraBox`, `Perplexity.Comet` | `upgrade_not_applicable` (`-1978335189`): WinGet las lista pero la versión no aplica al sistema |
| `EpicGames.EpicOnlineServices` | `0x8A15008E` `UPDATE_INSTALL_TECHNOLOGY_MISMATCH`; lo gestiona Epic Games Launcher |
| `Google.PlayGames` | Desajuste de esquema de versión (26.x instalada vs 157.x ofrecida): el upgrade devuelve 0 y no cambia nada |
| `EpicGames.EpicGamesLauncher` | La actualización silenciosa por WinGet lo dejó sin su `.exe` principal (job 175); se actualiza desde el propio launcher |

## Clasificaciones por app

| Clasificación | Significado |
|---|---|
| `up_to_date` / `update_available` | Al día / hay versión nueva (consulta) |
| `upgraded` | Se actualizó y la verificación posterior lo confirmó |
| `still_outdated` | `rc 0` pero sigue pendiente (app abierta o desajuste de versiones) |
| `upgrade_not_applicable` | La versión ofrecida no aplica a este sistema |
| `verify_failed` | Se actualizó pero falta un archivo declarado en `verify_paths` |
| `other_rc`, `timeout`, `blocked_by_process`, `not_installed`, `winget_not_found`, `script_error` | Ver [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |

## Resultado global del informe

| Estado | Cuándo |
|---|---|
| `correcto` | Hay evidencia, todas las fases ejecutadas están `ok` y no falta ninguna fase requerida |
| `parcial` | Alguna fase terminó `partial`, o falló una fase no crítica |
| `fallido` | Falla una fase crítica (`preflight`, `windows_updates`), falta una fase requerida, el playbook registró un fallo, o no hay ninguna evidencia |

Si el resultado es `fallido`, el job termina como `failed` **después** de publicar el informe.
El informe está en el log del job ("INFORME update-manager") y en el artefacto
`update_manager_report_<host>`. Cada app de WinGet incluye una línea
`rc: before=… check=… upgrade=… after=… post_check=…` con los códigos de salida reales.

## Qué está probado

| Prueba | Estado |
|---|---|
| `yamllint` y `--syntax-check` de los roles y playbooks (ansible-core 2.15, `ansible.windows` 2.4.0) | Hecho |
| Guardas de confirmación y de entrada | Hecho |
| Preflight, consulta e informe en AWX contra el Windows 11 real | **Hecho (real)** |
| Detección de pendientes por fila de ID de WinGet (WinGet v1.29 devuelve `rc 0` sin coincidencias) | **Hecho (real)** |
| Actualización de apps con WinGet por ID exacto bajo la identidad de AWX (7zip, Epic Games Launcher, Telegram, ChatGPT) | **Hecho (real)**. Con ChatGPT: falló con la app abierta (`still_outdated`) y funcionó con la app cerrada |
| Instalación puntual de un driver con `windows_updates_accept_list` (regex escapada) | **Hecho (real)** |
| Filas `filtered` y títulos de drivers en el informe | **Hecho (real)** |
| Componentes Microsoft en modo upgrade | Hecho (real) solo con todo al día; sin actualización pendiente real |
| `verify_paths` / `verify_failed` | Sintaxis hecha; la rama de fallo y la de éxito **no se han ejercitado en real** (ninguna app de la lista lo declara hoy) |
| Reinicio automático (`windows_updates_reboot`) | **No probado** |
| Cierre de procesos ordenado y forzado | **No probado** (y es probable que el cierre ordenado no funcione con apps de otra sesión) |
| `server_selection` distinto de `default`, categorías extra, `reject_list`, feature packs, upgrades | **No probado** |
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

Eliminar `playbook.yaml`, `vars.yaml` y `roles/winget_updates/` **solo después** de comprobar que no
los usa ningún Job Template. El Job Template antiguo ("Actualizar windows 11"), si sigue
existiendo, apunta al playbook heredado, que instala y reinicia: no lo ejecutes.

## Rollback

Los cambios del repositorio se revierten con `git revert`. Las actualizaciones ya instaladas en
Windows **no** tienen rollback automatizado (ver [docs/SECURITY.md](docs/SECURITY.md)). Un driver
mal instalado se revierte desde el Administrador de dispositivos.
#sync w11 & linux