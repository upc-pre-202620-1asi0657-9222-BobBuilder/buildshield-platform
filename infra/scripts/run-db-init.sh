#!/usr/bin/env bash
# Crea las 8 bases y sus roles en RDS con una tarea de ECS. Es idempotente. Se ejecuta tras el primer apply.
set -euo pipefail
cd "$(dirname "$0")/../terraform"

cluster=$(terraform output -raw cluster_name)
region=$(terraform output -raw region)
subnets=$(terraform output -json private_subnet_ids | tr -d '[]"')
security_group=$(terraform output -raw services_security_group_id)

task=$(aws ecs run-task --region "$region" --cluster "$cluster" --launch-type FARGATE \
  --task-definition "$cluster-db-init" \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_group]}" \
  --query 'tasks[0].taskArn' --output text)

echo "Tarea $task en curso..."
aws ecs wait tasks-stopped --region "$region" --cluster "$cluster" --tasks "$task"

code=$(aws ecs describe-tasks --region "$region" --cluster "$cluster" --tasks "$task" \
  --query 'tasks[0].containers[0].exitCode' --output text)
if [ "$code" != "0" ]; then
  echo "Falló con código $code. Revisa el log /ecs/$cluster/db-init en CloudWatch." >&2
  exit 1
fi
echo "Las 8 bases están listas."
