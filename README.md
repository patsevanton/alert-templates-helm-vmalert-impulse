# Шаблонизация правил алертов в Helm и их обработка через vmalert и Impulse для отправки в Telegram

### 1. cert-manager

Установите cert-manager для автоматизации TLS:

```bash
helm install \
  cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.19.2 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait \
  --timeout 15m
```

После установки подключите ClusterIssuer (пример файла — [`cluster-issuer.yaml`](cluster-issuer.yaml:1)).

```bash
kubectl apply -f cluster-issuer.yaml
```

Содержимое cluster-issuer.yaml:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: my-email@mycompany.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

> Если вы не используете Let's Encrypt, замените настройки ClusterIssuer на внутренний CA или нужный вам провайдер.

### VM K8s Stack (метрики, Grafana)

Пример установки victoria-metrics-k8s-stack c Grafana:

```bash
helm upgrade --install vmks \
  oci://ghcr.io/victoriametrics/helm-charts/victoria-metrics-k8s-stack \
  --namespace vmks \
  --create-namespace \
  --wait \
  --version 0.67.0 \
  --timeout 15m \
  -f vmks-values.yaml
```

Содержимое vmks-values.yaml:
```
grafana:
  ingress:
    ingressClassName: nginx
    enabled: true
    hosts:
      - grafana.apatsev.org.ru
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
defaultRules:
  groups:
    etcd:
      create: false
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
        nginx.ingress.kubernetes.io/ssl-redirect: "false"
      hosts:
        - vmselect.apatsev.org.ru
alertmanager:
  enabled: true
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - alertmanager.apatsev.org.ru
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
vmalert:
  enabled: true
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - vmalert.apatsev.org.ru
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
    path: "/"
    pathType: Prefix
```

Можно анализировать логи через explore Grafana.

Откройте http://grafana.apatsev.org.ru/

Откройте http://vmselect.apatsev.org.ru/select/0/vmui

Откройте http://alertmanager.apatsev.org.ru

Откройте http://vmalert.apatsev.org.ru

Для получения пароля admin от Grafana необходимо:
```bash
kubectl get secret vmks-grafana -n vmks -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

### Установка через Helm

Для установки приложения в Kubernetes-кластере используйте Helm:

```bash
helm upgrade --install golden-signal-app ./chart \
  --namespace golden-signal-app \
  --create-namespace \
  --set image.repository=ghcr.io/patsevanton/alert-templates-helm-vmalert-impulse \
  --set image.tag=1.3.0
```

# Проверка статуса развертывания
```
kubectl get pods -n golden-signal-app -l app=golden-signal-app
```

# Проверка метрик
```
kubectl port-forward -n golden-signal-app svc/golden-signal-app 8080:8080
curl http://localhost:8080/metrics
curl http://localhost:8080/work
```

### Настройка Telegram-бота

Для отправки уведомлений в Telegram:

1. Создайте бота через [@BotFather](https://t.me/BotFather)
2. Получите токен бота
3. Добавьте бота в чат или группу, куда будут приходить алерты (бот должен быть добавлен как участник)
4. Получите `telegram_chat_id` — ID чата/группы, куда будут отправляться уведомления:
   - Добавьте бота [@userinfobot](https://t.me/userinfobot) в ваш чат/группу
   - Отправьте любое сообщение в чат/группу
   - [@userinfobot](https://t.me/userinfobot) вернет информацию о чате, включая `chat.id` — это и есть `telegram_chat_id`
   - Укажите полученный ID в `values-impulse.yaml` в секции `channels.incidents_default.id`
5. Получите `telegram_user_id` для администратора:
   - Напишите боту [@userinfobot](https://t.me/userinfobot) в личные сообщения
   - Бот вернет ваш `id` — это и есть `telegram_user_id`
   - Укажите полученный ID в `values-impulse.yaml` в секции `users.admin_user.id`
   - `admin_user` используется для управления инцидентами через цепочки эскалации (chains) и получения уведомлений о статусе обработки алертов
6. Создайте Kubernetes Secret с токеном бота:

```bash
kubectl create namespace impulse
kubectl create secret generic impulse-telegram-secrets \
  --namespace impulse \
  --from-literal=bot-token='xxxxx:xxxxx-xxxxxxx'
```

Затем в `values-impulse.yaml` раскомментируйте и настройте:

```yaml
secrets:
  existing:
    telegram:
      secretName: "impulse-telegram-secrets"
      botTokenKey: "bot-token"
```

И закомментируйте секцию `secrets.inline.telegram.botToken`.

7. Настройте Impulse на прием webhook от Alertmanager
8. Сконфигурируйте шаблоны сообщений с необходимыми полями:
   - Severity (уровень серьезности)
   - Текущее значение метрики
   - Пороговое значение
   - Ссылки на дашборды Grafana
   - Команда ответственных

### Установка Impulse

Для установки Impulse через Helm используйте следующие команды:

```bash
helm repo add impulse https://eslupmi.github.io/helm-charts/packages
helm repo update
helm upgrade --install impulse impulse/impulse \
  --version 1.0.6 \
  --namespace impulse \
  --create-namespace \
  -f values-impulse.yaml
```