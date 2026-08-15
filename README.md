# Шаблонизация правил алертов в Helm и их обработка через vmalert и Impulse для отправки в Telegram

## Цель статьи

Показать, как отправлять и маршрутизировать алерты от двух сервисов разных команд в их собственные Telegram-чаты. На примере demo-приложения Golden Signal и стека VictoriaMetrics разбирается: шаблонизация правил алертов в Helm, маршрутизация алертов через vmalert + Alertmanager и доставка уведомлений в Telegram через Impulse с разнесением по чатам команд.

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
| Привязка Telegram-пользователей к admin-user'ам (`users.<name>.id = telegram_user_id`) для эскалаций и упоминаний конкретным людям | ❌ нет (чужая зона ответственности) | ✅ |

**Кратко:** Alertmanager здесь выступает только маршрутизатором-источником (`receiver: impulse` → webhook на Impulse). Всю работу с пользователем внутри Telegram — треды, кнопки, состояния инцидента, привязку людей — делает Impulse.

> **Перед шагами ниже** разверните kubernetes и установите cert-manager. Дальнейшие шаги предполагают, что кластер K8s работает, ingress-nginx слушает на публичном IP, cert-manager установлен, а ClusterIssuer `letsencrypt-prod` применён.

## Порядок развёртывания

### 1. Подготовка файла конфигурации victoria-metrics-k8s-stack

```
cat <<'EOF' >> values/vmks-values.yaml
# здесь values/vmks-values.yaml через EOF
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

Правила алертов задаются как **VMRule** (Custom Resource VictoriaMetrics) — манифест `chart/templates/vmrule.yaml`. VMRule применяется в кластер **вместе с установкой приложения** одним `helm upgrade --install`, отдельного шага для алертов нет. vmalert автоматически подхватывает VMRule через `selectAllByDefault: true`.

Правила алертов (группа `golden-signal-alerts`):

| Алерт | Условие | For | Severity |
|---|---|---|---|
| `HighErrorRate` | `rate(app_errors_total[5m]) / rate(app_requests_total[5m]) > 0.05` | 1m | critical |
| `HighLatency` | `histogram_quantile(0.95, sum(rate(app_request_latency_seconds_bucket[5m])) by (le)) > 0.5` | 2m | warning |
| `HighGoroutineCount` | `app_goroutines > 50` | 1m | warning |

Каждый алерт несёт label `team` (`team-a` или `team-b`), по которому Impulse разносит инциденты по двум Telegram-чатам команд (`route.routes` + matchers в `values/values-impulse.yaml.tftpl`). Поэтому приложение устанавливается **двумя релизами** — по одному на команду, с переопределением `team`:

```bash
# Релиз команды team-a (алерты с label team=team-a → чат incidents_team_a)
helm upgrade --install golden-signal-app-a ./chart \
  --namespace golden-signal-app \
  --create-namespace \
  --set team=team-a

# Релиз команды team-b (алерты с label team=team-b → чат incidents_team_b)
helm upgrade --install golden-signal-app-b ./chart \
  --namespace golden-signal-app \
  --set team=team-b
```

### Проверка статуса развертывания

```bash
kubectl get pods -n golden-signal-app -l app=golden-signal-app
```

### Проверка метрик

```bash
kubectl port-forward -n golden-signal-app svc/golden-signal-app-a 8080:8080
curl http://localhost:8080/metrics
curl http://localhost:8080/work
```

### 3. Настройка Telegram-бота

Для отправки уведомлений в Telegram потребуется бот и значения: `bot-token`, `telegram_chat_id` (чат team-a), `telegram_chat_id_b` (чат team-b), `telegram_user_id`, `telegram_teamlead_id`.

#### Если у вас нет Telegram-бота

Создайте бота и получите его токен:

1. Напишите [@BotFather](https://t.me/BotFather) команду `/newbot`
2. Задайте имя и username бота (username должен оканчиваться на `bot`)
3. BotFather вернёт `bot-token` вида `123456789:ABCdefGhI-jklMnoPQRstuVwxYZ`
4. Добавьте созданного бота в оба чата команд (бот должен быть участником обеих групп)

#### Если у вас уже есть Telegram-бот

Пропустите раздел выше. Если `bot-token` этого бота у вас уже есть — переходите к следующему шагу. Если токен утерян, получите его заново:

1. Напишите [@BotFather](https://t.me/BotFather) команду `/token`
2. Выберите нужного бота из списка
3. BotFather вернёт новый `bot-token` вида `123456789:ABCdefGhI-jklMnoPQRstuVwxYZ`
4. Добавьте бота в оба чата команд (если ещё не добавлен)

#### Получение `telegram_chat_id`, `telegram_chat_id_b`, `telegram_user_id`, `telegram_teamlead_id`

1. Получите `telegram_chat_id` — ID чата/группы команды team-a, куда будут отправляться уведомления:
   - Добавьте бота [@myidbot](https://t.me/myidbot) в ваш чат/группу team-a
   - Отправьте сообщение `/getgroupid@myidbot` в чат/группу
   - Бот вернёт `Your group ID is: -xxxxx` — это и есть `telegram_chat_id`
2. Получите `telegram_chat_id_b` — ID чата/группы команды team-b аналогично:
   - Добавьте [@myidbot](https://t.me/myidbot) в чат/группу team-b
   - Отправьте `/getgroupid@myidbot`
   - ID из ответа — это `telegram_chat_id_b`
3. Получите `telegram_user_id` для администратора:
   - Напишите боту [@userinfobot](https://t.me/userinfobot) в личные сообщения команду `/start`
   - Бот вернёт ваш `id` — это и есть `telegram_user_id`
4. Получите `telegram_teamlead_id` — Telegram `user_id` teamlead:
   - Teamlead пишет боту [@userinfobot](https://t.me/userinfobot) команду `/start` из своего аккаунта
   - Бот вернёт `id` teamlead — это и есть `telegram_teamlead_id`
   - Если teamlead и администратор — один и тот же человек, `telegram_teamlead_id` совпадает с `telegram_user_id`

#### Включение топиков (форума) в группах Telegram

Impulse реализует инциденты в Telegram как **топики (темы) форума**: для каждого инцидента создаётся отдельная тема через Telegram API `createForumTopic`. В обычном чате без включённых топиков отправка алертов завершится ошибкой `Bad Request: the chat is not a forum` / `Incident creation aborted: failed to create thread`. Поэтому **оба чата команд** (team-a и team-b) обязательно должны быть супергруппами с включёнными Topics.

Настройка группы (выполнить для каждого из двух чатов):

1. Откройте ваш чат/группу → меню → **Manage group**
2. Включите **Topics** (это преобразует чат в форум-супергруппу; `telegram_chat_id` при этом не меняется — повторно получать ID не нужно)
3. Добавьте бота Impulse в группу (если ещё не добавлен)
4. Повысьте бота до администратора и включите право **Manage topics**
5. (Рекомендуется) Отключите уведомления в группе навсегда, чтобы не было шума от топиков-инцидентов

> Topics должны оставаться включёнными всё время работы Impulse — каждое уведомление о новом инциденте создаёт новый топик. Выключение Topics приведёт к возврату ошибки `the chat is not a forum` на новых алертах, а уже созданные инциденты могут рассинхронизироваться с чатом (кнопки Take It / Freeze перестанут работать).

> **Бот обязательно должен быть администратором обеих групп с правом «Manage topics».** Без этого права Telegram Bot API отклоняет `createForumTopic` ошибкой `Bad Request: not enough rights to create a topic` (HTTP 400), а Impulse прерывает создание инцидента: `Incident creation aborted: failed to create thread`. Право `can_manage_topics` на уровне чата (в `getChat`/permissions) разрешает участникам создавать темы, но **не распространяется на бота автоматически** — его нужно выдать боту персонально через Manage group → Administrators. Повышение бота в админы возможно только через клиент Telegram создателем группы (creator); через Bot API это сделать нельзя.

#### Вписывание значений и создание Secret

1. Создайте файл `terraform.tfvars` в корне репозитория со значениями (файл уже в `.gitignore`, значения не попадут в git):

```bash
cat > terraform.tfvars <<'EOF'
telegram_chat_id     = "<ID чата team-a>"
telegram_chat_id_b   = "<ID чата team-b>"
telegram_user_id     = "<ваш telegram_user_id>"
telegram_teamlead_id = "<telegram_user_id teamlead>"
bot_token            = "<ваш bot-token вида 123456789:ABCdefGhI-jklMnoPQRstuVwxYZ>"
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
- **VictoriaMetrics**: `https://vmsingle.<LB_IP>.sslip.io`
- **Alertmanager**: `https://alertmanager.<LB_IP>.sslip.io`
- **vmalert**: `https://vmalert.<LB_IP>.sslip.io`
- **Impulse**: `https://impulse.<LB_IP>.sslip.io`

Для получения пароля admin от Grafana:

```bash
terraform output -raw grafana_admin_password_command | sh
```

> sslip.io — бесплатный wildcard-DNS: `<anything>.<IP>.sslip.io` всегда резолвится в `<IP>`. Не требует делегирования доменной зоны.

## Как работает привязка Telegram-пользователей в Impulse (`users.<name>.id` и `admin_users`)

В `values/values-impulse.yaml.tftpl` секция `impulseConfig.messenger` содержит:

```yaml
admin_users: ["admin_user"]
users:
  admin_user:
    id: "${telegram_user_id}"          # числовой Telegram user_id администратора
  team_a_teamlead:
    id: "${telegram_teamlead_id}"      # числовой Telegram user_id teamlead
  team_b_teamlead:
    id: "${telegram_teamlead_id}"      # тот же id, что у team_a_teamlead
  team_a_oncall:
    id: "${telegram_user_id}"          # дежурный team-a (те же люди, что и teamlead/admin)
  team_b_oncall:
    id: "${telegram_user_id}"          # дежурный team-b
```

**Назначение `users.<name>.id`** — это **числовой Telegram `user_id`** (положительное число). Используется **не для адресации кнопок callback**, а для:

1. **Пред-регистрации пользователя в `UserManager`** Impulse — `user_id` становится первичным ключом, через Telegram API `getChat` подгружаются `full_name`/`username`. Без записи в `users` тоже работает: Impulse узнаёт пользователя при первом его действии через `from.id` из callback-пейлоада.
2. **Адресации по имени в эскалационных цепочках** — chain-step `user: <config_name>` резолвится в `user_id` через `UserManager`.
3. **`admin_users`** — список **имён (ключей из `users`)** (валидируется, что каждое имя есть в `users`). Администраторы упоминаются в текстах уведомлений как `tg://user?id=<id>` (фолбэк-канал для алертов и предупреждений).
4. **Упоминаний в текстах** — `<a href="tg://user?id={{ id }}">` в шаблонах Impulse превращается в пуш-уведомление конкретному человеку в Telegram.
5. **Обратного сопоставления `user_id → config_name`** — для refresh-задач и UI.

> Teamlead объявляется двумя ключами (`team_a_teamlead` и `team_b_teamlead`) с одинаковым `id`, чтобы каждая эскалационная цепочка ссылалась на «своего» teamlead по имени. Если teamlead один на обе команды — значения совпадают. Аналогично объявлены дежурные (`team_a_oncall` / `team_b_oncall`) — те же люди, что и teamlead/admin_user.

> **Кнопки callback в Telegram не имеют адресации конкретному человеку.** Inline-кнопки (`Take It` / `Freeze` и т.п.) видны всем участникам группы, `callback_data` содержит только команду (`stop_chain`, `start_chain`, …) без `user_id`. В момент клика Telegram сам сообщает в callback-пейлоаде `from.id` нажавшего — Impulse привязывает инцидент к этому `user_id` уже в момент нажатия, а не из конфига.

**`impulse_address`** (`https://impulse.<LB_IP>.sslip.io`) — это **публичный HTTPS-URL инстанса Impulse**, куда Telegram шлёт POST'ом все `callback_query` и сообщения (регистрируется через Telegram API `setWebhook` с `url = {impulse_address}/app`). Это транспортный endpoint для приёма callback'ов от Telegram, **не механизм адресации людям** — Telegram поддерживает webhook только по HTTPS, поэтому TLS обязателен.

## Эскалация инцидентов и дежурства (schedule chains)

Impulse поддерживает эскалационные цепочки — последовательность шагов уведомления, которая запускается при создании инцидента и останавливается, когда кто-то нажимает кнопку **Take It** (или замораживает инцидент **Freeze**). Пока никто не отреагировал, цепочка продолжает выполняться по расписанию шагов.

В проекте цепочки реализованы как **schedule chains** — расписание дежурств с тайм-зоной `Asia/Omsk`:

- **Будни 09:00–20:00** (окно дежурства, 11 часов): инцидент → тег дежурного сразу → wait 5m → тег teamlead.
- **Вне окна** (будни 20:00–09:00 и выходные Сб/Вс): инцидент → wait 5m → тег teamlead (дежурного нет, teamlead заменяет дежурного).

```yaml
chains:
  team_a_escalation:
    type: schedule
    timezone: Asia/Omsk
    schedule:
      # Будни 09:00–20:00: дежурный тегается сразу, затем через 5 минут — teamlead
      - matcher:
          start_day_expr: dow
          start_day_values: ["Mon", "Tue", "Wed", "Thu", "Fri"]
          start_time: "09:00"
          duration: 11h
        steps:
          - user: team_a_oncall
          - wait: 5m
          - user: team_a_teamlead
      # Вне окна дежурства (будни 20:00–09:00, выходные): только teamlead через 5 минут
      - steps:
          - wait: 5m
          - user: team_a_teamlead
  team_b_escalation:
    # аналогично для team-b (team_b_oncall, team_b_teamlead)
```

**Логика:**

1. Инцидент создаётся в чате команды (`incidents_team_a` или `incidents_team_b`) — все участники видят сообщение с кнопками Take It / Freeze. Impulse оценивает матчеры schedule-chain сверху вниз, первый совпавший выбирает steps.
2. **В окно дежурства** (будни 09:00–20:00): дежурный тегается сразу (`user: team_*_oncall` → `tg://user?id=<id>` → push-уведомление). Если в течение 5 минут никто не нажал **Take It** — тегается teamlead.
3. **Вне окна дежурства**: teamlead тегается через 5 минут (дежурного нет, teamlead заменяет).
4. Нажатие **Take It** в любой момент останавливает цепочку (`stops chain escalation`), teamlead не тегается.

> Schedule-chain в Impulse поддерживает `dow` (день недели), `dom` (день месяца), `date` (точная дата) и modulus-выражения (`dow % 2` для чередования). Матчеры оцениваются сверху вниз, ветка без `matcher` — fallback (срабатывает, если ни один матчер не совпал). Подробнее — в [документации Impulse](https://eslupmi-community.github.io/impulse/config_file/#schedule-chains).

> Шаг `user` упоминает пользователя в сообщении инцидента в текущем чате (не в личку). Для отправки в личные сообщения нужно, чтобы пользователь предварительно начал диалог с ботом (Telegram Bot API требует `/start` от пользователя перед отправкой ему сообщений).

## Маршрутизация алертов по чатам команд (route + matchers)

Алерт несёт label `team` (`team-a` или `team-b`), который выставляется в `chart/templates/vmrule.yaml` из `chart/values.yaml` (`team: team-a` по умолчанию). Impulse разносит инциденты по двум чатам через `route.routes` + `matchers`:

```yaml
route:
  channel: "incidents_team_a"       # канал по умолчанию (fallback, если matchers не сработали)
  chain: "team_a_escalation"        # цепочка по умолчанию
  routes:
    - matchers:
        - team="team-a"
      channel: "incidents_team_a"
      chain: "team_a_escalation"
    - matchers:
        - team="team-b"
      channel: "incidents_team_b"
      chain: "team_b_escalation"
```

Чтобы получить алерты от обеих команд, demo-приложение устанавливается двумя релизами с переопределением `team` (см. шаг 2).
