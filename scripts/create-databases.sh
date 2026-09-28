#!/bin/sh
# Job postgres-init: garante um database e um usuario por servico. Idempotente
# (roda a cada `docker compose up`), inclusive num volume ja inicializado:
# cria so o que falta, nunca altera nem apaga o que existe.
set -eu

ensure_service_db() {
  db_user="$1"
  db_password="$2"
  db_name="$3"
  psql -v ON_ERROR_STOP=1 --host postgres --username "$POSTGRES_USER" --dbname postgres \
    --set=db_user="$db_user" --set=db_password="$db_password" --set=db_name="$db_name" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db_name') \gexec
SQL
  echo "database $db_name pronto (usuario $db_user)"
}

ensure_service_db "$CATALOG_DB_USER" "$CATALOG_DB_PASSWORD" "$CATALOG_DB_NAME"
ensure_service_db "$TRANSPORT_DB_USER" "$TRANSPORT_DB_PASSWORD" "$TRANSPORT_DB_NAME"
ensure_service_db "$AUTH_DB_USER" "$AUTH_DB_PASSWORD" "$AUTH_DB_NAME"
ensure_service_db "$CUSTOMER_DB_USER" "$CUSTOMER_DB_PASSWORD" "$CUSTOMER_DB_NAME"
ensure_service_db "$SALES_ORDER_DB_USER" "$SALES_ORDER_DB_PASSWORD" "$SALES_ORDER_DB_NAME"
