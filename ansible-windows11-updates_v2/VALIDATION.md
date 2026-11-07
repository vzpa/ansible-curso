# Validación del paquete

Validaciones realizadas en el entorno de preparación:

- YAML: todos los archivos `.yaml` / `.yml` parsean correctamente con PyYAML.
- Jinja: todas las expresiones de los archivos YAML parsean correctamente con Jinja2.
- Checks estáticos: categoría `Updates`, eliminación de `failed_when: false` en Windows Update, confirmación `INSTALL`, reinicio desactivado, actualización WinGet por ID (sin `--all`) y fallo del Job ante estado parcial en el playbook de instalación.

Limitaciones de validación:

- No se ejecutó `ansible-playbook --syntax-check`: Ansible no está instalado en este entorno.
- No se ejecutó PowerShell en Windows ni WinRM contra `192.168.99.19`.
- No se ha ejecutado ninguna instalación ni se han modificado aplicaciones o actualizaciones de tu equipo.
- El parser de la salida tabular de WinGet debe confirmarse con el primer Job de consulta en tu sesión WinRM. Si el formato no permite extraer un ID/versión de forma inequívoca, el script reporta `upgrade_unverified` en lugar de afirmar que actualizó.

Siguiente paso seguro: importar/sincronizar el proyecto y ejecutar primero `check_updates.yaml` sin `update_manager_confirm`.
