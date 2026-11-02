resource "aws_ecs_cluster" "main" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = local.namespace
  vpc  = aws_vpc.main.id
}

resource "aws_ecr_repository" "services" {
  for_each = local.services

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each = local.services

  repository = aws_ecr_repository.services[each.key].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conserva las 10 imágenes más recientes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "services" {
  for_each = toset(concat(keys(local.services), ["kafka", "db-init"]))

  name              = "/ecs/${var.project}/${each.key}"
  retention_in_days = var.log_retention_days
}

locals {
  kafka_bootstrap = (var.kafka_mode == "msk"
    ? aws_msk_cluster.main[0].bootstrap_brokers
  : "kafka.${local.namespace}:9092")
}

resource "aws_ecs_task_definition" "services" {
  for_each = local.services

  family                   = "${var.project}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = each.key == "discrepancy" ? aws_iam_role.evidence_task.arn : aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name         = each.key
    image        = "${aws_ecr_repository.services[each.key].repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = each.value.port, protocol = "tcp" }]

    environment = [
      for name, value in merge(
        {
          SPRING_PROFILES_ACTIVE = "prod"
          SERVER_PORT            = tostring(each.value.port)
        },
        each.value.database ? {
          DB_HOST                 = aws_db_instance.main.address
          DB_PORT                 = tostring(aws_db_instance.main.port)
          DB_NAME                 = "${each.key}_db"
          DB_USER                 = "${each.key}_service"
          KAFKA_BOOTSTRAP_SERVERS = local.kafka_bootstrap
        } : {},
        each.value.env
      ) : { name = name, value = value }
    ]

    secrets = [
      for name, arn in merge(
        { BUILDSHIELD_JWT_PUBLIC_KEY = aws_secretsmanager_secret.jwt_public_key.arn },
        each.value.database ? { DB_PASSWORD = aws_secretsmanager_secret.db[each.key].arn } : {},
        each.value.secrets
      ) : { name = name, valueFrom = arn }
    ]

    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:${each.value.port}/actuator/health | grep -q UP"]
      interval    = 30
      timeout     = 5
      retries     = 5
      startPeriod = 180
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.services[each.key].name
        awslogs-region        = var.region
        awslogs-stream-prefix = each.key
      }
    }
  }])

  depends_on = [aws_secretsmanager_secret_version.db, aws_secretsmanager_secret_version.jwt_public_key]
}

resource "aws_service_discovery_service" "services" {
  for_each = local.services

  name = each.key

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "services" {
  for_each = local.services

  name                              = each.key
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.services[each.key].arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = each.key == "gateway" ? 300 : null
  wait_for_steady_state             = false

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.services.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services[each.key].arn
  }

  dynamic "load_balancer" {
    for_each = each.key == "gateway" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.gateway.arn
      container_name   = "gateway"
      container_port   = 8080
    }
  }

  # El escalado automático cambia desired_count fuera de Terraform.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_appautoscaling_target" "services" {
  for_each = { for name, service in local.services : name => service if service.autoscale }

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.services[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.desired_count
  max_capacity       = var.autoscaling_max
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = aws_appautoscaling_target.services

  name               = "${var.project}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# ---------------------------------------------------------------- Kafka en Fargate (kafka_mode = "ecs")
# Un solo broker sin disco persistente: al reiniciar se pierden los eventos aún no consumidos.
resource "aws_ecs_task_definition" "kafka" {
  count = var.kafka_mode == "ecs" ? 1 : 0

  family                   = "${var.project}-kafka"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([{
    name         = "kafka"
    image        = "apache/kafka:3.9.1"
    essential    = true
    portMappings = [{ containerPort = 9092, protocol = "tcp" }]

    environment = [
      for name, value in {
        KAFKA_NODE_ID                                  = "1"
        KAFKA_PROCESS_ROLES                            = "broker,controller"
        KAFKA_LISTENERS                                = "PLAINTEXT://:9092,CONTROLLER://:9093"
        KAFKA_ADVERTISED_LISTENERS                     = "PLAINTEXT://kafka.${local.namespace}:9092"
        KAFKA_LISTENER_SECURITY_PROTOCOL_MAP           = "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT"
        KAFKA_CONTROLLER_LISTENER_NAMES                = "CONTROLLER"
        KAFKA_CONTROLLER_QUORUM_VOTERS                 = "1@localhost:9093"
        KAFKA_INTER_BROKER_LISTENER_NAME               = "PLAINTEXT"
        KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR         = "1"
        KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR = "1"
        KAFKA_TRANSACTION_STATE_LOG_MIN_ISR            = "1"
        KAFKA_NUM_PARTITIONS                           = "3"
        KAFKA_HEAP_OPTS                                = "-Xms256m -Xmx512m"
      } : { name = name, value = value }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.services["kafka"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "kafka"
      }
    }
  }])
}

resource "aws_service_discovery_service" "kafka" {
  count = var.kafka_mode == "ecs" ? 1 : 0

  name = "kafka"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "kafka" {
  count = var.kafka_mode == "ecs" ? 1 : 0

  name            = "kafka"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.kafka[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.services.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.kafka[0].arn
  }
}

# ---------------------------------------------------------------- creación de las 8 bases (se corre una vez)
resource "aws_ecs_task_definition" "db_init" {
  family                   = "${var.project}-db-init"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([{
    name      = "db-init"
    image     = "postgres:16-alpine"
    essential = true
    command   = ["sh", "-c", file("${path.module}/files/db-init.sh")]

    environment = [
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "MASTER_USER", value = aws_db_instance.main.username },
      { name = "SERVICES", value = join(" ", local.database_services) },
    ]

    secrets = concat(
      [{ name = "MASTER_PASSWORD", valueFrom = aws_secretsmanager_secret.db_master.arn }],
      [for name in local.database_services : { name = "PW_${name}", valueFrom = aws_secretsmanager_secret.db[name].arn }]
    )

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.services["db-init"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "db-init"
      }
    }
  }])
}
