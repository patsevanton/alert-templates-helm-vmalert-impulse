# TODO: Эскалация в Impulse (chat → teamlead)

## Постановка

Добавить в Impulse эскалационную цепочку: инцидент создаётся в чате команды → если никто не нажал **Take It** в течение 5 минут → teamlead тегается в чате инцидента. Clusterlead убран из сценария — его не будет.

## Что нужно сделать

- [ ] **Сделать второй Telegram-чат.** Сейчас в проекте один чат `incidents_default` (`${telegram_chat_id}`). Нужно добавить второй чат для команды `team-b` (`telegram_chat_id_b`), чтобы алерты расходились по чатам команд через `route.routes` + matchers по label `team=team-a` / `team=team-b`. Оба чата — супергруппы с включёнными Topics, бот — администратор с правом «Manage topics» (см. README, секция «Включение топиков»).
- [x] **id teamlead.** Teamlead и devops-инженер — один и тот же человек. В конфиге Impulse объявляется двумя ключами (`team_a_teamlead` и `team_b_teamlead`) с одинаковым `id`, чтобы каждая цепочка ссылалась на «своего» teamlead по имени. Значение берётся из переменной Terraform `telegram_teamlead_id` (задаётся в `terraform.tfvars`).
- [x] **Clusterlead не будет.** Из сценария эскалации исключён; шаг chain `clusterlead` не добавляется.

## Планируемая конфигурация Impulse (`values/values-impulse.yaml.tftpl`)

```yaml
impulseConfig:
  messenger:
    type: "telegram"
    impulse_address: "https://impulse.${lb_ip}.sslip.io"
    admin_users: ["admin_user"]
    users:
      admin_user:
        id: "${telegram_user_id}"
      team_a_teamlead:
        id: "${telegram_teamlead_id}"   # один и тот же id на оба чата
      team_b_teamlead:
        id: "${telegram_teamlead_id}"
    channels:
      incidents_team_a:                 # чат №1 (team-a)
        id: "${telegram_chat_id}"
      incidents_team_b:                 # чат №2 (team-b)
        id: "${telegram_chat_id_b}"
    chains:
      team_a_escalation:
        - wait: 5m
        - user: team_a_teamlead         # тег teamlead в чате инцидента
      team_b_escalation:
        - wait: 5m
        - user: team_b_teamlead
  route:
    channel: "incidents_team_a"         # канал по умолчанию (fallback)
    chain: "team_a_escalation"
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

## Связанные изменения в Terraform

- [x] `versions.tf`: добавить переменные `telegram_chat_id_b` и `telegram_teamlead_id`.
- [x] `k8s.tf` (`locals.impulse_values`): передать `telegram_chat_id_b` и `telegram_teamlead_id` в `templatefile`.
- [ ] `terraform.tfvars`: указать реальное значение `telegram_chat_id_b` (id второго чата) и `telegram_teamlead_id`.
- [x] `README.md`: обновить секцию «Настройка Telegram-бота» (получение id второго чата и id teamlead) и блок описания `users`/`chains`/`route`.

## Условие срабатывания эскалации

«Никто не ответил» = никто не нажал кнопку **Take It** в течение 5 минут с момента создания инцидента. Нажатие **Take It** останавливает цепочку (`stops chain escalation`, см. `docs/content/concepts/incident.md` в Impulse). Шаг `user: teamlead` тегает teamlead в чате инцидента (упоминание через `tg://user?id=<id>` в шаблоне уведомления).
