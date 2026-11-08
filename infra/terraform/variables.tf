variable "project" {
  description = "Prefijo de los recursos."
  type        = string
  default     = "buildshield"
}

variable "region" {
  description = "Región de AWS."
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "Organización de GitHub cuyos repos buildshield-* pueden desplegar."
  type        = string
  default     = "upc-pre-202620-1asi0657-9222-BobBuilder"
}

variable "create_github_oidc_provider" {
  description = "false si la cuenta ya tiene el proveedor OIDC de GitHub."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- tamaño (por defecto, la versión reducida)
variable "desired_count" {
  description = "Tareas por servicio. La arquitectura de la Figura 94 usa 2, una por zona."
  type        = number
  default     = 1
}

variable "autoscaling_max" {
  description = "Máximo de tareas de Pedidos y Entregas y de Discrepancias."
  type        = number
  default     = 8
}

variable "task_cpu" {
  description = "CPU de cada tarea de ECS."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Memoria de cada tarea de ECS, en MB."
  type        = number
  default     = 1024
}

variable "db_instance_class" {
  description = "Clase de la instancia de RDS."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "RDS Multi-AZ. La arquitectura de la Figura 94 usa true."
  type        = bool
  default     = false
}

variable "kafka_mode" {
  description = "ecs: un broker Kafka en Fargate, sin réplica. msk: Amazon MSK, como en la Figura 94."
  type        = string
  default     = "ecs"

  validation {
    condition     = contains(["ecs", "msk"], var.kafka_mode)
    error_message = "kafka_mode debe ser ecs o msk."
  }
}

variable "log_retention_days" {
  description = "Días que se conservan los logs en CloudWatch."
  type        = number
  default     = 14
}

# ---------------------------------------------------------------- integraciones externas
variable "stripe_secret_key" {
  description = "Clave secreta de Stripe en modo prueba (sk_test_...)."
  type        = string
  sensitive   = true

  validation {
    condition     = startswith(var.stripe_secret_key, "sk_test_")
    error_message = "Usa una clave de Stripe en modo prueba (sk_test_...)."
  }
}

variable "stripe_webhook_secret" {
  description = "Secreto del webhook de Stripe. Se crea después del primer apply, con la URL de stripe_webhook_url."
  type        = string
  sensitive   = true
  default     = "whsec_pendiente"
}

variable "email_enabled" {
  description = "Activa el envío de correos en notification-service."
  type        = bool
  default     = false
}

variable "email_from" {
  description = "Remitente de los correos."
  type        = string
  default     = "notificaciones@buildshield.pe"
}
