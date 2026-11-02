output "site_url" {
  description = "URL pública de BuildShield."
  value       = local.site_url
}

output "stripe_webhook_url" {
  description = "URL que se registra en Stripe para crear el webhook."
  value       = "${local.site_url}/api/v1/subscriptions/webhooks/stripe"
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "web_bucket" {
  value = aws_s3_bucket.web.bucket
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.web.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "services_security_group_id" {
  value = aws_security_group.services.id
}
