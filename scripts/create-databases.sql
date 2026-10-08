-- Crea las 8 bases de BuildShield (una por microservicio) y su rol propietario.
-- Idempotente: se puede ejecutar varias veces. Requiere un superusuario (en el clúster local de
-- 127.0.0.1:5433, buildshield_core). Ejecutar con psql:
--   psql -h 127.0.0.1 -p 5433 -U buildshield_core -d postgres -f scripts/create-databases.sql
-- Las contraseñas solo valen para docker-compose; el clúster local usa autenticación trust.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', svc || '_service', svc || '_service')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = svc || '_service')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', svc || '_db', svc || '_service')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = svc || '_db')
\gexec

-- Cada rol solo se conecta a su propia base (sin acceso a las de otros servicios).
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', svc || '_db')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', svc || '_db', svc || '_service')
FROM unnest(ARRAY['iam', 'organization', 'inventory', 'ordering', 'discrepancy', 'subscription',
                  'notification', 'audit']) AS svc
\gexec
