# Развёртывание инфраструктуры: Terraform + VLESS-прокси + cert-manager

Этот файл описывает шаги 1–3 деплоя демонстрационного кластера vmalert + Impulse
в Kubernetes на Yandex Cloud: разворот инфраструктуры через Terraform (кластер
K8s, ingress-nginx, статический публичный IP, рендер values из `.tftpl`),
настройку VLESS-прокси (mihomo) для отправки алертов Impulse в Telegram и
установку cert-manager для автоматического выпуска TLS-сертификатов. Сама
статья про шаблонизацию правил алертов, Impulse и Telegram — в
[README.md](README.md).

## Шаг 1. Развёртывание инфраструктуры через Terraform

Terraform создаёт кластер Managed Kubernetes, статический публичный IP для
балансировщика ingress-nginx, VPC-сеть с NAT-шлюзом (ноды без публичных IP),
устанавливает ingress-nginx через `helm_release`, а также генерирует из
шаблонов `values/*.tftpl` файлы `values/vmks-values.yaml`,
`values/values-impulse.yaml`, `impulse-telegram-secret.yaml`,
`mihomo-vless-proxy.yaml` и `cluster-issuer.yaml` с уже подставленным IP
балансировщика и значениями переменных (`acme_email`, `telegram_chat_id`,
`telegram_admin_id`, `bot_token`, `vless_subscription_url`).

### Требования

- [yc CLI](https://yandex.cloud/ru/docs/cli/), настроенный и аутентифицированный (`yc init`)
- [Terraform](https://www.terraform.io/) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/) и [Helm](https://helm.sh/)

### Переменные Terraform

Переменные задаются в `terraform.tfvars` (файл в `.gitignore`, не коммитится —
содержит чувствительные данные):

```bash
cat > terraform.tfvars <<'EOF'
telegram_chat_id       = "<ваш telegram_chat_id>"
telegram_admin_id      = "<ваш telegram_admin_id>"
telegram_teamlead_id   = "<ваш telegram_teamlead_id>"
telegram_support_id    = "<ваш telegram_support_id>"
bot_token              = "<ваш bot-token вида 123456789:ABCdefGhI-jklMnoPQRstuVwxYZ>"
vless_subscription_url = "<URL вашей VLESS-подписки>"
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
`values-impulse.yaml` с актуальными sslip.io-хостами и env-переменными прокси
(`HTTPS_PROXY` → `mihomo-proxy.mihomo.svc.cluster.local:1080`), а в корне —
`impulse-telegram-secret.yaml` (манифест Namespace `impulse` + Secret
`impulse-telegram-secrets` с ключом `bot-token` в base64),
`mihomo-vless-proxy.yaml` (манифест Namespace `mihomo` + Secret с URL
VLESS-подписки + Deployment + Service + NetworkPolicy) и `cluster-issuer.yaml`
(ClusterIssuer Let's Encrypt с подставленным `acme_email`). URL сервисов и IP
балансировщика выводятся в `terraform output`:

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
нужна. IP балансировщика ingress-nginx известен только после `terraform apply`,
поэтому values-файлы рендерятся Terraform из шаблонов `values/*.tftpl` (через
`local_file` в `k8s.tf`) с подстановкой реального IP.

После любого изменения шаблона: `terraform apply` → `helm upgrade ... -f values/<file>.yaml`.

## Шаг 2. VLESS-прокси для отправки алертов Impulse в Telegram (mihomo)

Telegram API (`api.telegram.org`) с IP Yandex Cloud может быть недоступен или
нестабилен из-за гео-ограничений провайдеров. Поэтому исходящий трафик Impulse
в Telegram пускается через VLESS-прокси **только для доменов Telegram** —
остальные идут напрямую, экономя VLESS-трафик.

Этот шаг нужно выполнить **сразу после `terraform apply` и до установки
Impulse**, чтобы Impulse с первого старта ходил в Telegram через прокси.

Готовый манифест [`mihomo-vless-proxy.yaml.tftpl`](mihomo-vless-proxy.yaml.tftpl)
(рендерится Terraform в `mihomo-vless-proxy.yaml`) поднимает
[mihomo](https://github.com/MetaCubeX/mihomo) (ядро Clash.Meta, ест
VLESS-подписку напрямую) как отдельный Deployment + Service в кластере:

```
                          ┌── telegram.org / t.me / api.telegram.org ──► VLESS ──► Telegram API
Impulse pod ──HTTPS_PROXY──► mihomo-proxy.mihomo.svc.cluster.local:1080
                          └── всё остальное ──► DIRECT (напрямую)
```

Правила маршрутизации в `mihomo-vless-proxy.yaml.tftpl` (секция `rules`)
отправляют в VLESS только `DOMAIN-SUFFIX,telegram.org`, `DOMAIN-SUFFIX,t.me` и
другие Telegram-домены; всё остальное идёт через `DIRECT`. Плюс: не нужен
sidecar/kustomize/форк чарта Impulse — всё голыми манифестами.

### Шаг 2.1. Заполнить `vless_subscription_url` в `terraform.tfvars`

URL VLESS-подписки указывается в `terraform.tfvars` (файл в `.gitignore`):

```bash
vless_subscription_url = "https://sub.example.com/ВАША_VLESS_ПОДПИСКА"
```

Terraform подставит его в `mihomo-vless-proxy.yaml` (поле
`proxy-providers.sub.url` в Secret `mihomo-vless-proxy`) при `terraform apply`.

> Аутентификация на mixed-порту в этом манифесте **не включена** — прокси
> маршрутизирует только Telegram-домены, доступ ограничен NetworkPolicy, а
> пароль в `HTTPS_PROXY` не нужен.

**Важно: фильтр зарубежных серверов.** В `proxy-groups.auto` уже заданы
`filter` / `exclude-filter`, оставляющие только зарубежные серверы (Нидерланды,
Германия, Франция, Финляндия и т.д.) и исключающие РФ-серверы. Если ваша
подписка использует другие названия стран — отрегулируйте regex под них в
`mihomo-vless-proxy.yaml.tftpl`, иначе mihomo выберет РФ-сервер:

```yaml
proxy-groups:
  - name: auto
    type: url-test
    use: [sub]
    filter: "(?i)(Нидерланды|Германия|Франция|Великобритания|Финляндия|Швеция|Польша|Литва|Румыния|Австрия|Швейцария|Норвегия|США|USA|Англия|Европа|EU)"
    exclude-filter: "(?i)Россия|Russia|Москва|СПб|Москва"
    tolerance: 50
    url: https://www.gstatic.com/generate_204
```

### Шаг 2.2. Применить манифест

```bash
kubectl apply -f mihomo-vless-proxy.yaml
```

Проверяем, что подписка скачалась:

```bash
kubectl -n mihomo logs deploy/mihomo-proxy
kubectl -n mihomo get pods
```

### Шаг 2.3. Переменные прокси уже в values-impulse.yaml

Terraform генерирует `values/values-impulse.yaml` из шаблона
[`values/values-impulse.yaml.tftpl`](values/values-impulse.yaml.tftpl) **уже с
переменными прокси** (без пароля — аутентификация не используется), поэтому
дописывать ничего руками не нужно. Секция `config.env` в сгенерированном файле
выглядит так:

```yaml
config:
  env:
    LOG_LEVEL: "DEBUG"
    HTTPS_PROXY: "http://mihomo-proxy.mihomo.svc.cluster.local:1080"
    https_proxy: "http://mihomo-proxy.mihomo.svc.cluster.local:1080"
    NO_PROXY: "127.0.0.1,localhost,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    no_proxy: "127.0.0.1,localhost,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
```

Impulse использует `aiohttp.ClientSession` с `trust_env=True`
(`app/http_client/session.py`), поэтому читает env-переменные
`HTTPS_PROXY`/`http_proxy`/`NO_PROXY` из окружения и маршрутизирует запросы к
`api.telegram.org` через mihomo → VLESS. Внутрикластерный трафик (webhook из
Alertmanager в Impulse — `http://impulse.impulse.svc.cluster.local:5000/`) идёт
мимо прокси благодаря `NO_PROXY`.

### Проверка (после установки Impulse на шаге 5 в README.md)

```bash
# Проверка прокси напрямую из debug-пода (curlimages/curl) с явным -x:
kubectl -n impulse run curl-debug --rm -i --restart=Never \
  --image=curlimages/curl:8.10.0 -- \
  curl -sS -x http://mihomo-proxy.mihomo.svc.cluster.local:1080 \
  -o /dev/null -w "HTTP %{http_code}\n" \
  https://api.telegram.org/
# HTTP 200 — прокси пробрасывает api.telegram.org через VLESS
```

### Замечания по безопасности

- Аутентификация на mixed-порту mihomo **не включена** — прокси маршрутизирует
  только Telegram-домены, остальное идёт напрямую, а доступ к Service ограничен
  NetworkPolicy.
- NetworkPolicy ограничивает доступ только подами из namespace `impulse` (где
  живёт Impulse) — работает, если CNI поддерживает NetworkPolicy
  (Calico/Cilium); flannel его игнорирует.
- Если URL подписки сам заблокирован провайдером: скачайте подписку вручную,
  вставьте серверы в `proxies:` (формат clash) вместо `proxy-providers` и
  замените `use: [sub]` на имена/фильтр этих серверов в `proxy-groups`.

## Шаг 3. cert-manager: автоматические TLS-сертификаты

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
