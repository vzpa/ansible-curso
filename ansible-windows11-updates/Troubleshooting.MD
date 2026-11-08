# Resolución de problemas

Método: **síntoma → evidencia → prueba → interpretación → mitigación**. No concluyas "es WinGet",
"es WinRM" o "el job fue correcto" solo porque un comando devolvió texto: apóyate en la conexión,
los privilegios, el resultado estructurado, el código de salida y el estado posterior.

Dónde está la evidencia: el log del job ("INFORME update-manager"), el artefacto
`update_manager_report_<host>` y, con `reporting_include_raw_output: true`, el stdout/stderr crudo.
Cada app de WinGet muestra en el informe una línea `rc: before=… check=… upgrade=… after=… post_check=… | before_state=… check_state=… post_state=…`.

## Antes de ejecutar

| Síntoma | Evidencia | Interpretación / acción |
|---|---|---|
| El editor (VS Code) marca `Incorrect type. Expected one of array, null. yaml-schema: Ansible Tasks Schema` en un archivo | Solo aparece en el editor, no en `ansible-playbook` | El esquema de *tareas* se aplicó a un archivo que no lo es (p. ej. un `defaults/main.yaml` guardado en `tasks/`). Revisa la ruta del archivo. No afecta a AWX |
| `the role 'preflight' was not found` | Error al cargar el playbook | El playbook no está junto a `roles/` y no hay `ansible.cfg`. Mantén los playbooks en la raíz del proyecto |
| El playbook no aparece en AWX | Lista de playbooks del Job Template | Sincroniza el proyecto `curso` y revisa que el archivo esté en la rama configurada |
| `Instalación bloqueada: define update_manager_confirm: INSTALL` | Fallo del primer paso, sin cambios en el equipo | Comportamiento esperado: escribe `INSTALL` en mayúsculas y no uses `--check` |
| `check_updates.yaml es solo de consulta` | Fallo del primer paso | Se pasó un modo de instalación o `windows_updates_reboot`. Usa `update_windows11.yaml` |
| `Entrada inválida` / `Lista de aplicaciones inválida` | Mensaje del `assert` | Una lista llegó como cadena (encuesta de texto), hay IDs vacíos/duplicados, un ID de `*_limit_ids` que no está en la lista, o `verify_paths` definido como cadena en vez de lista |

## Preflight

| Comprobación | Si falla o advierte | Qué probar |
|---|---|---|
| `powershell` | Versión < 5.1 | Ver `data.version`/`edition`. El módulo de Ansible usa el intérprete de la conexión, no el de tu sesión local |
| `identity_admin` (**fail**) | La identidad de la credencial no es administradora | `win_updates` exige el grupo Administradores. Comprueba el usuario de la credencial; no se cambia WinRM ni la credencial desde este proyecto |
| `os` (warn) | Build < 22000 | No es Windows 11. Ojo: `ProductName` puede decir "Windows 10" en Windows 11; la referencia es el número de build |
| `services` (**fail**) | `wuauserv` deshabilitado o inexistente | Un `wuauserv` *detenido* con inicio Manual/Automático es normal (arranca bajo demanda). Solo falla si está deshabilitado |
| `pending_reboot` (warn) | `CBS` o `WindowsUpdate` piden reinicio | Reinicia antes de instalar, o acepta que quedará `partial`. `PendingFileRenameOperations` solo se informa |
| `disk_free` (**fail**) | Menos de `preflight_min_free_gb` GB | Libera espacio o baja el umbral conscientemente |
| `update_policy` (warn) | `DisableWindowsUpdateAccess = 1` | Una política bloquea Windows Update. No se evade (`server_selection: default`) |
| `winget` (warn/**fail**) | No encontrado, `rc` distinto de 0 o timeout | Mira `data.version_call`, `source_list_call` y `probe_call` (rc, stdout, stderr). Ver sección WinGet |

Si el estado es `failed`, `check_updates` y `update_windows11` **omiten las demás fases**
(`update_manager_continue_on_failure: true` lo salta; en instalación úsalo con cuidado).

## Windows Update

| Síntoma | Evidencia | Interpretación / acción |
|---|---|---|
| `search_failed` | `msg` del módulo en el log | Causa habitual: servicio, política/WSUS, o la API de Windows Update que no funciona con inicio de sesión de red. Prueba `windows_updates_use_become: true` (ejecuta como SYSTEM) y revisa el log (`windows_updates_log_path`) |
| Un `HRESULT` como `0x80070005` | `failure_hresult_code` de la actualización | Suele indicar acceso denegado: identidad/become. Interprétalo con el código real del log; no se asume el motivo |
| `found: 0` pero esperabas actualizaciones | `filtered` y `filtered_titles` en el resumen; filas `filtered` en el informe | `found` solo cuenta lo que pasa el filtro. Los drivers y demás categorías fuera de alcance aparecen como `filtered` (informativas). Revisa `categories` y `server_selection` |
| Estado `partial` con `reboot_required` | `summary.reboot_required` | Faltan reinicio y verificación. Con `windows_updates_reboot: false` es esperado |
| `remaining_updates:N` tras instalar | Nueva búsqueda tras instalar | Se publicó algo nuevo o la actualización quedó pendiente de reinicio. Repite la consulta |
| Job cortado durante un reinicio | Log del job | Revisa `windows_updates_reboot_timeout` y los timeouts de WinRM del inventario; después ejecuta la consulta y compara el estado |

### Drivers (instalación puntual)

Los drivers están desactivados por defecto. Para consultarlos o instalar uno concreto:

- Consulta: `windows_updates_include_drivers: true` y `windows_updates_skip_optional: false` (el rol exige esa pareja).
- Instalación de UN driver: añade `update_manager_confirm: INSTALL` y `windows_updates_accept_list` con el título.
- **`accept_list` trata cada entrada como EXPRESIÓN REGULAR.** Un título con paréntesis o puntos escrito literal no coincide (job 181: instaló 0). Escápalos y usa comillas simples: `'^Microsoft Corporation AudioProcessingObject Driver Update \(1\.0\.4\.55794\)$'` (job 182: instaló 1).
- Los drivers no suelen traer KB: el informe los identifica por título. Nunca instales "todos los drivers" sin mirar antes qué hardware tienes.
- Un driver de AMD de 2017 en un equipo sin dispositivo de audio AMD activo no tiene a qué aplicarse: se descarta tras comparar con el hardware real.

## WinGet (aplicaciones y componentes Microsoft)

| Clasificación | Qué significa | Qué probar |
|---|---|---|
| `winget_not_found` | `winget.exe` no existe para esa identidad/sesión | Mira el `preflight`. Bajo una sesión no interactiva, WinGet (MSIX) puede no estar disponible; las fases de apps no funcionarán hasta resolverlo |
| `not_installed` (en la primera consulta) | `winget list --id <id> --exact` no encontró el paquete | Bajo la identidad de AWX `winget list` puede ver menos apps que tu sesión (p. ej. instaladas solo para tu usuario). Compara con tu `winget list` |
| `other_rc` | Código de salida inesperado | Mira `before/check/upgrade` (rc, stdout, stderr). Consulta el significado con `winget error 0x<código en hex>` (solo lectura). Ejemplo real: `0x8A15008E` = `UPDATE_INSTALL_TECHNOLOGY_MISMATCH` (EpicOnlineServices: el paquete ofrece otro tipo de instalador que el actual; no se actualiza por WinGet sin reinstalar) |
| `timeout` | Se excedió `*_timeout_seconds` | Súbelo con criterio. Al vencer se mata solo `winget`; un instalador hijo podría seguir corriendo |
| `still_outdated` | `upgrade` devolvió `rc 0` pero la verificación posterior aún ve actualización | Dos causas vistas: (1) la app estaba **abierta** (ChatGPT: al cerrarla se actualizó en la siguiente ejecución); (2) desajuste de esquema de versión del manifiesto (Google.PlayGames: `26.x` instalada vs `157.x` ofrecida; nunca converge). Reintenta con la app cerrada; si persiste, exclúyela con nota |
| `upgrade_not_applicable` | `winget upgrade` devolvió `-1978335189`: la versión que lista `--upgrade-available` no aplica a este sistema | Reproducible en tu sesión interactiva (Baidu.TeraBox, Perplexity.Comet). No es un fallo de AWX. Exclúyelas con nota en `application_updates_apps` |
| `upgrade_unverified` | `rc 0` pero la verificación posterior dio un código inesperado | Revisa `post_check` y repite la consulta |
| `verify_failed` | `upgrade` terminó bien y WinGet ya no lo ve pendiente, pero **falta algún archivo declarado en `verify_paths`** | El paquete cambió pero el programa puede no abrir. Caso real: Epic Games Launcher (job 175) quedó sin `Portal\Binaries\Win64\EpicGamesLauncher.exe` y no abría. Reparación manual (decisión tuya): `winget install --id <id> --exact --source winget --force` con la app cerrada. No hay reparación automática |
| `blocked_by_process` | Hay procesos de la app vivos tras el cierre ordenado | Cierra la app o, bajo tu responsabilidad, `application_updates_force_close: true` (puede perder trabajo sin guardar) |
| `script_error` | El script o el módulo cayó | Mira `error` en el informe y el log |
| ID duplicado (p. ej. `Microsoft.WindowsAppRuntime.1.7` aparece varias veces) | `--exact` puede ser ambiguo | Revisa `winget list --id <id>` en el equipo y decide si mantenerlo en la lista |
| App con id `ARP\...` o `MSIX\...` en `winget list` | WinGet no la correlaciona con un paquete | No se puede gestionar por ID de WinGet; está fuera de la lista a propósito |

Detección: con winget v1.29, `list --upgrade-available --id X --exact` devuelve `rc 0` aunque no haya coincidencias. El script decide por la presencia de una **fila con el ID exacto** en stdout, no por el rc ni por texto localizado.

### `verify_paths` (verificación de archivos tras actualizar)

Cada app de la lista puede declarar rutas que deben existir tras el upgrade, por ejemplo:

```yaml
- id: EpicGames.EpicGamesLauncher
  verify_paths:
    - '%ProgramFiles%\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe'
```

Reglas: lista (no cadena), rutas absolutas, sin comodines; se admiten variables de entorno. Solo se comprueban **después de un upgrade exitoso**. Epic Games Launcher está comentado de `application_updates_apps` mientras no se sepa por qué la actualización silenciosa lo dejó incompleto: se actualiza desde el propio launcher.

## Informe

| Síntoma | Interpretación |
|---|---|
| Resultado `fallido` aunque las apps están bien | Falló una fase **crítica** (`preflight` o `windows_updates`), faltó una fase requerida, o el playbook registró un fallo. Mira "Fases críticas con fallo" y "Fases requeridas sin resumen" |
| `Fases requeridas SIN resumen: …` | Esa fase no llegó a publicar su resumen: se omitió por una puerta o un rol abortó. Mira "Fallo registrado por el playbook" |
| Resultado `parcial` | Alguna fase terminó `partial` (p. ej. WinGet no disponible en preflight, apps con problemas, reinicio pendiente) |
| En Windows Update veo un GUID en vez del título | Versión anterior de `summarize.yaml`. Desde 2026-11-08 el informe muestra el KB si existe y, si no (drivers), el título |
| No encuentro el artefacto | Busca `update_manager_report_<host>`; el nombre sustituye caracteres no alfanuméricos del host por `_` |

## Qué no concluir

- Que WinGet "funciona" porque exista en tu sesión interactiva: lo que cuenta es el `preflight` bajo la identidad de AWX.
- Que una actualización se instaló solo porque el `rc` fue 0: debe confirmarlo la verificación posterior; y para apps delicadas, la existencia de sus archivos (`verify_paths`).
- Que `wuauserv` detenido es un fallo: arranca bajo demanda.
- Que un resultado `correcto` de una consulta equivale a permiso para instalar: la instalación exige su propia confirmación.