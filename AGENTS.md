# AGENTS.md

Operational notes for working with this repo's infrastructure (Yandex Cloud + K8s + Impulse + vmalert + Telegram).

## Требование к версии Kubernetes

Кластер проверен на **Managed Kubernetes 1.33** (release channel `STABLE`). В `k8s.tf` версия жёстко задана как `1.33` и для master, и для node group. Согласно общему правилу репозитория — обновлять компоненты инфраструктуры, кроме k8s и ingress-nginx, без явного указания не изменять версии k8s и ingress-nginx.

## Структура проекта

| Файл / каталог | Назначение |
|---|---|
| `versions.tf` | Провайдеры Terraform: `yandex`, `helm`, `time`, `local`, `null`. Переменные `acme_email`, `telegram_chat_id`, `telegram_admin_id`, `bot_token` |
| `net.tf` | VPC-сеть `impulse`, 3 подсети (a/b/d), NAT-шлюз + route table для исходящего трафика из приватных подсетей (ноды без публичных IP) |
| `ip-dns.tf` | Ресурс `yandex_vpc_address.addr` — статический публичный IP балансировщика ingress-nginx. DNS-зона не создаётся: имена формируются через sslip.io |
| `k8s.tf` | K8s-кластер + node group (3 ноды, `nat=false`), `helm_release` ingress-nginx, `locals` + `local_file` для рендера values из `.tftpl` и манифеста Secret `impulse-telegram-secrets`, `output` для URL сервисов |
| `cluster-issuer.yaml` | ClusterIssuer Let's Encrypt для cert-manager. Применяется пользователем вручную `kubectl apply -f cluster-issuer.yaml` — см. секцию «TLS / cert-manager» |
| `impulse-telegram-secret.yaml.tftpl` | Шаблон манифеста Secret `impulse-telegram-secrets` (Namespace + Secret с `bot-token` в base64). Рендерится Terraform в `impulse-telegram-secret.yaml` (в `.gitignore`), применяется пользователем вручную `kubectl apply -f` |
| `values/vmks-values.yaml.tftpl` | Шаблон values victoria-metrics-k8s-stack (Grafana, vmcluster, alertmanager, vmalert). Рендерится Terraform в `values/vmks-values.yaml` (в `.gitignore`) |
| `values/values-impulse.yaml.tftpl` | Шаблон values Impulse (Telegram, ingress). Рендерится в `values/values-impulse.yaml` (в `.gitignore`) |
| `chart/` | Helm-чарт demo-приложения Golden Signal: `Chart.yaml`, `values.yaml`, `templates/` (`_helpers.tpl`, `deployment.yaml`, `service.yaml`, `servicemonitor.yaml`, `vmrule.yaml`) |
| `app/` | Исходники demo-приложения на Go (`main.go`, `go.mod`, `Dockerfile`): HTTP-эндпоинты `/` и `/work`, метрики Prometheus `app_requests_total` / `app_errors_total` / `app_request_latency_seconds` / `app_goroutines`, фоновый генератор трафика |
| `test_install_impulse.md` | Черновик команд установки Impulse (справочно) |
| `cleanup-helm-releases.sh` | Скрипт очистки helm-релизов |

### Рендер values из `.tftpl`

IP балансировщика известен только после `terraform apply`, поэтому статичные values не годятся. Шаблоны лежат в `values/*.tftpl` с плейсхолдером `${lb_ip}`; `k8s.tf` рендерит их через `templatefile` и пишет в `values/*.yaml` ресурсами `local_file`. Отрендеренные `.yaml` добавлены в `.gitignore` — в git хранятся только `.tftpl`. После любого изменения шаблона: `terraform apply` → `helm upgrade ... -f values/<file>.yaml`.

### Именование сервисов (sslip.io)

Все публичные имена — `<сервис>.<LB_IP>.sslip.io` (Grafana, vmsingle, alertmanager, vmalert, impulse). sslip.io — wildcard-DNS: `<anything>.<IP>.sslip.io` резолвится в `<IP>`. Собственная DNS-зона не нужна (в `ip-dns.tf` удалена). IP берётся из `terraform output lb_ip`.

## Helm-чарт Impulse

Impulse устанавливается через Helm вручную (шаг 5 в README), не через `helm_release` в Terraform. Команда установки описана в двух местах:

| Файл | Назначение | Команда |
|---|---|---|
| `README.md` (шаг 5) | Рабочая инструкция для пользователя | `helm install impulse impulse/impulse --version 1.0.15 -f values/values-impulse.yaml` |
| `test_install_impulse.md` | Черновик команд (справочно) | то же |

**Параметры установки:**
- репо: `https://eslupmi-community.github.io/helm-charts`
- чарт: `impulse/impulse`
- версия: `1.0.15`
- release name: `impulse`
- values: `values/values-impulse.yaml` (рендерится Terraform из `values/values-impulse.yaml.tftpl`)
- namespace: `impulse` (создаётся `--create-namespace`)

**Открытые вопросы по helm-чарту Impulse** (требуют решения владельцем репозитория):
- [ ] Рассмотреть вынос установки Impulse в `helm_release` в `k8s.tf` (по аналогии с `ingress_nginx`) — но только после того, как источник чарта станет стабильным.
- [ ] Рассмотреть удаление `test_install_impulse.md` как дубликата README.

**Ждём мерджа PR #11 (https://github.com/eslupmi-community/helm-charts/pull/11):**
PR меняет пробы deployment Impulse: `livenessProbe` `/queue` → `/livez` (всегда `200`, даже в standby), `readinessProbe` `/queue` → `/readyz` (`200` primary, `503` standby). Исправляет баг, когда kubelet убивал standby-поды по liveness-пробе во время rolling update (проблема #10). После мерджа и публикации новой версии чарта в репо `https://eslupmi-community.github.io/helm-charts`:
- [ ] Обновить `version` (с `1.0.14`) на новую версию чарта `impulse/impulse` везде, где упоминается установка: `README.md` (шаг 5) и `test_install_impulse.md`.
- [ ] Проверить, что `helm repo update` подтянул новую версию, и переустановить релиз: `helm upgrade impulse impulse/impulse --version <новая> -f values/values-impulse.yaml -n impulse`.
- [ ] Проверить, что standby-поды больше не рестартятся во время rolling update (`kubectl get pods -n impulse` — `RESTARTS=0`).
- [ ] Замечание: PR #11 НЕ решает дедлок rolling update при `replicaCount: 1` + RWO PVC (новый под зависает в standby, пока старый primary держит HA file lock) — это отдельная задача уровня deployment-strategy (см. issue #10).

## Пароль Grafana (обработка как в соседнем проекте)

Пароль администратора Grafana автогенерируется helm-чартом `victoria-metrics-k8s-stack` в Secret `vmks-grafana` (namespace `vmks`, ключ `admin-password`). В Terraform сам пароль **не хранится** — выводится только команда для его извлечения, по образцу соседнего проекта `nginx-vts-vs-angie` (`k8s.tf`: `output grafana_admin_password_command`).

- `output.grafana_admin_user` → `admin` (дефолт чарта)
- `output.grafana_admin_password_command` → `kubectl get secret vmks-grafana -n vmks -o jsonpath='{.data.admin-password}' | base64 -d && echo`

Получение пароля одной командой:

```bash
terraform output -raw grafana_admin_password_command | sh
```

> Не выводить сам пароль в `terraform output` и не коммитить `.tfstate` с паролем (`.tfstate` уже в `.gitignore`).

## TLS / cert-manager

**Текущее состояние: TLS включён.** Все публичные ingress (Grafana, vmsingle, alertmanager, vmalert, Impulse) работают по HTTPS через cert-manager + Let's Encrypt (ClusterIssuer `letsencrypt-prod`, HTTP-01 challenge через ingress class `nginx`). В `values/vmks-values.yaml.tftpl` для каждого ingress стоит `nginx.ingress.kubernetes.io/ssl-redirect: "true"` + аннотация `cert-manager.io/cluster-issuer: letsencrypt-prod` + блок `tls` с индивидуальным `secretName`. В `values/values-impulse.yaml.tftpl` аннотации `cert-manager.io/cluster-issuer: letsencrypt-prod`, `kubernetes.io/tls-acme: "true"`, блок `tls` (`secretName: impulse-tls`) и `impulse_address: "https://impulse.${lb_ip}.sslip.io"`. В `k8s.tf` все `output.*_url` отдают `https://`. `cluster-issuer.yaml` применяется пользователем вручную (`kubectl apply -f cluster-issuer.yaml`), email — `admin@cert-manager.89.169.133.122.sslip.io`.

> sslip.io поддерживает валидацию Let's Encrypt HTTP-01 (ClusterIssuer `http01.ingress.class: nginx`), так что сертификаты для `<сервис>.<LB_IP>.sslip.io` выпускаются без проблем.
>
> Внутрикластерный трафик идёт по HTTP: webhook из Alertmanager в Impulse — `http://impulse.impulse.svc.cluster.local:5000/` (см. `values/vmks-values.yaml.tftpl`), внутренний self-call демо-приложения — `http://localhost:8080` (см. `app/main.go`). TLS на эти endpoints не навешивается — они не покидают кластер.

### Проверка после включения TLS

```bash
# cert-manager поды (CertificateValidated, Ready)
kubectl get pods -n cert-manager

# ClusterIssuer готов (Ready=True)
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo

# Certificates (Ready=True для каждого ingress)
kubectl get certificate -A

# Проверка HTTPS-доступа к Impulse (должен отвечать 200/3xx)
curl -sS -o /dev/null -w "Impulse HTTPS: HTTP %{http_code}\n" "https://impulse.$(terraform output -raw lb_ip).sslip.io"

# Проверка редиректа HTTP→HTTPS для Grafana (ssl-redirect: "true")
curl -sS -o /dev/null -w "Grafana redirect: HTTP %{http_code} -> %{redirect_url}\n" "http://grafana.$(terraform output -raw lb_ip).sslip.io"
```

## Команды проверки (после любых изменений инфраструктуры)

```bash
# K8s ноды
$(terraform output -raw k8s_cluster_credentials_command)
kubectl get nodes

# Ingress-nginx LB IP (должен совпадать с terraform output lb_ip)
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo

# URL сервисов
terraform output lb_ip
terraform output grafana_url
terraform output impulse_url

# Values-файлы перегенерированы (должны содержать актуальный IP из terraform output lb_ip)
rg sslip.io values/vmks-values.yaml values/values-impulse.yaml

# Поды
kubectl get pods -n vmks
kubectl get pods -n impulse
kubectl get pods -n golden-signal-app

# Ingress
kubectl get ingress -A

# Пароль Grafana
terraform output -raw grafana_admin_password_command | sh
```
