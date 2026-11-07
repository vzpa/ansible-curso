# Windows 11 Update Manager — versión corregida

Proyecto Ansible/AWX para consultar y actualizar Windows Update y aplicaciones WinGet por ID exacto. Diseñado para AWX EE 24.6.1 y `ansible.windows.win_powershell` / `win_updates`.

> **Seguridad:** `check_updates.yaml` es de solo consulta. `update_windows11.yaml` exige `update_manager_confirm: INSTALL`. No ejecuta `winget upgrade --all`, no reinicia automáticamente y no fuerza el cierre de procesos por defecto.

## Cambios principales

1. **Windows Update:** agrega la categoría `Updates` al alcance base. Mantiene `server_selection: default` para respetar WSUS/políticas del equipo. Elimina `failed_when: false` de búsqueda, instalación y verificación: los errores reales ahora llegan al bloque `rescue` y al informe.
2. **WinGet:** la comprobación busca la fila del ID exacto en la salida tabular de `winget list --upgrade-available`. Ya no interpreta cualquier retorno `0` como una actualización disponible. Si existe actualización, ejecuta `winget upgrade` solo para ese ID.
3. **Verificación:** clasifica `updated` únicamente cuando WinGet retorna `0`, la consulta posterior funciona, ya no aparece una actualización pendiente y la versión instalada cambia. Si no puede demostrarlo, informa `upgrade_unverified` o `still_outdated`; no declara éxito por un `rc=0` aislado.
4. **Logs por aplicación:** `Invoke-WingetPackage.ps1` conserva un JSON por paquete con `stdout`, `stderr`, argumentos, códigos de retorno, versiones y clasificación.
5. **Reporting:** genera `execution_summary.json` y `applications.csv` en `C:\Logs\ansible_updates\latest` y conserva historial en `C:\Logs\ansible_updates\history\<jobid_timestamp>`; también publica el objeto `update_manager_report_<host>` mediante `set_stats` para AWX.
6. **Estado AWX:** la ejecución de instalación falla si el resultado global queda `parcial` o `fallido`. El playbook de consulta puede terminar correctamente con hallazgos pendientes, porque no instala.

## Requisitos

- AWX / Automation Controller con EE que incluya `ansible.windows`.
- Colección `ansible.windows` instalada en el EE. `requirements.yml` declara la dependencia.
- Windows 11 accesible por la conexión WinRM ya configurada en AWX.
- WinGet/`winget.exe` disponible en el contexto de usuario con el que AWX se conecta. WinGet puede tener diferencias de visibilidad entre una sesión interactiva y la sesión WinRM.
- Permisos para crear `C:\Logs\ansible_updates`.

No es necesario volver a configurar WinRM, firewall ni credenciales si la conectividad actual ya funciona.

## Configuración del proyecto en AWX

1. Sincroniza el repositorio Git que contiene la carpeta `ansible-windows11-updates`.
2. Conserva el inventario, la credencial Machine/WinRM y el Execution Environment que ya te funcionan. No es necesario recrearlos.
3. Verifica que el EE `awx-ee:24.6.1` tenga la colección `ansible.windows`; si no está, incorpora `requirements.yml` al proceso de construcción del EE (no basta con que el archivo exista en el proyecto).
4. Crea o actualiza un Job Template de consulta con Playbook `check_updates.yaml`.
5. Crea o actualiza otro Job Template de instalación con Playbook `update_windows11.yaml`. Mantén `Prompt on launch` para las variables extra vars de instalación y no guardes `update_manager_confirm: INSTALL` como valor permanente del template.
6. Ejecuta primero la consulta. Solo después de revisar el alcance, usa el template de instalación con confirmación explícita.

## Validación inicial — solo consulta

1. Ejecuta `check_updates.yaml` desde el Job Template.
2. No definas `update_manager_confirm` para esta consulta.
3. Revisa el resumen del Job y los archivos remotos.

Ejemplo de extra vars:

```yaml
update_manager_hosts: windows
update_manager_run_windows_updates: true
update_manager_run_application_updates: true
update_manager_run_ms_components: true
windows_updates_server_selection: default
windows_updates_reboot: false
application_updates_limit_ids: []
ms_components_limit_ids: []
reporting_write_files: true
reporting_output_directory: 'C:\Logs\ansible_updates'
```

## Instalación controlada

Primera prueba recomendada: limita a una aplicación conocida, después de revisar la consulta.

```yaml
update_manager_confirm: INSTALL
update_manager_hosts: windows
update_manager_run_windows_updates: false
update_manager_run_application_updates: true
update_manager_run_ms_components: false
application_updates_limit_ids:
  - 7zip.7zip
windows_updates_reboot: false
application_updates_close_processes: false
application_updates_force_close: false
reporting_write_files: true
reporting_fail_job_on_partial: true
```

Cuando esa prueba sea satisfactoria, amplía el límite o déjalo vacío para evaluar todas las aplicaciones definidas. Para incluir Windows Update en una ejecución posterior, activa `update_manager_run_windows_updates: true` y revisa primero el alcance de categorías y las políticas del equipo.

## Variables importantes

| Variable | Valor por defecto | Uso |
|---|---:|---|
| `update_manager_confirm` | sin definir | Debe ser exactamente `INSTALL` para instalar. |
| `windows_updates_server_selection` | `default` | Respeta la configuración/política del equipo. |
| `windows_updates_base_categories` | Security, Critical, Definition, Rollups, Updates | Categorías base. |
| `windows_updates_reboot` | `false` | Reinicio automático desactivado. |
| `application_updates_limit_ids` | `[]` | Subconjunto exacto de IDs; vacío = lista completa configurada. |
| `ms_components_limit_ids` | `[]` | Subconjunto exacto de componentes Microsoft. |
| `application_updates_close_processes` | `false` | Cierre ordenado desactivado. |
| `application_updates_force_close` | `false` | Cierre forzado desactivado. |
| `reporting_write_files` | `true` | Escribe JSON y CSV en Windows. |
| `reporting_output_directory` | `C:\Logs\ansible_updates` | Carpeta raíz de evidencia. |
| `reporting_fail_job_on_partial` | `false` general / `true` en instalación | Convierte un resultado parcial en Job fallido. |

## Evidencia generada en Windows

```text
C:\Logs\ansible_updates\
├── windows_update.log
├── winget\
│   ├── application_updates\<package-id>.json
│   └── ms_components\<package-id>.json
├── latest\
│   ├── execution_summary.json
│   └── applications.csv
└── history\
    └── <awx_job_id_timestamp>\
        ├── execution_summary.json
        └── applications.csv
```

Los JSON individuales de WinGet incluyen la salida completa de cada comando. El resumen JSON contiene estado global, fases, códigos de retorno, versiones antes/después, clasificación y ruta del log individual.

## Interpretación de estados de aplicaciones

- `updated`: la versión cambió y la consulta posterior confirma que ya no hay actualización disponible.
- `up_to_date`: no se detectó una actualización aplicable.
- `update_available`: modo consulta; hay una versión disponible.
- `not_installed`: ese ID no aparece instalado en el contexto de ejecución de AWX.
- `still_outdated`: la actualización se intentó, pero sigue apareciendo disponible.
- `upgrade_unverified`: no se pudo demostrar el cambio de versión.
- `timeout`, `other_rc`, `script_error`, `winget_not_found`, `blocked_by_process`: fallo o bloqueo que requiere revisar el JSON del paquete.

**Importante:** WinGet presenta una tabla de texto en `list`; el script identifica el ID exacto y extrae versión instalada/disponible. Si una versión o ID se muestra truncado o la tabla cambia, el resultado se marca como no verificado en vez de declararse actualizado. Comprueba el JSON de esa aplicación.

## Validación de sintaxis

Desde el directorio del proyecto, dentro de un entorno que tenga Ansible y las colecciones:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook --syntax-check -i localhost, check_updates.yaml
ansible-playbook --syntax-check -i localhost, update_windows11.yaml
```

La validación de sintaxis no se ha ejecutado contra tu AWX ni contra tu Windows desde este entorno. Después de importar el ZIP, ejecuta primero el playbook de consulta.

## Recomendaciones operativas

- Mantén `server_selection: default` salvo que el equipo confirme que debe usar otro catálogo. No eludas WSUS/políticas corporativas a ciegas.
- No habilites `windows_updates_reboot`, `application_updates_force_close` ni el cierre de procesos sin una ventana de mantenimiento y autorización.
- La lista de IDs de `application_updates/defaults/main.yaml` es la lista que venía en tu ZIP. Revisa `not_installed` en la sesión WinRM; no significa necesariamente que la aplicación no exista en el perfil interactivo de otro usuario.
- Los componentes Microsoft permanecen separados en `ms_components` para mantener control del alcance.
