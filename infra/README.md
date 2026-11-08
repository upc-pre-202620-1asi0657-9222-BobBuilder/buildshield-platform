# Infraestructura de BuildShield en AWS

Terraform de la arquitectura de la Figura 94: CloudFront, S3, balanceador, ECS Fargate, RDS for PostgreSQL 16, Kafka,
Secrets Manager y CloudWatch. **Crear estos recursos genera costo: al terminar, ejecuta `terraform destroy`.**

## Tamaño

Por defecto se crea una versión reducida. Para ir a la de la Figura 94, cambia estas variables en `terraform.tfvars`.

| Variable | Reducida (por defecto) | Figura 94 |
|---|---|---|
| `desired_count` | 1 | 2 |
| `db_multi_az` | `false` | `true` |
| `kafka_mode` | `ecs`: un broker en Fargate, sin disco persistente | `msk` |

En ambas: RDS tiene las 8 bases en una sola instancia, cada una con su rol. Los servicios no usan TLS hacia Kafka; ese
tráfico queda dentro de las subredes privadas. Sin dominio propio, el balanceador recibe HTTP solo desde CloudFront, que
atiende a los usuarios por HTTPS.

## Primer despliegue

Requiere una sesión de AWS (no uses la cuenta root), Terraform y la CLI `gh`.

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # y completa la clave de Stripe en modo prueba
terraform init
terraform plan
terraform apply
../scripts/run-db-init.sh
../scripts/set-github-variables.sh
```

Después:

1. Vuelve a ejecutar los flujos de GitHub Actions de cada repo (al hacer merge en `develop` o `main`). Hasta que suben
   su primera imagen, los servicios de ECS no arrancan.
2. Crea el webhook en Stripe con la URL de `terraform output stripe_webhook_url`, agrega su secreto a
   `terraform.tfvars` como `stripe_webhook_secret` y aplica de nuevo.
3. Fuerza un nuevo despliegue de `subscription`, porque los secretos solo se leen al arrancar.

## Cómo se despliega cada repo

Cada repo tiene `.github/workflows/deploy.yml`. Corre las pruebas y, en `develop` y `main`, sube la imagen a ECR con la
etiqueta del commit y `latest`, y fuerza un nuevo despliegue en ECS. La web se publica en S3 e invalida CloudFront.
GitHub entra a AWS con OIDC, sin claves guardadas, y solo desde esas dos ramas.

## Cuidado

- El estado de Terraform contiene las contraseñas y la clave de JWT. `terraform.tfstate` y `terraform.tfvars` están en
  `.gitignore`: no los subas.
- Con `kafka_mode = "ecs"`, si el broker se reinicia se pierden los eventos que aún no se consumieron.
