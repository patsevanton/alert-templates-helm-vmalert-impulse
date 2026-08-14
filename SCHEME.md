# Схема адресации инцидентов в Telegram через Impulse

Сценарий: 1 admin/devops-инженер + 2 команды разработки (teamlead + developer) + 2 чата команд в Telegram.

```mermaid
flowchart TD
    subgraph People["Люди (telegram_user_id)"]
        DEVOPS["devops<br/>admin/devops инженер<br/>TG ID: devops_tg_id"]
        TL1["teamlead1<br/>TG ID: tl1_tg_id"]
        DEV1["developer1<br/>TG ID: dev1_tg_id"]
        TL2["teamlead2<br/>TG ID: tl2_tg_id"]
        DEV2["developer2<br/>TG ID: dev2_tg_id"]
    end

    subgraph Telegram["Telegram (чат — форум с Topics)"]
        CHAT1["team1_chat<br/>chat_id: team1_chat_id<br/>инциденты команды 1"]
        CHAT2["team2_chat<br/>chat_id: team2_chat_id<br/>инциденты команды 2"]
    end

    subgraph Impulse["Impulse config"]
        direction TB
        ADMIN["admin_users: [devops]<br/>← получает warnings<br/>(недоставка эскалаций, unknown-статус)"]
        USERS["users.&lt;name&gt;.id = TG user_id<br/>devops → devops_tg_id<br/>teamlead1 → tl1_tg_id<br/>developer1 → dev1_tg_id<br/>teamlead2 → tl2_tg_id<br/>developer2 → dev2_tg_id"]
        GROUPS["user_groups<br/>team1: [teamlead1, developer1]<br/>team2: [teamlead2, developer2]"]
        CHAINS["chains<br/>notify_team1: user_group team1<br/>notify_team2: user_group team2"]
        ROUTE["route (matchers из алерта)<br/>team=team1 → (team1_chat, notify_team1)<br/>team=team2 → (team2_chat, notify_team2)"]
        ADMIN --- USERS
        USERS --> GROUPS
        GROUPS --> CHAINS
        CHAINS --> ROUTE
    end

    VMALERT["vmalert + Alertmanager<br/>алерты с лейблом team="]
    VMALERT -->|"webhook"| Impulse

    ROUTE -->|"team=team1"| CHAT1
    ROUTE -->|"team=team2"| CHAT2

    CHAINS -.->|"упоминание tg://user?id="| TL1
    CHAINS -.->|"упоминание tg://user?id="| DEV1
    CHAINS -.->|"упоминание tg://user?id="| TL2
    CHAINS -.->|"упоминание tg://user?id="| DEV2

    CHAT1 -.->|"кнопка Take It нажата<br/>from.id из callback"| TL1
    CHAT1 -.-> DEV1
    CHAT2 -.-> TL2
    CHAT2 -.-> DEV2

    CHAINS -.->|"если @tl1/@dev1 недостижимы<br/>→ 🔔 admins"| DEVOPS

    classDef person fill:#e1f5ff,stroke:#0288d1,color:#000
    classDef chat fill:#fff3e0,stroke:#f57c00,color:#000
    classDef impulse fill:#f3e5f5,stroke:#7b1fa2,color:#000
    classDef alert fill:#ffebee,stroke:#c62828,color:#000

    class DEVOPS,TL1,DEV1,TL2,DEV2 person
    class CHAT1,CHAT2 chat
    class ADMIN,USERS,GROUPS,CHAINS,ROUTE impulse
    class VMALERT alert
```

## Легенда связей

- **Сплошные** — маршрутизация: vmalert → Impulse → `route` (по `matchers`) → `channel` (чат команды).
- **Пунктирные** — упоминания/адресация: `chains` через `tg://user?id=<id>` подсвечивают конкретным людям пуш в треде инцидента.
- **`admin_users`** получает `🔔 admins` только как фолбэк: если целевой пользователь из цепочки недостижим (`NotDefined`/`NotFound`) или инцидент перешёл в `unknown`.
- **Кнопки callback** не адресуются заранее — `from.id` нажавшего узнаётся в момент клика от Telegram, не из конфига.

## Назначение сущностей Impulse

| Сущность | Привязка | Что адресует |
|---|---|---|
| `users.<name>.id` | = Telegram `user_id` человека | Пред-регистрация в `UserManager`, адресация эскалаций `user: <name>`, упоминания `tg://user?id=<id>` |
| `admin_users` | список имён из `users` | Получатели warning-уведомлений (фолбэк при недоставке + `unknown`-статус) |
| `user_groups.<name>.users` | список имён из `users` | Массовое уведомление группы в эскалации (`user_group: <name>`) |
| `channels.<name>.id` | = Telegram `chat_id` | Куда создавать топик-инцидент (`route.channel`) |
| `route` (matchers) | поля алерта (`team=`, `service=`, `severity=`, …) | Маршрутизация: алерт → (channel, chain) |

## Пример конфига

```yaml
impulseConfig:
  messenger:
    type: "telegram"
    impulse_address: "https://impulse.${lb_ip}.sslip.io"

    admin_users: ["devops"]          # ← получает warnings

    users:
      devops:       {id: ${devops_tg_id}}      # нужен telegram_user_id админа
      teamlead1:    {id: ${tl1_tg_id}}
      developer1:   {id: ${dev1_tg_id}}
      teamlead2:    {id: ${tl2_tg_id}}
      developer2:   {id: ${dev2_tg_id}}

    user_groups:
      team1: {users: ["teamlead1", "developer1"]}
      team2: {users: ["teamlead2", "developer2"]}

    channels:
      team1_chat: {id: ${team1_chat_id}}      # telegram_chat_id чата команды 1
      team2_chat: {id: ${team2_chat_id}}      # telegram_chat_id чата команды 2

    chains:
      notify_team1:
        - user_group: team1
      notify_team2:
        - user_group: team2

  route:
    channel: team1_chat              # default
    chain:   notify_team1
    routes:
      - matchers: [team="team1"]
        channel: team1_chat
        chain:   notify_team1
      - matchers: [team="team2"]
        channel: team2_chat
        chain:   notify_team2
```

> В текущем `values/values-impulse.yaml.tftpl` описан только один `admin_user` с одним `telegram_user_id` — для сценария с 2 командами потребуется расширить секции `users` / `user_groups` / `channels` / `chains` / `route` и добавить в `terraform.tfvars` переменные для всех `telegram_user_id` и `telegram_chat_id`.
