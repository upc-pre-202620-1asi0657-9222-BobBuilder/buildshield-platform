# buildshield-platform

Infraestructura local de BuildShield (BobBuilder): Kafka de desarrollo sin Docker, scripts para levantar y
detener todo, `docker-compose.yml` para quien tenga Docker y la colección Postman E2E contra el gateway.
El contrato de todos los repositorios está en el wiki del proyecto (`wiki/informe-tf/plan-microservicios.md`).

## Mapa de servicios

| Servicio | Repositorio | Puerto | Base | Tópico que publica |
|---|---|---|---|---|
| API Gateway | `buildshield-api-gateway` | 8080 | ninguna | ninguno |
| Identidad y Acceso | `buildshield-iam-service` | 8081 | `iam_db` | `buildshield.iam` |
| Organización y Configuración | `buildshield-organization-service` | 8082 | `organization_db` | `buildshield.organization` |
| Inventario | `buildshield-inventory-service` | 8083 | `inventory_db` | `buildshield.inventory` |
| Gestión de Pedidos y Entregas | `buildshield-ordering-service` | 8084 | `ordering_db` | `buildshield.ordering` |
| Gestión de Discrepancias | `buildshield-discrepancy-service` | 8085 | `discrepancy_db` | `buildshield.discrepancy` |
| Suscripción y Pagos | `buildshield-subscription-service` | 8086 | `subscription_db` | `buildshield.subscription` |
| Notificaciones | `buildshield-notification-service` | 8087 | `notification_db` | ninguno |
| Trazabilidad y Auditoría | `buildshield-audit-service` | 8088 | `audit_db` | ninguno |
| Kafka de desarrollo | `buildshield-platform/dev-kafka` | 9092 | ninguna | crea los 6 tópicos (3 particiones) |
| Web | `buildshield-web` | 4200 | ninguna | ninguno |

Cada servicio se conecta a su base con el rol `<svc>_service` (contraseña igual al nombre del rol), que es
el valor por defecto de `DB_USER`/`DB_PASSWORD` en los servicios. En el clúster local la autenticación es
trust; las contraseñas solo importan en Docker.

## Local sin Docker (Windows)

Requisitos: JDK 21, PostgreSQL en `127.0.0.1:5433` (autenticación trust, superusuario `buildshield_core`),
claves JWT en `~/.buildshield/jwt-private.pem` y `jwt-public.pem`, y los repositorios `buildshield-*` como
carpetas hermanas de este.

```powershell
# 1. Arrancar el clúster PostgreSQL local
pg_ctl -D "$env:LOCALAPPDATA\buildshield-local-pg" -o "-p 5433" start

# 2. Crear las 8 bases y sus roles (idempotente; -WithTestDatabases crea además las <svc>_it)
.\scripts\create-databases.ps1

# 3. Levantar dev-kafka, los servicios que tengan JAR y el gateway
.\scripts\run-all.ps1                 # usa los JAR de target/
.\scripts\run-all.ps1 -Build          # antes compila cada repo con mvn package -DskipTests

# 4. Detener todo
.\scripts\stop-all.ps1
```

`run-all.ps1`:

- Arranca primero `dev-kafka` y espera a que abra el 9092; luego cada servicio y el gateway como
  `java -jar <jar> --spring.profiles.active=local` en segundo plano.
- Variables de cada proceso: `SERVER_PORT`, `DB_HOST=127.0.0.1`, `DB_PORT=5433`, `DB_NAME=<svc>_db`,
  `DB_USER`/`DB_PASSWORD=<svc>_service`, `KAFKA_BOOTSTRAP_SERVERS=localhost:9092`, `BUILDSHIELD_JWT_PUBLIC_KEY`
  (todos) y `BUILDSHIELD_JWT_PRIVATE_KEY` (solo IAM), leídas de `~/.buildshield/*.pem`.
- Omite con una advertencia los servicios cuyo repositorio o JAR no existe todavía y los puertos ya ocupados.
- Espera `/actuator/health` de cada servicio (por defecto hasta 180 s).
- Logs en `logs/<svc>.log` (y `logs/<svc>.err.log`), PIDs en `logs/run-all.pids`.
- Parámetros: `-ReposRoot <carpeta>` (por defecto la carpeta padre de este repo), `-Build`, `-Only iam,gateway`,
  `-NoKafka`, `-SpringProfile`, `-DbHost`, `-DbPort`, `-KafkaBootstrapServers`, `-KeysDir`,
  `-HealthTimeoutSeconds`.

`stop-all.ps1` detiene los PIDs de `logs/run-all.pids` y, como respaldo, cualquier proceso `java` que siga
escuchando en 8080 a 8088 o 9092 (`-NoPortFallback` lo desactiva).

`dev-kafka` es un broker KRaft embebido (spring-kafka-test) en `localhost:9092`. Los mensajes viven mientras
el proceso está arriba. Para correrlo solo: `cd dev-kafka; .\mvnw.cmd package; java -jar target\dev-kafka-0.1.0-SNAPSHOT.jar`.

## Con Docker

```bash
cp .env.example .env      # pegar el PEM de las claves JWT
docker compose up -d --build
```

Levanta 8 PostgreSQL 16 (uno por servicio, se eligió así en vez de una instancia con script de inicio para
reflejar "una base por microservicio"), Kafka KRaft (`apache/kafka`) con un contenedor que crea los 6 tópicos,
los 8 servicios, el gateway (8080) y la web (4200, nginx con `/api` hacia el gateway). Mientras no existan todos
los repositorios se puede levantar una parte: `docker compose up -d --build api-gateway iam-service organization-service`.
La imagen de la web se construye con `docker/web/Dockerfile` sin tocar el repositorio de la web.

## Postman

`postman/BuildShield-Microservices-E2E.postman_collection.json` con el entorno
`postman/BuildShield-local.postman_environment.json` (`baseUrl=http://localhost:8080`). Por ahora cubre:
comprobaciones del gateway (salud, 401 sin token, `X-Correlation-Id`), registro, inicio de sesión, usuarios,
obra, almacén, material y asignaciones. Se basa en la colección Sprint 2 de `buildshield-core`. Las etapas
siguientes agregan stock, pedidos, saga, despacho, recepción, discrepancias, notificaciones y auditoría.

```bash
npx newman run postman/BuildShield-Microservices-E2E.postman_collection.json -e postman/BuildShield-local.postman_environment.json
```

## Pruebas E2E con Python

Con todo levantado (`run-all.ps1`) y, para la web, `npx ng serve` en `buildshield-web` (puerto 4200):

| Script | Qué recorre |
|---|---|
| `e2e/api_flow_ordering_inventory.py` | saga de reserva (aprobado y rechazo sin stock), despacho, recepción parcial y conformidad, stock de la obra y cierre del pedido |
| `e2e/api_flow_custody.py` | prueba gratuita, notificaciones, auditoría, discrepancia automática, evidencia por URL firmada y custodia |
| `e2e/web_flow_sprint3.py <carpeta>` | la web con login real por rol (Playwright y Chrome instalado) y una captura por pantalla del Sprint 3 |

```bash
python -X utf8 e2e/api_flow_ordering_inventory.py
python -X utf8 e2e/web_flow_sprint3.py capturas
```
