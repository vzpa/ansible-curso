#!/bin/bash
## Borrar el resultado del backup anterior
rm /tmp/backup.terminado
rm /tmp/copia.tar

### Hacer el backup 
tar cvf /tmp/copia.tar /usr/*

### Indicar que ha terminado
echo "Fin de Backup" >/tmp/backup.terminado