# ---------------------------------------------------------------- secretos
# El estado de Terraform guarda estos valores: no se sube al repositorio (ver .gitignore).
resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "random_password" "db" {
  for_each = toset(local.database_services)

  length  = 32
  special = false
}

resource "random_password" "evidence_url" {
  length  = 48
  special = false
}

resource "random_password" "origin_verify" {
  length  = 48
  special = false
}

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.project}/db/master"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id     = aws_secretsmanager_secret.db_master.id
  secret_string = random_password.db_master.result
}

resource "aws_secretsmanager_secret" "db" {
  for_each = toset(local.database_services)

  name                    = "${var.project}/db/${each.key}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  for_each = toset(local.database_services)

  secret_id     = aws_secretsmanager_secret.db[each.key].id
  secret_string = random_password.db[each.key].result
}

resource "aws_secretsmanager_secret" "jwt_private_key" {
  name                    = "${var.project}/jwt/private-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_private_key" {
  secret_id     = aws_secretsmanager_secret.jwt_private_key.id
  secret_string = tls_private_key.jwt.private_key_pem_pkcs8
}

resource "aws_secretsmanager_secret" "jwt_public_key" {
  name                    = "${var.project}/jwt/public-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_public_key" {
  secret_id     = aws_secretsmanager_secret.jwt_public_key.id
  secret_string = tls_private_key.jwt.public_key_pem
}

resource "aws_secretsmanager_secret" "evidence_url" {
  name                    = "${var.project}/evidence/url-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "evidence_url" {
  secret_id     = aws_secretsmanager_secret.evidence_url.id
  secret_string = random_password.evidence_url.result
}

resource "aws_secretsmanager_secret" "stripe_secret_key" {
  name                    = "${var.project}/stripe/secret-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "stripe_secret_key" {
  secret_id     = aws_secretsmanager_secret.stripe_secret_key.id
  secret_string = var.stripe_secret_key
}

resource "aws_secretsmanager_secret" "stripe_webhook" {
  name                    = "${var.project}/stripe/webhook-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "stripe_webhook" {
  secret_id     = aws_secretsmanager_secret.stripe_webhook.id
  secret_string = var.stripe_webhook_secret
}

# ---------------------------------------------------------------- RDS: una instancia con las 8 bases
resource "aws_db_subnet_group" "main" {
  name       = var.project
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "main" {
  identifier              = var.project
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  max_allocated_storage   = 50
  storage_type            = "gp3"
  storage_encrypted       = true
  multi_az                = var.db_multi_az
  username                = "buildshield_admin"
  password                = random_password.db_master.result
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.database.id]
  publicly_accessible     = false
  backup_retention_period = 7
  skip_final_snapshot     = true
  apply_immediately       = true
}

# ---------------------------------------------------------------- Kafka administrado (kafka_mode = "msk")
resource "aws_msk_configuration" "main" {
  count = var.kafka_mode == "msk" ? 1 : 0

  name           = var.project
  kafka_versions = ["3.6.0"]

  server_properties = <<-PROPERTIES
    auto.create.topics.enable=true
    default.replication.factor=2
  PROPERTIES
}

resource "aws_msk_cluster" "main" {
  count = var.kafka_mode == "msk" ? 1 : 0

  cluster_name           = var.project
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = aws_subnet.private[*].id
    security_groups = [aws_security_group.msk[0].id]

    storage_info {
      ebs_storage_info {
        volume_size = 20
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main[0].arn
    revision = aws_msk_configuration.main[0].latest_revision
  }

  # Los servicios no usan TLS hacia Kafka: el tráfico queda dentro de las subredes privadas.
  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
    }
  }
}

# ---------------------------------------------------------------- S3 de evidencias
resource "aws_s3_bucket" "evidence" {
  bucket_prefix = "${var.project}-evidence-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
