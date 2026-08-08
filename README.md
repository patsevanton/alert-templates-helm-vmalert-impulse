# Шаблонизация правил алертов в Helm и их обработка через vmalert и Impulse для отправки в Telegram

Публичные имена сервисов формируются через **sslip.io** по схеме `<сервис>.<LB_IP>.sslip.io` — это бесплатный wildcard-DNS: `<anything>.<IP>.sslip.io` всегда резолвится в `<IP>`. Собственная DNS-зона не нужна. IP балансировщика ingress-nginx известен только после `terraform apply`, поэтому values-файлы рендерятся Terraform из шаблонов `values/*.tftpl` (через `local_file` в `k8s.tf`) с подстановкой реального IP.

## Порядок развёртывания

### 1. Terraform: инфраструктура и рендер values

```bash
terraform init
terraform apply
```

После `apply` в `values/` появятся отрендеренные `vmks-values.yaml` и `values-impulse.yaml` с актуальными sslip.io-хостами. URL сервисов и IP балансировщика выводятся в `terraform output`:

```bash
terraform output lb_ip
terraform output grafana_url
terraform output vmselect_url
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

### 2. VM K8s Stack (метрики, Grafana)

Установка victoria-metrics-k8s-stack с Grafana. Values-файл уже сгенерирован Terraform с актуальным sslip.io-хостом:

```bash
helm upgrade --install vmks \
  oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
  --namespace vmks \
  --create-namespace \
  --wait \
  --version 0.90.1 \
  --timeout 15m \
  -f values/vmks-values.yaml
```

Шаблон values: [`values/vmks-values.yaml.tftpl`](values/vmks-values.yaml.tftpl) (рендерится в `values/vmks-values.yaml`).

### 3. Установка приложения через Helm

Для установки demo-приложения Golden Signal в Kubernetes-кластере используйте Helm:

```bash
helm upgrade --install golden-signal-app ./chart \
  --namespace golden-signal-app \
  --create-namespace
```

> `image.repository` и `image.tag` уже заданы в [`chart/values.yaml`](chart/values.yaml) по умолчанию, `--set` не требуется.

### Проверка статуса развертывания

```bash
kubectl get pods -n golden-signal-app -l app=golden-signal-app
```

### Проверка метрик

```bash
kubectl port-forward -n golden-signal-app svc/golden-signal-app 8080:8080
curl http://localhost:8080/metrics
curl http://localhost:8080/work
```

### 4. Настройка Telegram-бота

Для отправки уведомлений в Telegram:

1. Создайте бота через [@BotFather](https://t.me/BotFather)
2. Получите токен бота
3. Добавьте бота в чат или группу, куда будут приходить алерты (бот должен быть добавлен как участник)
4. Получите `telegram_chat_id` — ID чата/группы, куда будут отправляться уведомления:
   - Добавьте бота [@myidbot](https://t.me/myidbot) в ваш чат/группу
   - Отправьте сообщение `/getgroupid@myidbot` в чат/группу
   - Бот вернёт информацию о чате `Your group ID is: -xxxxx` — это и есть `telegram_chat_id`
   - Укажите полученный ID в `values/values-impulse.yaml.tftpl` в секции `channels.incidents_default.id`
5. Получите `telegram_user_id` для администратора:
   - Напишите боту [@userinfobot](https://t.me/userinfobot) в личные сообщения команду `/start`
   - Бот вернёт ваш `id` — это и есть `telegram_user_id`
   - Укажите полученный ID в `values/values-impulse.yaml.tftpl` в секции `users.admin_user.id`
6. Создайте Kubernetes Secret с токеном бота:

```bash
kubectl create namespace impulse
kubectl create secret generic impulse-telegram-secrets \
  --namespace impulse \
  --from-literal=bot-token='xxxxx:xxxxx-xxxxxxx'
```

> После редактирования `values/values-impulse.yaml.tftpl` выполните `terraform apply` для перегенерации `values/values-impulse.yaml`.

### 5. Установка Impulse

Для установки Impulse через Helm используйте следующие команды:

```bash
helm repo add impulse https://eslupmi.github.io/helm-charts/packages
helm repo update
helm upgrade --install impulse impulse/impulse \
  --version 1.0.6 \
  --namespace impulse \
  --create-namespace \
  -f values/values-impulse.yaml
```

Шаблон values: [`values/values-impulse.yaml.tftpl`](values/values-impulse.yaml.tftpl) (рендерится в `values/values-impulse.yaml`).

## Доступ к сервисам

URL формируются через sslip.io из публичного IP балансировщика ingress-nginx (IP берётся из `terraform output lb_ip`):

- **Grafana**: `http://grafana.<LB_IP>.sslip.io`
- **VictoriaMetrics**: `http://vmselect.<LB_IP>.sslip.io`
- **Alertmanager**: `http://alertmanager.<LB_IP>.sslip.io`
- **vmalert**: `http://vmalert.<LB_IP>.sslip.io`
- **Impulse**: `http://impulse.<LB_IP>.sslip.io`

Для получения пароля admin от Grafana:

```bash
terraform output -raw grafana_admin_password_command | sh
```

> sslip.io — бесплатный wildcard-DNS: `<anything>.<IP>.sslip.io` всегда резолвится в `<IP>`. Не требует делегирования доменной зоны.

## Структура файлов

| Файл | Описание |
|------|----------|
| [`versions.tf`](versions.tf) | Провайдеры Terraform (Yandex Cloud, Helm, Kubernetes, time) |
| [`net.tf`](net.tf) | VPC-сеть, подсети, NAT-шлюз + route table для исходящего трафика из приватных подсетей |
| [`ip-dns.tf`](ip-dns.tf) | Статический IP балансировщика (публичные имена через sslip.io, собственная DNS-зона не нужна) |
| [`k8s.tf`](k8s.tf) | K8s-кластер, ноды, Helm-релиз ingress-nginx, рендер values из `.tftpl`, `terraform output` URL |
| [`values/vmks-values.yaml.tftpl`](values/vmks-values.yaml.tftpl) | Шаблон values victoria-metrics-k8s-stack (рендерится в `values/vmks-values.yaml`) |
| [`values/values-impulse.yaml.tftpl`](values/values-impulse.yaml.tftpl) | Шаблон values Impulse (рендерится в `values/values-impulse.yaml`) |
| [`chart/`](chart) | Helm-чарт demo-приложения Golden Signal (Deployment, Service, ServiceMonitor, VMRule) |
| [`app/`](app) | Исходники demo-приложения (Go): генератор трафика + метрики Golden Signals (latency, errors, saturation) |
| [`values-telegram_impulse.yaml`](values-telegram_impulse.yaml) | Пример альтернативной конфигурации Impulse с chains, UI-колонками, persistence |
