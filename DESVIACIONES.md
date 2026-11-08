# Desviaciones frente a la arquitectura v4

Repositorio `buildshield-platform`. Fuente: sección «Microservicio 3» y Anexo A.3 de la tarea. No tiene componentes en
el C4 ni tablas en el ER.

| Elemento | Motivo |
|---|---|
| Servicio `web` en `docker-compose.yml` | La tarea pide 8 PostgreSQL 16, Kafka KRaft y los servicios. La web se mantiene porque ya estaba y permite probar el sistema completo. |
| Perfil `local` en `docker-compose.yml` | Las imágenes traen `prod` por defecto. Con `local`, subscription usa el pago simulado y no pide claves de Stripe. |
| Fotos de evidencia en `/tmp` del contenedor de discrepancy | En desarrollo se usa disco local (Anexo A.2). La imagen corre sin root, así que no puede escribir en `/app`. Las fotos se pierden al recrear el contenedor. |
