set -eu
export PGPASSWORD="$MASTER_PASSWORD" PGSSLMODE=require
sql() { psql -h "$DB_HOST" -U "$MASTER_USER" -d postgres -v ON_ERROR_STOP=1 -tA -c "$1"; }

for svc in $SERVICES; do
  role="${svc}_service"
  db="${svc}_db"
  eval "password=\$PW_${svc}"

  if [ -z "$(sql "SELECT 1 FROM pg_roles WHERE rolname = '$role'")" ]; then
    sql "CREATE ROLE $role LOGIN PASSWORD '$password'"
  else
    sql "ALTER ROLE $role LOGIN PASSWORD '$password'"
  fi

  # En RDS el usuario maestro no es superusuario: necesita el rol para crear una base a su nombre.
  sql "GRANT $role TO $MASTER_USER"

  if [ -z "$(sql "SELECT 1 FROM pg_database WHERE datname = '$db'")" ]; then
    sql "CREATE DATABASE $db OWNER $role ENCODING 'UTF8'"
  fi

  # Cada rol solo se conecta a su propia base.
  sql "REVOKE CONNECT ON DATABASE $db FROM PUBLIC"
  sql "GRANT CONNECT ON DATABASE $db TO $role"
  echo "Base $db lista"
done
