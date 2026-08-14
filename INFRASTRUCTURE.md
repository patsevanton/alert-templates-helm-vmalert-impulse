# Развёртывание инфраструктуры: Terraform + cert-manager

Этот файл описывает шаги 1–2 деплоя демонстрационного кластера vmalert + Impulse
в Kubernetes на Yandex Cloud: разворот инфраструктуры через Terraform (кластер
K8s, ingress-nginx, статический публичный IP, рендер values из `.tftpl`) и
установку cert-manager для автоматического выпуска TLS-сертификатов. Сама
статья про шаблонизацию правил алертов, Impulse и Telegram — в
[README.md](README.md).

## Шаг 1. Развёртывание инфраструктуры через Terraform

Terraform создаёт кластер Managed Kubernetes, статический публичный IP для
балансировщика ingress-nginx, VPC-сеть с NAT-шлюзом (ноды без публичных IP),
устанавливает ingress-nginx через `helm_release`, а также генерирует из
шаблонов `values/*.tftpl` файлы `values/vmks-values.yaml`,
`values/values-impulse.yaml`, `impulse-telegram-secret.yaml` и
`cluster-issuer.yaml` с уже подставленным IP балансировщика и значениями
переменных (`acme_email`, `telegram_chat_id`, `telegram_user_id`,
`bot_token`).

### Требования

- [yc CLI](https://yandex.cloud/ru/docs/cli/), настроенный и аутентифицированный (`yc init`)
- [Terraform](https://www.terraform.io/) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/) и [Helm](https://helm.sh/)

### Переменные Terraform

Переменные задаются в `terraform.tfvars` (файл в `.gitignore`, не коммитится —
содержит чувствительные данные):

```bash
cat > terraform.tfvars <<'EOF'
telegram_chat_id = "<ваш telegram_chat_id>"
telegram_user_id = "<ваш telegram_user_id>"
bot_token        = "<ваш bot-token вида 123456789:ABCdefGhI-jklMnoPQRstuVwxYZ>"
EOF
```

Описание переменных — в [`versions.tf`](versions.tf).

### Запуск

```bash
# Клонируем репозиторий
git clone https://github.com/patsevanton/alert-templates-helm-vmalert-impulse
cd alert-templates-helm-vmalert-impulse

# Заполняем terraform.tfvars (см. выше)
terraform init
terraform apply
```

После `apply` в `values/` появятся отрендеренные `vmks-values.yaml` и
`values-impulse.yaml` с актуальными sslip.io-хостами, а в корне —
`impulse-telegram-secret.yaml` (манифест Namespace `impulse` + Secret
`impulse-telegram-secrets` с ключом `bot-token` в base64) и
`cluster-issuer.yaml` (ClusterIssuer Let's Encrypt с подставленным `acme_email`).
URL сервисов и IP балансировщика выводятся в `terraform output`:

```bash
terraform output lb_ip
terraform output grafana_url
terraform output vmsingle_url
terraform output alertmanager_url
terraform output vmalert_url
terraform output impulse_url
terraform output grafana_admin_user
terraform output grafana_admin_password_command
```

Доступ к кластеру:

```bash
$(terraform output -raw k8s_cluster_credentials_command)
kubectl get nodes
```

### Домен через sslip.io — ничего вводить не нужно

Все публичные имена сервисов формируются через **sslip.io** по схеме
`<сервис>.<LB_IP>.sslip.io` — это бесплатный wildcard-DNS:
`<anything>.<IP>.sslip.io` всегда резолвится в `<IP>`. Собственная DNS-зона не
нужда. IP балансировщика ingress-nginx известен только после `terraform apply`,
поэтому values-файлы рендерятся Terraform из шаблонов `values/*.tftpl` (через
`local_file` в `k8s.tf`) с подстановкой реального IP.

После любого изменения шаблона: `terraform apply` → `helm upgrade ... -f values/<file>.yaml`.

## Шаг 2. cert-manager: автоматические TLS-сертификаты

Для работы HTTPS с валидным TLS-сертификатом от Let's Encrypt нужен
[cert-manager](https://cert-manager.io/). Он автоматически выпускает и
обновляет сертификаты для Ingress-ресурсов.

### Установка cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.21.1 \
  --set crds.enabled=true \
  --wait
```

Проверяем, что поды cert-manager запустились:

```bash
kubectl get pods -n cert-manager
# cert-manager-xxx            1/1     Running
# cert-manager-cainjector-xxx 1/1     Running
# cert-manager-webhook-xxx    1/1     Running
```

### Создаём ClusterIssuer

Terraform уже отрендерил `cluster-issuer.yaml` из шаблона
[`cluster-issuer.yaml.tftpl`](cluster-issuer.yaml.tftpl) с подставленным
`acme_email` — редактировать его руками не нужно. Просто применяем:

```bash
kubectl apply -f cluster-issuer.yaml
```

Проверяем:

```bash
kubectl get clusterissuer letsencrypt-prod
# NAME               READY   AGE
# letsencrypt-prod   True    10s
```

> sslip.io поддерживает валидацию Let's Encrypt HTTP-01 (ClusterIssuer
> `http01.ingress.class: nginx`), так что сертификаты для
> `<сервис>.<LB_IP>.sslip.io` выпустятся без проблем.
