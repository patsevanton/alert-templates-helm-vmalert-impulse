# Получаем информацию о конфигурации клиента Yandex
data "yandex_client_config" "client" {}

# Создание сервисного аккаунта для управления Kubernetes
resource "yandex_iam_service_account" "sa-k8s-editor" {
  name = "sa-k8s-editor" # Имя сервисного аккаунта
}

# Назначение роли "editor" сервисному аккаунту на уровне папки
resource "yandex_resourcemanager_folder_iam_member" "sa-k8s-editor-permissions" {
  role      = "editor" # Роль, дающая полные права на ресурсы папки
  folder_id = data.yandex_client_config.client.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.sa-k8s-editor.id}" # Назначаемый участник
}

# Пауза, чтобы изменения IAM успели примениться до создания кластера
resource "time_sleep" "wait_sa" {
  create_duration = "20s"
  depends_on = [
    yandex_iam_service_account.sa-k8s-editor,
    yandex_resourcemanager_folder_iam_member.sa-k8s-editor-permissions
  ]
}

# Создание Kubernetes-кластера в Yandex Cloud
resource "yandex_kubernetes_cluster" "impulse" {
  name       = "impulse"                     # Имя кластера
  network_id = yandex_vpc_network.impulse.id # Сеть, к которой подключается кластер

  master {
    version = "1.33" # Версия Kubernetes мастера
    zonal {
      zone      = yandex_vpc_subnet.impulse-a.zone # Зона размещения мастера
      subnet_id = yandex_vpc_subnet.impulse-a.id   # Подсеть для мастера
    }

    public_ip = true # Включение публичного IP для доступа к мастеру
  }

  # Сервисный аккаунт для управления кластером и нодами
  service_account_id      = yandex_iam_service_account.sa-k8s-editor.id
  node_service_account_id = yandex_iam_service_account.sa-k8s-editor.id

  release_channel = "STABLE" # Канал обновлений

  # Зависимость от ожидания применения IAM-ролей.
  # При destroy кластер должен удалиться ДО time_sleep.wait_lb_release (пауза перед освобождением IP),
  # чтобы cloud-controller-manager успел снять LoadBalancer с адреса yandex_vpc_address.addr.
  depends_on = [
    time_sleep.wait_sa,
    time_sleep.wait_lb_release,
  ]
}

# Группа узлов для Kubernetes-кластера
resource "yandex_kubernetes_node_group" "k8s-node-group" {
  description = "Node group for the Managed Service for Kubernetes cluster"
  name        = "k8s-node-group"
  cluster_id  = yandex_kubernetes_cluster.impulse.id
  version     = "1.33" # Версия Kubernetes на нодах

  scale_policy {
    fixed_scale {
      size = 3 # Фиксированное количество нод
    }
  }

  allocation_policy {
    # Распределение нод по зонам отказоустойчивости
    location { zone = yandex_vpc_subnet.impulse-a.zone }
    location { zone = yandex_vpc_subnet.impulse-b.zone }
    location { zone = yandex_vpc_subnet.impulse-d.zone }
  }

  instance_template {
    platform_id = "standard-v2" # Тип виртуальной машины

    network_interface {
      nat = false # Публичный IP выключен, исходящий трафик через NAT-шлюз
      subnet_ids = [
        yandex_vpc_subnet.impulse-a.id,
        yandex_vpc_subnet.impulse-b.id,
        yandex_vpc_subnet.impulse-d.id
      ]
    }

    resources {
      memory = 4 # ОЗУ
      cores  = 2 # Кол-во ядер CPU
    }

    boot_disk {
      type = "network-ssd" # Тип диска
      size = 30            # Размер диска
    }
  }
}

provider "helm" {
  kubernetes = {
    host                   = yandex_kubernetes_cluster.impulse.master[0].external_v4_endpoint
    cluster_ca_certificate = yandex_kubernetes_cluster.impulse.master[0].cluster_ca_certificate

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["k8s", "create-token"]
      command     = "yc"
    }
  }
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  chart            = "oci://cr.yandex/yc-marketplace/yandex-cloud/ingress-nginx/chart/ingress-nginx"
  version          = "4.13.0"
  namespace        = "ingress-nginx"
  create_namespace = true

  depends_on = [
    yandex_kubernetes_cluster.impulse,
    yandex_kubernetes_node_group.k8s-node-group,
    time_sleep.wait_lb_release,
  ]

  values = [
    yamlencode({
      controller = {
        service = {
          loadBalancerIP = yandex_vpc_address.addr.external_ipv4_address[0].address
        }
        config = {
          log-format-escape-json = "true"
          log-format-upstream = trimspace(<<-EOT
            {"ts":"$time_iso8601","http":{"request_id":"$req_id","method":"$request_method","status_code":$status,"url":"$host$request_uri","host":"$host","uri":"$request_uri","request_time":$request_time,"user_agent":"$http_user_agent","protocol":"$server_protocol","trace_session_id":"$http_trace_session_id","server_protocol":"$server_protocol","content_type":"$sent_http_content_type","bytes_sent":"$bytes_sent"},"nginx":{"x-forward-for":"$proxy_add_x_forwarded_for","remote_addr":"$proxy_protocol_addr","http_referrer":"$http_referer"}}
          EOT
          )
        }
      }
    })
  ]
}

locals {
  lb_ip = yandex_vpc_address.addr.external_ipv4_address[0].address

  # Email для ClusterIssuer: если var.acme_email не задан — формируем из IP балансировщика.
  acme_email = coalesce(var.acme_email, "admin@cert-manager.${yandex_vpc_address.addr.external_ipv4_address[0].address}.sslip.io")

  vmks_values = templatefile("${path.module}/values/vmks-values.yaml.tftpl", {
    lb_ip = local.lb_ip
  })

  impulse_values = templatefile("${path.module}/values/values-impulse.yaml.tftpl", {
    lb_ip                      = local.lb_ip
    telegram_chat_id           = var.telegram_chat_id
    telegram_admin_id          = var.telegram_admin_id
    telegram_teamlead_id       = var.telegram_teamlead_id
    telegram_support_oncall_id = var.telegram_support_oncall_id
  })

  cluster_issuer = templatefile("${path.module}/cluster-issuer.yaml.tftpl", {
    acme_email = local.acme_email
  })

  # Рендер манифеста Secret impulse-telegram-secrets из шаблона с токеном бота.
  # Токен кодируется в base64 для поля data Secret. Применяется пользователем
  # вручную через kubectl apply -f impulse-telegram-secret.yaml после terraform apply
  # (kubectl не вызывается из Terraform — это избегает проблем с доступом к API
  # кластера во время apply). При смене bot_token повторный terraform apply
  # перегенерирует файл, затем его нужно повторно применить kubectl apply -f.
  telegram_secret = templatefile("${path.module}/impulse-telegram-secret.yaml.tftpl", {
    bot_token_b64 = base64encode(var.bot_token)
  })
}

# Рендер values-файлов из шаблонов с актуальным IP балансировщика (sslip.io-хосты)
resource "local_file" "vmks_values" {
  content         = local.vmks_values
  filename        = "${path.module}/values/vmks-values.yaml"
  file_permission = "0644"
}

resource "local_file" "impulse_values" {
  content         = local.impulse_values
  filename        = "${path.module}/values/values-impulse.yaml"
  file_permission = "0644"
}

# Рендер cluster-issuer.yaml из шаблона с актуальным email
resource "local_file" "cluster_issuer" {
  content         = local.cluster_issuer
  filename        = "${path.module}/cluster-issuer.yaml"
  file_permission = "0644"
}

# Рендер манифеста Secret impulse-telegram-secrets из шаблона с токеном бота.
# Применяется пользователем вручную через `kubectl apply -f impulse-telegram-secret.yaml`
# после `terraform apply`. При смене bot_token повторный `terraform apply` перегенерирует
# файл — его нужно повторно применить через `kubectl apply -f`.
resource "local_file" "impulse_telegram_secret" {
  content         = local.telegram_secret
  filename        = "${path.module}/impulse-telegram-secret.yaml"
  file_permission = "0644"
}

# Вывод команды для получения kubeconfig
output "k8s_cluster_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.impulse.id} --external --force"
}

# URL сервисов формируются через sslip.io из публичного IP балансировщика ingress-nginx:
# <anything>.<IP>.sslip.io всегда резолвится в <IP>. Публичный DNS не требуется.
output "lb_ip" {
  description = "Публичный IP балансировщика ingress-nginx (используется для sslip.io-хостов)"
  value       = local.lb_ip
}

output "grafana_url" {
  description = "URL Grafana (сформирован через sslip.io из публичного IP балансировщика)"
  value       = "https://grafana.${local.lb_ip}.sslip.io"
}

output "vmsingle_url" {
  description = "URL VictoriaMetrics vmsingle (сформирован через sslip.io)"
  value       = "https://vmsingle.${local.lb_ip}.sslip.io"
}

output "alertmanager_url" {
  description = "URL Alertmanager (сформирован через sslip.io)"
  value       = "https://alertmanager.${local.lb_ip}.sslip.io"
}

output "vmalert_url" {
  description = "URL vmalert (сформирован через sslip.io)"
  value       = "https://vmalert.${local.lb_ip}.sslip.io"
}

output "impulse_url" {
  description = "URL Impulse (сформирован через sslip.io из публичного IP балансировщика)"
  value       = "https://impulse.${local.lb_ip}.sslip.io"
}

output "grafana_admin_user" {
  description = "Логин администратора Grafana (дефолт чарта victoria-metrics-k8s-stack)"
  value       = "admin"
}

output "grafana_admin_password_command" {
  description = "Команда для получения пароля администратора Grafana из Secret (пароль автогенерируется helm-чартом vmks при установке)"
  value       = "kubectl get secret vmks-grafana -n vmks -o jsonpath='{.data.admin-password}' | base64 -d && echo"
}
