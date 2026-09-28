#!/bin/sh
# Roda uma unica vez, na primeira subida do volume (docker-entrypoint-initdb.d).
# Um database e um usuario por servico: cada servico so enxerga o proprio banco.
set -eu

create_service_db() {
  db_user="$1"
  db_password="$2"
  db_name="$3"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
    --set=db_user="$db_user" --set=db_password="$db_password" --set=db_name="$db_name" <<'SQL'
CREATE ROLE :"db_user" LOGIN PASSWORD :'db_password';
CREATE DATABASE :"db_name" OWNER :"db_user";
REVOKE ALL ON DATABASE :"db_name" FROM PUBLIC;
SQL
}

create_service_db "$CATALOG_DB_USER" "$CATALOG_DB_PASSWORD" "$CATALOG_DB_NAME"
create_service_db "$TRANSPORT_DB_USER" "$TRANSPORT_DB_PASSWORD" "$TRANSPORT_DB_NAME"
