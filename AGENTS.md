# AGENTS.md

Operational notes for working with this repo's infrastructure (Yandex Cloud + K8s + Impulse + vmalert + Telegram).

## Требование к версии Kubernetes

Кластер проверен на **Managed Kubernetes 1.33** (release channel `STABLE`). В `k8s.tf` версия жёстко задана как `1.33` и для master, и для node group. Согласно общему правилу репозитория — обновлять компоненты инфраструктуры, кроме k8s и ingress-nginx, без явного указания не изменять версии k8s и ingress-nginx.

## Структура проекта

| Файл / каталог | Назначение |
|---|---|
| `versions.tf` | Провайдеры Terraform: `yandex`, `helm`, `time`, `local` |
| `net.tf` | VPC-сеть `impulse`, 3 подсети (a/b/d), NAT-шлюз + route table для исходящего трафика из приватных подсетей (ноды без публичных IP) |
| `ip-dns.tf` | Ресурс `yandex_vpc_address.addr` — статический публичный IP балансировщика ingress-nginx. DNS-зона не создаётся: имена формируются через sslip.io |
| `k8s.tf` | K8s-кластер + node group (3 ноды, `nat=false`), `helm_release` ingress-nginx, `locals` + `local_file` для рендера values из `.tftpl`, `output` для URL сервисов |
| `cluster-issuer.yaml` | ClusterIssuer Let's Encrypt для cert-manager. **Сейчас не применяется** (TLS выключен) — см. секцию «TLS / cert-manager» |
| `values/vmks-values.yaml.tftpl` | Шаблон values victoria-metrics-k8s-stack (Grafana, vmcluster, alertmanager, vmalert). Рендерится Terraform в `values/vmks-values.yaml` (в `.gitignore`) |
| `values/values-impulse.yaml.tftpl` | Шаблон values Impulse (Telegram, ingress). Рендерится в `values/values-impulse.yaml` (в `.gitignore`) |
| `values-telegram_impulse.yaml` | **Справочный пример** альтернативной конфигурации Impulse — см. отдельную секцию ниже |
| `chart/` | Helm-чарт demo-приложения Golden Signal: `Chart.yaml`, `values.yaml`, `templates/` (`_helpers.tpl`, `deployment.yaml`, `service.yaml`, `servicemonitor.yaml`, `vmrule.yaml`) |
| `app/` | Исходники demo-приложения на Go (`main.go`, `go.mod`, `Dockerfile`): HTTP-эндпоинты `/` и `/work`, метрики Prometheus `app_requests_total` / `app_errors_total` / `app_request_latency_seconds` / `app_goroutines`, фоновый генератор трафика |
| `test_install_impulse.md` | Черновик команд установки Impulse (справочно) |
| `cleanup-helm-releases.sh` | Скрипт очистки helm-релизов |

### Рендер values из `.tftpl`

IP балансировщика известен только после `terraform apply`, поэтому статичные values не годятся. Шаблоны лежат в `values/*.tftpl` с плейсхолдером `${lb_ip}`; `k8s.tf` рендерит их через `templatefile` и пишет в `values/*.yaml` ресурсами `local_file`. Отрендеренные `.yaml` добавлены в `.gitignore` — в git хранятся только `.tftpl`. После любого изменения шаблона: `terraform apply` → `helm upgrade ... -f values/<file>.yaml`.

### Именование сервисов (sslip.io)

Все публичные имена — `<сервис>.<LB_IP>.sslip.io` (Grafana, vmselect, alertmanager, vmalert, impulse). sslip.io — wildcard-DNS: `<anything>.<IP>.sslip.io` резолвится в `<IP>`. Собственная DNS-зона не нужна (в `ip-dns.tf` удалена). IP берётся из `terraform output lb_ip`.

## values-telegram_impulse.yaml (разобраться)

Файл `values-telegram_impulse.yaml` лежит в корне репозитория и **не подключён к Terraform** (не рендерится из `.tftpl`, не упоминается в `k8s.tf`). Это справочный пример альтернативной конфигурации Impulse, отличающийся от рабочего `values/values-impulse.yaml.tftpl`:

| Аспект | `values/values-impulse.yaml.tftpl` (рабочий) | `values-telegram_impulse.yaml` (пример) |
|---|---|---|
| Рендер Terraform | да (`local_file` в `k8s.tf`) | нет (статичный) |
| Хост ingress | `impulse.${lb_ip}.sslip.io` | нет ingress |
| TLS / cert-manager | выключено (см. ниже) | нет |
| `chains` (эскалация) | нет | есть (`default`: admin_user, wait 10m) |
| `incident.notifications` | `new_firing: false` | `new_firing/partial_resolved/status_update: true` |
| `incident.timeouts` | нет | есть (firing 6h, unknown 6h, resolved 12h) |
| `ui.columns/sorting/colors` | нет | есть (status/created/alertname/service/severity) |
| `persistence` | нет | есть (1Gi) |
| `secrets` | `existing` (Secret `impulse-telegram-secrets`) | `inline` (токен в values — для dev) |
| `image` | из чарта Impulse по умолчанию | `ghcr.io/eslupmi/impulse` явно |

**Открытые вопросы по файлу** (требуют решения владельцем репозитория):
- [ ] Определить судьбу файла: оставить как справочный пример / конвертировать в `values/values-telegram_impulse.yaml.tftpl` с рендером через `local_file` / удалить. Сейчас README упоминает его как «пример альтернативной конфигурации».
- [ ] Если решено оставить как пример — вынести `botToken` из `secrets.inline` (сейчас в файле плейсхолдер `your-telegram-bot-token`, но сам паттерн `inline` небезопасен для коммита).
- [ ] Если решено конвертировать в `.tftpl` — добавить `ingress` с `impulse.${lb_ip}.sslip.io` (сейчас ingress отсутствует, Impulse не будет доступен снаружи).
- [ ] `chains.default` ссылается на `admin_user` — убедиться, что этот ключ совпадает с `admin_users` и `users.admin_user.id` из рабочего шаблона.

## Helm-чарт Impulse

Impulse устанавливается через Helm вручную (шаг 5 в README), не через `helm_release` в Terraform. Команда установки описана в двух местах:

| Файл | Назначение | Команда |
|---|---|---|
| `README.md` (шаг 5) | Рабочая инструкция для пользователя | `helm install my-impulse impulse/impulse --version 1.0.14 -f values/values-impulse.yaml` |
| `test_install_impulse.md` | Черновик команд (справочно) | то же |

**Параметры установки:**
- репо: `https://eslupmi-community.github.io/helm-charts`
- чарт: `impulse/impulse`
- версия: `1.0.14`
- release name: `my-impulse`
- values: `values/values-impulse.yaml` (рендерится Terraform из `values/values-impulse.yaml.tftpl`)
- namespace: `impulse` (создаётся `--create-namespace`)

**Открытые вопросы по helm-чарту Impulse** (требуют решения владельцем репозитория):
- [ ] Рассмотреть вынос установки Impulse в `helm_release` в `k8s.tf` (по аналогии с `ingress_nginx`) — но только после того, как источник чарта станет стабильным.
- [ ] Рассмотреть удаление `test_install_impulse.md` как дубликата README.

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

**Текущее состояние: TLS выключен.** Все ingress (Grafana, vmselect, alertmanager, vmalert, Impulse) работают по HTTP, `nginx.ingress.kubernetes.io/ssl-redirect: "false"` в `values/vmks-values.yaml.tftpl`. В `values/values-impulse.yaml.tftpl` убраны `cert-manager.io/cluster-issuer`, `kubernetes.io/tls-acme` и блок `tls`; `impulse_address` изменён на `http://`.

**Почему это проблема:** Telegram Bot API принимает webhooks и callback-адреса только по HTTPS. Без HTTPS Telegram-интеграция Impulse (`impulse_address` для кнопок callback) работать не будет.

**Что нужно сделать для включения TLS (задача зафиксирована здесь как TODO):**
- [ ] Установить cert-manager (`helm upgrade --install cert-manager ...` — команда в README, шаг 2).
- [ ] Применить `cluster-issuer.yaml` (`kubectl apply -f cluster-issuer.yaml`). Указать реальный email вместо `my-email@mycompany.com`.
- [ ] В `values/values-impulse.yaml.tftpl`: вернуть аннотации `cert-manager.io/cluster-issuer: letsencrypt-prod` и `kubernetes.io/tls-acme: "true"`, блок `tls` с `secretName: impulse-tls`, изменить `impulse_address` на `https://impulse.${lb_ip}.sslip.io`.
- [ ] В `values/vmks-values.yaml.tftpl`: для каждого ingress (grafana / vmcluster.select / alertmanager / vmalert) поменять `ssl-redirect: "false"` → `"true"` и добавить аннотацию `cert-manager.io/cluster-issuer: letsencrypt-prod` + блок `tls`.
- [ ] В `k8s.tf`: поменять `output.impulse_url` с `http://` на `https://`.
- [ ] В README: убрать пометку «TLS выключен» из блока вверху и описания шага 2 / секции «Доступ к сервисам».

> sslip.io поддерживает валидацию Let's Encrypt HTTP-01 (ClusterIssuer `http01.ingress.class: nginx`), так что сертификаты для `<сервис>.<LB_IP>.sslip.io` выпустятся без проблем.

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
