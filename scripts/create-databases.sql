-- Crea las 8 bases de BuildShield (una por microservicio) y su rol propietario.
-- Idempotente: se puede ejecutar varias veces. Requiere un superusuario (en el clúster local de
-- 127.0.0.1:5433, buildshield_core). Ejecutar con psql:
--   psql -h 127.0.0.1 -p 5433 -U buildshield_core -d postgres -f scripts/create-databases.sql
-- Las contraseñas solo valen para docker-compose; el clúster local usa autenticación trust.

-- Sufijo de las bases: _db por defecto; otro sufijo (psql -v db_suffix=_e2e) crea un juego aparte.
\if :{?db_suffix}
\else
  \set db_suffix _db
\endif

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', svc || '_service', svc || '_service')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = svc || '_service')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', svc || :'db_suffix', svc || '_service')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = svc || :'db_suffix')
\gexec

-- Cada rol solo se conecta a su propia base (sin acceso a las de otros servicios).
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', svc || :'db_suffix')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', svc || :'db_suffix', svc || '_service')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
\gexec
