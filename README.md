# Шаблонизация правил алертов в Helm и их обработка через vmalert и Impulse для отправки в Telegram

## Зачем Impulse, если есть Alertmanager

Alertmanager — это stateless-«почтальон»: сгруппировал алерты, отправил в receiver (webhook/email/…), забыл. Состояния инцидента наружу он не экспортирует и интерактивности с пользователем не предоставляет. Impulse — это слой инцидент-менеджмента поверх Alertmanager: он принимает алерты как webhook-ресивер и превращает их в управляемые инциденты прямо внутри Telegram.

| Возможность | Alertmanager | Impulse |
|---|---|---|
| Группировка и дедупликация алертов (`group_by`, `group_interval`, `repeat_interval`, `inhibit_rules`) | ✅ встроено | — (получает уже сгруппированные алерты от Alertmanager) |
| Маршрутизация по receiver'ам через `route.routes` + `matchers` (severity/service/team → разные webhook'ы/чаты) | ✅ встроено | ✅ дополнительно через `impulseConfig.channels` + `route.channel` (разнесение по Telegram-чатам команд) |
| HA (cluster mode, gossip-протокол) | ✅ встроено (`--cluster.*`) | ✅ собственный HA-режим с файловым локом (primary/standby, `/readyz` 503 у standby) |
| Инцидент = отдельный топик форума Telegram (`createForumTopic`), все обновления в одном треде | ❌ нет (плоский поток сообщений в чат) | ✅ |
| Интерактивные inline-кнопки Take It / Freeze с callback на `impulse_address` (HTTPS webhook) | ❌ нет | ✅ |
| Жизненный цикл инцидента (new → ack/freeze → resolved) с синхронизацией состояния с топиком | ❌ нет (stateless по доставке: отправил и забыл) | ✅ |
| Привязка Telegram-пользователей к admin-user'ам (`users.<name>.id = telegram_user_id`) для адресации действий кнопок конкретным людям | ❌ нет (чужая зона ответственности) | ✅ |

**Кратко:** Alertmanager здесь выступает только маршрутизатором-источником (`receiver: impulse` → webhook на Impulse). Всю работу с пользователем внутри Telegram — треды, кнопки, состояния инцидента, привязку людей — делает Impulse.

## Цель статьи

Показать, как отправлять и маршрутизировать алерты от двух сервисов разных команд в их собственные Telegram-чаты. На примере demo-приложения Golden Signal и стека VictoriaMetrics разбирается: шаблонизация правил алертов в Helm, маршрутизация алертов через vmalert + Alertmanager и доставка уведомлений в Telegram через Impulse с разнесением по чатам команд.

> **Перед шагами ниже** разверните kubernetes и установите cert-manager. Дальнейшие шаги предполагают, что кластер K8s работает, ingress-nginx слушает на публичном IP, cert-manager установлен, а ClusterIssuer `letsencrypt-prod` применён.

## Порядок развёртывания

### 1. Подготовка файла конфигурации victoria-metrics-k8s-stack

```
cat <<'EOF' >> values/vmks-values.yaml
---
grafana:
  ingress:
    ingressClassName: nginx
    enabled: true
    hosts:
      - grafana.mycompany.corp
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      cert-manager.io/cluster-issuer: letsencrypt-prod
    tls:
      - secretName: grafana-tls
        hosts:
          - grafana.mycompany.corp
defaultRules:
  groups:
    etcd:
      enabled: false
    kubernetes-system-scheduler:
      enabled: false
    kubernetes-system-controller-manager:
      enabled: false
    # В Yandex Managed K8s kube-scheduler недоступен для скрейпинга,
    # поэтому recording-правила группы kube-scheduler.rules не имеют данных
    # и порождают шумный алерт RecordingRulesNoData.
    kube-scheduler.rules:
      enabled: false
# Control-plane компоненты Yandex Managed K8s (kube-controller-manager, kube-scheduler,
# kube-etcd) недоступны для скрейпинга — master управляемый и вне кластера.
# Отключаем scrape-job, иначе vmagent плодит ScrapePoolHasNoTargets,
# а vmalert — RecordingRulesNoData для пустых scrape-pool.
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
# kube-state-metrics: разрешаем собирать все labels подов (metricLabelsAllowlist).
# По умолчанию kube-state-metrics не экспортирует labels Pod-ов в своих метриках,
# чтобы не раздувать кардинальность. Список pods=[*] включает все labels —
# они нужны для правил алертов и маршрутизации (например, фильтрация по команде/сервису).
kube-state-metrics:
  metricLabelsAllowlist:
    - pods=[*]
vmsingle:
  enabled: false
vmcluster:
  enabled: true
  ingress:
    select:
      enabled: true
      ingressClassName: nginx
      annotations:
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
        cert-manager.io/cluster-issuer: letsencrypt-prod
      hosts:
        - vmselect.mycompany.corp
      tls:
        - secretName: vmselect-tls
          hosts:
            - vmselect.mycompany.corp
alertmanager:
  enabled: true
  spec:
    replicaCount: 1
    port: "9093"
    selectAllByDefault: true
    image:
      tag: v0.33.1
    externalURL: ""
    routePrefix: /
  config:
    route:
      receiver: "impulse"
      group_interval: 5m
      repeat_interval: 354m
      routes:
        - receiver: "blackhole"
          matchers:
            - severity="none"
    receivers:
      - name: impulse
        webhook_configs:
          - url: 'http://my-impulse.impulse.svc.cluster.local:5000/'
      - name: blackhole
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - alertmanager.mycompany.corp
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      cert-manager.io/cluster-issuer: letsencrypt-prod
    tls:
      - secretName: alertmanager-tls
        hosts:
          - alertmanager.mycompany.corp
vmalert:
  enabled: true
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - vmalert.mycompany.corp
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      cert-manager.io/cluster-issuer: letsencrypt-prod
    path: "/"
    pathType: Prefix
    tls:
      - secretName: vmalert-tls
        hosts:
          - vmalert.mycompany.corp
EOF
```

### 2. VM K8s Stack (метрики, Grafana)

```bash
helm upgrade --install vmks \
  oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
  --namespace vmks \
  --create-namespace \
  --wait \
  --version 0.90.2 \
  --timeout 15m \
  -f values/vmks-values.yaml
```

### 2. Установка demo-приложения Golden Signal через Helm

Demo-приложение Golden Signal написано на **Go** (`app/main.go`).

Приложение:

- Экспонирует HTTP-эндпоинты `/` (health) и `/work` (обработка запроса со случайной задержкой 100–499 мс и ~20% случайных ошибок).
- Экспортирует Prometheus-метрики на `/metrics`:
  - `app_requests_total` — счётчик входящих HTTP-запросов (counter);
  - `app_errors_total` — счётчик ответов с ошибкой (counter);
  - `app_request_latency_seconds` — гистограмма времени обработки запроса (histogram);
  - `app_goroutines` — текущее число горутин, индикатор насыщения (gauge).
- Запускает фоновый генератор трафика: каждые 2 с отправляет запрос на `/work`, чтобы метрики и алерты обновлялись постоянно.

Правила алертов задаются как **VMRule** (Custom Resource VictoriaMetrics) — манифест `chart/templates/vmrule.yaml`. VMRule применяется в кластер **вместе с установкой приложения** одним `helm upgrade --install golden-signal-app ./chart`, отдельного шага для алертов нет. vmalert автоматически подхватывает VMRule через `selectAllByDefault: true`.

Правила алертов (группа `golden-signal-alerts`):

| Алерт | Условие | For | Severity |
|---|---|---|---|
| `HighErrorRate` | `rate(app_errors_total[5m]) / rate(app_requests_total[5m]) > 0.05` | 1m | critical |
| `HighLatency` | `histogram_quantile(0.95, sum(rate(app_request_latency_seconds_bucket[5m])) by (le)) > 0.5` | 2m | warning |
| `HighGoroutineCount` | `app_goroutines > 50` | 1m | warning |

Установка приложения и его правил алертов одной командой:

```bash
helm upgrade --install golden-signal-app ./chart \
  --namespace golden-signal-app \
  --create-namespace
```

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

### 3. Настройка Telegram-бота

Для отправки уведомлений в Telegram потребуется бот и три значения: `bot-token`, `telegram_chat_id`, `telegram_user_id`.

#### Если у вас нет Telegram-бота

Создайте бота и получите его токен:

1. Напишите [@BotFather](https://t.me/BotFather) команду `/newbot`
2. Задайте имя и username бота (username должен оканчиваться на `bot`)
3. BotFather вернёт `bot-token` вида `123456789:ABCdefGhI-jklMnoPQRstuVwxYZ`
4. Добавьте созданного бота в чат или группу, куда будут приходить алерты (бот должен быть участником группы)

#### Если у вас уже есть Telegram-бот

Пропустите раздел выше. Если `bot-token` этого бота у вас уже есть — переходите к следующему шагу. Если токен утерян, получите его заново:

1. Напишите [@BotFather](https://t.me/BotFather) команду `/token`
2. Выберите нужного бота из списка
3. BotFather вернёт новый `bot-token` вида `123456789:ABCdefGhI-jklMnoPQRstuVwxYZ`
4. Добавьте бота в чат или группу, куда будут приходить алерты (если ещё не добавлен)

#### Получение `telegram_chat_id` и `telegram_user_id` (для обоих случаев)

1. Получите `telegram_chat_id` — ID чата/группы, куда будут отправляться уведомления:
   - Добавьте бота [@myidbot](https://t.me/myidbot) в ваш чат/группу
   - Отправьте сообщение `/getgroupid@myidbot` в чат/группу
   - Бот вернёт `Your group ID is: -xxxxx` — это и есть `telegram_chat_id`
2. Получите `telegram_user_id` для администратора:
   - Напишите боту [@userinfobot](https://t.me/userinfobot) в личные сообщения команду `/start`
   - Бот вернёт ваш `id` — это и есть `telegram_user_id`

#### Включение топиков (форума) в группе Telegram

Impulse реализует инциденты в Telegram как **топики (темы) форума**: для каждого инцидента создаётся отдельная тема через Telegram API `createForumTopic`. В обычном чате без включённых топиков отправка алертов завершится ошибкой `Bad Request: the chat is not a forum` / `Incident creation aborted: failed to create thread`. Поэтому целевой чат **обязательно** должен быть супергруппой с включёнными Topics.

Настройка группы:

1. Откройте ваш чат/группу → меню → **Manage group**
2. Включите **Topics** (это преобразует чат в форум-супергруппу; `telegram_chat_id` при этом не меняется — повторно получать ID не нужно)
3. Добавьте бота Impulse в группу (если ещё не добавлен)
4. Повысьте бота до администратора и включите право **Manage topics**
5. (Рекомендуется) Отключите уведомления в группе навсегда, чтобы не было шума от топиков-инцидентов

> Topics должны оставаться включёнными всё время работы Impulse — каждое уведомление о новом инциденте создаёт новый топик. Выключение Topics приведёт к возврату ошибки `the chat is not a forum` на новых алертах, а уже созданные инциденты могут рассинхронизироваться с чатом (кнопки Take It / Freeze перестанут работать).

> **Бот обязательно должен быть администратором группы с правом «Manage topics».** Без этого права Telegram Bot API отклоняет `createForumTopic` ошибкой `Bad Request: not enough rights to create a topic` (HTTP 400), а Impulse прерывает создание инцидента: `Incident creation aborted: failed to create thread`. Право `can_manage_topics` на уровне чата (в `getChat`/permissions) разрешает участникам создавать темы, но **не распространяется на бота автоматически** — его нужно выдать боту персонально через Manage group → Administrators. Повышение бота в админы возможно только через клиент Telegram создателем группы (creator); через Bot API это сделать нельзя.

#### Вписывание значений и создание Secret

1. Создайте файл `terraform.tfvars` в корне репозитория со значениями (файл уже в `.gitignore`, значения не попадут в git):

```bash
cat > terraform.tfvars <<'EOF'
telegram_chat_id = "<ваш telegram_chat_id>"
telegram_user_id = "<ваш telegram_user_id>"
bot_token        = "<ваш bot-token вида 123456789:ABCdefGhI-jklMnoPQRstuVwxYZ>"
EOF
```

2. Перегенерируйте values и манифест Secret с токеном бота:

```bash
terraform apply
```

> `terraform apply` рендерит файл `impulse-telegram-secret.yaml` (манифест Namespace `impulse` + Secret `impulse-telegram-secrets` с ключом `bot-token`) из переменной `bot_token`. Токен кодируется в base64 и не светится в values-файле. Сам файл `impulse-telegram-secret.yaml` добавлен в `.gitignore`.

3. Примените манифест Secret в кластере вручную:

```bash
kubectl apply -f impulse-telegram-secret.yaml
```

> Secret `impulse-telegram-secrets` в namespace `impulse` создаётся вручную через `kubectl apply -f impulse-telegram-secret.yaml` после `terraform apply`. Terraform не вызывает kubectl напрямую — это избегает ошибок доступа к API кластера во время `apply`. При смене `bot_token` в `terraform.tfvars` повторный `terraform apply` перегенерирует `impulse-telegram-secret.yaml`, после чего его нужно повторно применить `kubectl apply -f impulse-telegram-secret.yaml`.

### 4. Установка Impulse

Для установки Impulse через Helm используйте следующие команды:

```bash
helm repo add impulse https://eslupmi-community.github.io/helm-charts
helm repo update
helm install my-impulse impulse/impulse \
  --version 1.0.15 \
  --namespace impulse \
  --create-namespace \
  -f values/values-impulse.yaml
```

Шаблон values: [`values/values-impulse.yaml.tftpl`](values/values-impulse.yaml.tftpl) (рендерится в `values/values-impulse.yaml`).

## Доступ к сервисам

URL формируются через sslip.io из публичного IP балансировщика ingress-nginx (IP берётся из `terraform output lb_ip`). TLS через cert-manager + Let's Encrypt:

- **Grafana**: `https://grafana.<LB_IP>.sslip.io`
- **VictoriaMetrics**: `https://vmselect.<LB_IP>.sslip.io`
- **Alertmanager**: `https://alertmanager.<LB_IP>.sslip.io`
- **vmalert**: `https://vmalert.<LB_IP>.sslip.io`
- **Impulse**: `https://impulse.<LB_IP>.sslip.io`

Для получения пароля admin от Grafana:

```bash
terraform output -raw grafana_admin_password_command | sh
```

> sslip.io — бесплатный wildcard-DNS: `<anything>.<IP>.sslip.io` всегда резолвится в `<IP>`. Не требует делегирования доменной зоны.
