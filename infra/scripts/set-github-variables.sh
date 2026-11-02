#!/usr/bin/env bash
# Publica en cada repo las variables que usan sus GitHub Actions. Mientras no existan, los flujos no despliegan.
# Son variables y no secretos: ninguna es una clave.
set -euo pipefail
cd "$(dirname "$0")/../terraform"

org=upc-pre-202620-1asi0657-9222-BobBuilder
role=$(terraform output -raw github_deploy_role_arn)
region=$(terraform output -raw region)
cluster=$(terraform output -raw cluster_name)
site=$(terraform output -raw site_url)

for repo in api-gateway iam-service organization-service inventory-service ordering-service \
            discrepancy-service subscription-service notification-service audit-service web; do
  full="$org/buildshield-$repo"
  gh variable set AWS_ROLE_ARN --repo "$full" --body "$role"
  gh variable set AWS_REGION --repo "$full" --body "$region"
  gh variable set ECS_CLUSTER --repo "$full" --body "$cluster"
  echo "Listo: $full"
done

gh variable set WEB_BUCKET --repo "$org/buildshield-web" --body "$(terraform output -raw web_bucket)"
gh variable set CLOUDFRONT_DISTRIBUTION_ID --repo "$org/buildshield-web" --body "$(terraform output -raw cloudfront_distribution_id)"
echo "URL del sitio: $site"
