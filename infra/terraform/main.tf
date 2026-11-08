terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  azs       = slice(data.aws_availability_zones.available.names, 0, 2)
  namespace = "${var.project}.local"

  site_url = "https://${aws_cloudfront_distribution.web.domain_name}"

  # Un servicio por bounded context más el API Gateway. Los puertos son los del contrato de plataforma.
  services = {
    gateway = {
      port      = 8080
      database  = false
      autoscale = false
      env = merge(
        { for name in local.database_services : "${upper(name)}_URI" => "http://${name}.${local.namespace}:${local.ports[name]}" },
        { BUILDSHIELD_CORS_ALLOWED_ORIGINS = local.site_url }
      )
      secrets = {}
    }
    iam = {
      port      = 8081
      database  = true
      autoscale = false
      env       = { BUILDSHIELD_PASSWORD_RESET_URL = "${local.site_url}/restablecer-contrasena" }
      secrets   = { BUILDSHIELD_JWT_PRIVATE_KEY = aws_secretsmanager_secret.jwt_private_key.arn }
    }
    organization = {
      port      = 8082
      database  = true
      autoscale = false
      env       = {}
      secrets   = {}
    }
    inventory = {
      port      = 8083
      database  = true
      autoscale = false
      env       = {}
      secrets   = {}
    }
    ordering = {
      port      = 8084
      database  = true
      autoscale = true
      env       = {}
      secrets   = {}
    }
    discrepancy = {
      port      = 8085
      database  = true
      autoscale = true
      env       = { EVIDENCE_BUCKET = aws_s3_bucket.evidence.bucket }
      secrets   = { EVIDENCE_URL_SECRET = aws_secretsmanager_secret.evidence_url.arn }
    }
    subscription = {
      port      = 8086
      database  = true
      autoscale = false
      env = {
        PAYMENTS_SUCCESS_URL = "${local.site_url}/suscripcion?pago=exitoso&session_id={CHECKOUT_SESSION_ID}"
        PAYMENTS_CANCEL_URL  = "${local.site_url}/suscripcion?pago=cancelado"
      }
      secrets = {
        STRIPE_SECRET_KEY     = aws_secretsmanager_secret.stripe_secret_key.arn
        STRIPE_WEBHOOK_SECRET = aws_secretsmanager_secret.stripe_webhook.arn
      }
    }
    notification = {
      port      = 8087
      database  = true
      autoscale = false
      env = {
        NOTIFICATION_EMAIL_ENABLED = tostring(var.email_enabled)
        NOTIFICATION_EMAIL_FROM    = var.email_from
      }
      secrets = {}
    }
    audit = {
      port      = 8088
      database  = true
      autoscale = false
      env       = {}
      secrets   = {}
    }
  }

  database_services = ["iam", "organization", "inventory", "ordering", "discrepancy", "subscription", "notification", "audit"]
  ports = {
    iam         = 8081, organization = 8082, inventory = 8083, ordering = 8084
    discrepancy = 8085, subscription = 8086, notification = 8087, audit = 8088
  }
}
