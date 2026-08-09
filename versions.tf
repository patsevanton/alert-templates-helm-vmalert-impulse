terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "= 0.213.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
  required_version = ">= 1.3"
}

# Email для ACME-аккаунта Let's Encrypt (ClusterIssuer).
# По умолчанию формируется из IP балансировщика: admin@cert-manager.<LB_IP>.sslip.io.
# Синтаксис валиден для Let's Encrypt, выпуск сертификатов через HTTP-01 работает.
# Внимание: почта на этот адрес физически не доставляется (нет MX/SMTP) —
# уведомления об истечении сертификатов не придут. Для продакшена перезапишите
# реальным email через terraform.tfvars или -var="acme_email=you@example.com".
variable "acme_email" {
  type        = string
  description = "Email ACME-аккаунта Let's Encrypt в ClusterIssuer letsencrypt-prod"
  default     = null
}

variable "telegram_chat_id" {
  type        = string
  description = "ID чата/группы Telegram, куда будут отправляться алерты (отрицательное число для групп)"
}

variable "telegram_user_id" {
  type        = string
  description = "ID пользователя-администратора Telegram (положительное число)"
}

# Токен Telegram-бота. Чувствительные данные — не выводится в terraform output и
# не попадает в git (terraform.tfvars в .gitignore). Используется для создания
# Secret impulse-telegram-secrets в namespace impulse через kubectl (null_resource),
# чтобы не хранить токен в values-файле, который рендерится на диск.
variable "bot_token" {
  type        = string
  description = "Токен Telegram-бота вида 123456789:ABCdefGhI-jklMnoPQRstuVwxYZ"
  sensitive   = true
}
