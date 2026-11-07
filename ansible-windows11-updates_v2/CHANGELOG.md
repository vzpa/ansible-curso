# Cambios — versión 2.0 corregida

- Añadida la categoría `Updates` a las categorías base de Windows Update.
- Eliminada la supresión global de errores de `win_updates` (`failed_when: false`).
- Añadida ruta de log persistente y creación explícita del directorio.
- Corregida la detección WinGet: el ID exacto debe aparecer en la lista de actualizaciones para declarar `update_available`.
- Añadida comprobación de versión antes/después y clasificación `updated` solo con evidencia del cambio.
- Añadidos JSON individuales por paquete con stdout/stderr/rc y versiones.
- Añadidos `execution_summary.json` y `applications.csv` en `latest` e `history`.
- El playbook de instalación falla ante resultados `parcial` o `fallido`.
- Las fases de aplicaciones se omiten si Windows Update falla o queda parcialmente pendiente, salvo override explícito.
- Añadidos ejemplos de variables y guía de operación para AWX EE 24.6.1.
