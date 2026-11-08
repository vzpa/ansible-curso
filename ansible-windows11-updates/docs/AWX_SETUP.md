# Configuración en AWX

Guía para crear los Job Templates sobre lo que ya tienes funcionando. **No se cambia** la
conectividad (WinRM), las credenciales ni los Execution Environments existentes.

Datos del entorno tomados de tu Job Template actual "Actualizar windows 11":

| Elemento | Valor |
|---|---|
| Organización | Mi Empresa |
| Inventario | `windows` (el playbook usa por defecto el grupo `windows`) |
| Proyecto | `curso` |
| Entorno de ejecución | AWX EE (24.6.1) — `quay.io/ansible/awx-ee:24.6.1` |
| Credencial | "Windows 11" (tipo Machine; AWX la muestra como `SSH: Windows 11`) |

> Verifica con tu propio AWX los nombres exactos de campos y pestañas; esta guía se basa en la
> captura de tu Job Template y en el comportamiento general de AWX, y puede variar con la versión.

## Antes de empezar

1. Sube el repositorio con estos archivos a `https://github.com/vzpa/ansible-curso` (rama `main`).
2. En AWX, **sincroniza el proyecto `curso`**. Los playbooks nuevos aparecerán como
   `ansible-windows11-updates/preflight.yaml`, `.../check_updates.yaml` y `.../update_windows11.yaml`.
3. Confirma que el EE asignado es el 24.6.1 (no `latest`: una etiqueta móvil puede cambiar las
   versiones de las colecciones). El contexto del proyecto indica que trae `ansible-core 2.15.12`
   y `ansible.windows 2.4.0`, versiones con las que se probó la sintaxis.

## Job Templates

Crea tres, copiando el que ya funciona y cambiando solo el nombre y el playbook.

| Orden | Nombre sugerido | Playbook | Cambia el equipo |
|---|---|---|---|
| 1 | `WU Manager - Preflight` | `ansible-windows11-updates/preflight.yaml` | No |
| 2 | `WU Manager - Consulta` | `ansible-windows11-updates/check_updates.yaml` | No |
| 3 | `WU Manager - Instalacion` | `ansible-windows11-updates/update_windows11.yaml` | **Sí** |

Mismos valores para los tres: inventario `windows`, proyecto `curso`, EE 24.6.1, credencial
"Windows 11", nivel de detalle 1. Deja las variables vacías (`---`).

Recomendaciones para el 3.º: activa "Solicitar al ejecutar" (prompt on launch) en *Variables* y
*Límite*, añade una encuesta (abajo) y define un **tiempo de espera** distinto de 0 (por ejemplo
3600 s o más si autorizas reinicios) para que un job colgado no quede indefinido.
Restringe el rol *Ejecutar* de ese template solo a quien deba instalar.

## Orden de las primeras ejecuciones

1. **Preflight.** Mira el informe: PowerShell efectivo (¿5.1?), identidad y `is_admin`, build de
   Windows, versión y ruta de WinGet, y el estado de cada comprobación.
2. **Consulta.** Revisa windows_updates (`found`, categorías de cada actualización) y qué apps
   salen `update_available`, `not_installed` o con problemas.
3. **Comparte el resultado** (sin secretos) antes de habilitar la instalación.
4. **Instalación**, primera vez con alcance mínimo:
   - `update_manager_confirm: INSTALL`
   - `application_updates_limit_ids` y `ms_components_limit_ids` con 1–2 IDs
   - `windows_updates_reboot: false`
5. Cuando funcione, amplía el alcance. Activa el reinicio solo con una consulta previa correcta.

## Encuesta del Job Template de instalación (sugerida)

| Variable | Tipo de pregunta | Defecto | Nota |
|---|---|---|---|
| `update_manager_confirm` | Texto | (vacío) | Hay que escribir `INSTALL` |
| `windows_updates_reboot` | Opción múltiple | `false` | `true`/`false` |
| `windows_updates_include_drivers` | Opción múltiple | `false` | Opt-in |
| `update_manager_run_windows_updates` | Opción múltiple | `true` | Desactivar fases |
| `update_manager_run_application_updates` | Opción múltiple | `true` | |
| `update_manager_run_ms_components` | Opción múltiple | `true` | |
| `update_manager_continue_on_failure` | Opción múltiple | `false` | Salta las puertas |

**Listas (IDs).** `application_updates_limit_ids` y `ms_components_limit_ids` deben llegar como
**lista**. Una pregunta de tipo texto/área de texto entrega una *cadena* y el rol la rechaza con
"Entrada inválida". Pásalas como YAML en *Variables al ejecutar*:

```yaml
---
update_manager_confirm: INSTALL
application_updates_limit_ids:
  - 7zip.7zip
ms_components_limit_ids:
  - Microsoft.Edge
```

(o con una pregunta de *opción múltiple, selección múltiple* con los IDs predefinidos).

## Dónde ver el resultado

- **Log del job:** bloque "INFORME update-manager" con el resultado global y el estado por fase.
- **Artefactos:** variable `update_manager_report_<host>` (campo `artifacts` del job en la API y,
  según tu versión de AWX, en la vista de detalles). Sirve también como entrada de un workflow.
- Si el resultado global es `fallido`, el job termina `failed` después de publicar el informe.

## Reinicios y jobs largos

- `windows_updates_reboot: true` hace que `win_updates` reinicie y espere la reconexión
  (`windows_updates_reboot_timeout`, 1200 s por defecto). No se combina con `async`.
- Si un job largo se corta por timeouts de WinRM, revisa en las variables del inventario
  `ansible_winrm_operation_timeout_sec` y `ansible_winrm_read_timeout_sec`. **No se modifican
  desde este proyecto**; cámbialos solo con evidencia de que son la causa.
- Tras un reinicio, el rol hace una nueva búsqueda y deja el estado `partial` si quedan
  actualizaciones o reinicio pendiente.

## Job Template heredado

"Actualizar windows 11" apunta a `ansible-windows11-updates/playbook.yaml`, que instala y reinicia
sin confirmación. Mantenlo sin ejecutar y elimínalo cuando la consulta nueva esté validada.