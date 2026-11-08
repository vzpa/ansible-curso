# Seguridad

## Secretos

- **Nunca** se guardan contraseñas, tokens ni claves en el repositorio, en variables de ejemplo,
  en logs ni en informes. Las credenciales viven solo en el almacén de credenciales de AWX
  (la credencial "Windows 11").
- No definas `ansible_password` ni similares en variables de inventario, de Job Template o de
  encuesta. Una pregunta de encuesta de tipo *contraseña* se enmascara en AWX; una de tipo texto no.
- Si algún día se añade un secreto, debe llegar por una credencial de AWX, no por `extra vars`.

## Qué contiene el informe

El artefacto `update_manager_report_<host>` y el log del job incluyen: nombre del equipo,
identidad de la conexión (por ejemplo `EQUIPO\usuario`, sin contraseña), build de Windows,
versión y ruta de WinGet, IDs de paquetes, KB y títulos de actualizaciones, códigos de salida,
y las variables de conexión **no sensibles** `ansible_connection`, transporte WinRM, puerto y
si se valida el certificado (`winrm_server_cert_validation`). Trátalo como información interna.

- `reporting_include_raw_output` está en `false`: el artefacto no lleva stdout/stderr crudo de WinGet
  (sí queda en el log del job). Actívalo solo para diagnosticar.
- El `preflight` registra **solo si existe** una política de WSUS, no su URL.
- Quien tenga acceso de lectura al job verá el informe: gestiona los permisos de AWX en consecuencia.

## Control de cambios

- **Confirmación explícita.** `update_windows11.yaml` y los roles rechazan la instalación sin
  `update_manager_confirm: INSTALL` (mayúsculas) y con `--check`.
- **Separación de permisos (recomendado).** En AWX, da *Ejecutar* sobre el Job Template de
  instalación solo a quien deba instalar; el de consulta y el de preflight pueden tener un
  alcance más amplio porque no cambian el equipo.
- **Puertas.** Si `preflight` falla, no se instala nada; si falla `windows_updates`, se omiten
  las aplicaciones. `update_manager_continue_on_failure: true` las salta: úsalo con conocimiento.

## Opciones de riesgo (todas desactivadas por defecto)

| Opción | Riesgo |
|---|---|
| `windows_updates_reboot` | Reinicia el equipo durante el job; puede cortar sesiones y trabajo sin guardar |
| `windows_updates_include_drivers` / `_feature_packs` / `_upgrades` | Cambios de mayor impacto y difíciles de revertir |
| `windows_updates_use_become` | Ejecuta `win_updates` como SYSTEM |
| `application_updates_close_processes` | Cierra apps en ejecución (cierre ordenado) |
| `application_updates_force_close` | `Stop-Process -Force`: **puede perder trabajo sin guardar** |
| `update_manager_continue_on_failure` | Salta las puertas de seguridad entre fases |
| `windows_updates_server_selection` distinto de `default` | Puede eludir WSUS o una política corporativa. Se mantiene `default` salvo evidencia |

## WinGet

- Solo **IDs exactos** (`--id <id> --exact`) y fuente fija (`winget` o `msstore`). Nunca `--all`.
- **Acuerdos de licencia:** las llamadas usan `--accept-source-agreements` y, al actualizar,
  `--accept-package-agreements`. Es decir, el job **acepta en tu nombre** los términos de las
  fuentes y de los paquetes que actualiza. Revisa la lista de aplicaciones sabiendo esto.
- El ID, la fuente y los nombres de proceso se validan con expresiones regulares y se pasan al
  script como **parámetros** (no se interpolan en el texto del script), para evitar que un valor
  se interprete como una opción o un comando.
- La lista de aplicaciones (`application_updates_apps`, `ms_components_ids`) define el alcance
  máximo. Cambiarla es un cambio de código: revísalo en Git.

## Preflight (solo lectura)

Lee versión de PowerShell, identidad, claves del registro de compilación/políticas/reinicio
pendiente, estado de servicios, espacio libre y ejecuta `winget --version`, `winget source list`
y `winget list --count 1`. No inicia ni detiene servicios, no escribe en el equipo (solo los
archivos temporales de WinGet, que elimina) y no instala nada.

## Cadena de suministro

- Usa el EE con etiqueta fija `quay.io/ansible/awx-ee:24.6.1`; evita `latest`.
- No se instalan colecciones en tiempo de ejecución: se usa lo que trae el EE.
- El repositorio es la única fuente de los playbooks; revisa los cambios antes de sincronizar el proyecto.

## Limitaciones y rollback

- **No hay rollback automatizado en Windows.** Si una actualización causa problemas, hay que
  desinstalarla manualmente (por KB) o restaurar desde un punto de restauración o copia.
  Esta guía no los crea ni los comprueba.
- Los cambios del **repositorio** se revierten con `git revert`.
- Nada de esto se ha ejecutado aún contra un Windows real; el comportamiento real de WinGet bajo
  la identidad de AWX y el efecto de cada actualización deben validarse con la primera consulta.

## Higiene del repositorio (sugerido)

Añade a `.gitignore` los artefactos locales (`*.retry`, `*.log`, entornos virtuales) y no subas
salidas de `winget list` completas ni informes con datos internos a repositorios públicos
(`github.com/vzpa/ansible-curso` es un repositorio en GitHub: comprueba que su visibilidad es la deseada).