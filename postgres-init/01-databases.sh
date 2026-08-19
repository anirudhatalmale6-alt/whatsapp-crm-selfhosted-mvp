#!/bin/bash
# Se ejecuta UNA sola vez, cuando el volumen de Postgres esta vacio.
# Una base de datos por numero -> la sesion/credenciales de un numero no
# comparten tabla con las del otro. Anadir un numero 3 = anadir una linea.
set -e

for db in evolution_n1 evolution_n2 chatwoot; do
  echo "creando base de datos: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    SELECT 'CREATE DATABASE $db'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
EOSQL
done
