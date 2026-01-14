#!/bin/bash

# Variables de configuración
USER="postgres"
PASSWORD="postgres"
DB="testdb"
DB_USER="testuser"
DB_PASSWORD="password"

# Crear usuario
psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"

# Crear base de datos
psql -c "CREATE DATABASE $DB OWNER $DB_USER;"

# Asignar permisos al usuario sobre la base de datos
psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB TO $DB_USER;"
