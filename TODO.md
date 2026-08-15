# TODO: Эскалация и дежурства в Impulse

## Постановка

Добавить в Impulse эскалационную цепочку с дежурствами (schedule chain):
- инцидент создаётся в чате команды;
- в окно дежурства (будни 09:00–20:00, Asia/Omsk) дежурный тегается сразу, затем через 5 минут — teamlead;
- вне окна дежурства (будни 20:00–09:00 и выходные) teamlead тегается через 5 минут (заменяет дежурного).

Clusterlead убран из сценария — его не будет.

## Что нужно сделать

- [x] **Telegram-чат.** Значение `telegram_chat_id` вписано в `terraform.tfvars`. Чат — супергруппа с включёнными Topics, бот — администратор с правом «Manage topics» (см. README, секция «Включение топиков»).
- [x] **id teamlead.** Teamlead и devops-инженер — один и тот же человек. В конфиге Impulse объявляется ключом `team_a_teamlead` со значением `id` из переменной Terraform `telegram_teamlead_id` (задаётся в `terraform.tfvars`).
- [x] **Дежурный.** Объявлен ключом `team_a_oncall` с `id` из `telegram_user_id` (тот же человек, что и teamlead/admin_user). В окне дежурства дежурный тегается сразу при создании инцидента.
- [x] **Расписание дежурств.** Schedule-chain с тайм-зоной `Asia/Omsk`: будни Mon–Fri 09:00, duration 11h → дежурный сразу + teamlead через 5m; fallback (вне окна) → teamlead через 5m.
- [x] **Clusterlead не будет.** Из сценария эскалации исключён; шаг chain `clusterlead` не добавляется.

## Конфигурация Impulse (`values/values-impulse.yaml.tftpl`)

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
        id: "${telegram_teamlead_id}"
      team_a_oncall:
        id: "${telegram_user_id}"
    channels:
      incidents_team_a:
        id: "${telegram_chat_id}"
    chains:
      team_a_escalation:
        type: schedule
        timezone: Asia/Omsk
        schedule:
          - matcher:
              start_day_expr: dow
              start_day_values: ["Mon", "Tue", "Wed", "Thu", "Fri"]
              start_time: "09:00"
              duration: 11h
            steps:
              - user: team_a_oncall
              - wait: 5m
              - user: team_a_teamlead
          - steps:
              - wait: 5m
              - user: team_a_teamlead
  route:
    channel: "incidents_team_a"
    chain: "team_a_escalation"
```

## Связанные изменения в Terraform

- [x] `versions.tf`: переменные `telegram_chat_id` и `telegram_teamlead_id`.
- [x] `k8s.tf` (`locals.impulse_values`): переменные передаются в `templatefile`.
- [x] `terraform.tfvars`: значения `telegram_chat_id` и `telegram_teamlead_id` указаны.
- [x] `README.md`: секция «Эскалация инцидентов и дежурства (schedule chains)» с описанием окна дежурства и fallback.

## Условие срабатывания эскалации

«Никто не ответил» = никто не нажал кнопку **Take It** в течение 5 минут с момента создания инцидента. Нажатие **Take It** останавливает цепочку (`stops chain escalation`, см. `docs/content/concepts/incident.md` в Impulse). Шаг `user` тегает человека в чате инцидента (упоминание через `tg://user?id=<id>`).
