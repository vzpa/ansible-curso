CREATE USER testuser WITH PASSWORD 'password';
CREATE DATABASE testdb OWNER testuser;
GRANT ALL PRIVILEGES ON DATABASE testdb TO testuser;

# Crear usuario
psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"

# Crear base de datos
psql -c "CREATE DATABASE $DB OWNER $DB_USER;"

# Asignar permisos al usuario sobre la base de datos
psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB TO $DB_USER;"

# conectarse a la base de datos y crear tablas
\c testdb

CREATE TABLE empleados (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(100),
    puesto VARCHAR(100),
    salario NUMERIC
);