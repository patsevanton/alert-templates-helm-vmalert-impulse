# Шаблонизация правил алертов в Helm и их обработка через vmalert и Impulse для отправки в Telegram

## Цель статьи

Показать, как отправлять и маршрутизировать алерты от двух сервисов разных команд в их собственные Telegram-чаты. На примере demo-приложения Golden Signal и стека VictoriaMetrics разбирается: шаблонизация правил алертов в Helm, маршрутизация алертов через vmalert + Alertmanager и доставка уведомлений в Telegram через Impulse с разнесением по чатам команд.

> **Перед шагами ниже** разверните kubernetes и установите cert-manager. Дальнейшие шаги предполагают, что кластер K8s работает, ingress-nginx слушает на публичном IP, cert-manager установлен, а ClusterIssuer `letsencrypt-prod` применён.

## Порядок развёртывания

### 1. VM K8s Stack (метрики, Grafana)

Установка victoria-metrics-k8s-stack с Grafana. Values-файл уже сгенерирован Terraform с актуальным sslip.io-хостом и TLS-настройками ingress:

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

Шаблон values: [`values/vmks-values.yaml.tftpl`](values/vmks-values.yaml.tftpl) (рендерится в `values/vmks-values.yaml`).

### 2. Установка приложения через Helm

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
