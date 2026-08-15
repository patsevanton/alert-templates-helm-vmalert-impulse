# Схема адресации инцидентов в Telegram

Сценарий: 2 сервиса (`golden-signal-app` с `team=team-a` и `team=team-b`) → 2 команды разработки (по 2 developer'а) + 2 чата команд в Telegram.

```mermaid
flowchart TD
    subgraph Apps["Сервисы (Helm-чарт golden-signal-app)"]
        APPA["app-team-a<br/>label: team=team-a<br/>метрики app_*"]
        APPB["app-team-b<br/>label: team=team-b<br/>метрики app_*"]
    end

    VMALERT["vmalert<br/>VMRule: HighErrorRate / HighLatency / HighGoroutineCount<br/>алерт наследует label team="]
    AM["Alertmanager<br/>route по team= → webhook"]
    IMPULSE["Impulse<br/>route по team= → channel команды"]
    subgraph Telegram["Telegram (чат — форум с Topics)"]
        CHATA["team-a chat<br/>инциденты команды A"]
        CHATB["team-b chat<br/>инциденты команды B"]
    end

    subgraph People["Люди (telegram_user_id)"]
        DEVOPS["devops<br/>admin/devops инженер"]
        DEVA1["developer-a1<br/>TG ID: dev_a1_tg_id"]
        DEVA2["developer-a2<br/>TG ID: dev_a2_tg_id"]
        DEVB1["developer-b1<br/>TG ID: dev_b1_tg_id"]
        DEVB2["developer-b2<br/>TG ID: dev_b2_tg_id"]
    end

    APPA --> VMALERT
    APPB --> VMALERT
    VMALERT -->|"алерт team=team-a"| AM
    VMALERT -->|"алерт team=team-b"| AM
    AM --> IMPULSE
    IMPULSE -->|"team=team-a"| CHATA
    IMPULSE -->|"team=team-b"| CHATB

    CHATA -.->|"упоминание tg://user?id="| DEVA1
    CHATA -.-> DEVA2
    CHATB -.-> DEVB1
    CHATB -.-> DEVB2

    CHATA -.->|"кнопка Take It<br/>from.id из callback"| DEVA1
    CHATA -.-> DEVA2
    CHATB -.-> DEVB1
    CHATB -.-> DEVB2

    CHATA -.->|"если @dev-a1/@dev-a2 недостижимы<br/>→ 🔔 admins"| DEVOPS
    CHATB -.->|"если @dev-b1/@dev-b2 недостижимы<br/>→ 🔔 admins"| DEVOPS

    classDef app fill:#e8f5e9,stroke:#388e3c,color:#000
    classDef alert fill:#ffebee,stroke:#c62828,color:#000
    classDef impulse fill:#f3e5f5,stroke:#7b1fa2,color:#000
    classDef chat fill:#fff3e0,stroke:#f57c00,color:#000
    classDef person fill:#e1f5ff,stroke:#0288d1,color:#000

    class APPA,APPB app
    class VMALERT,AM alert
    class IMPULSE impulse
    class CHATA,CHATB chat
    class DEVOPS,DEVA1,DEVA2,DEVB1,DEVB2 person
```

## Легенда связей

- **Сплошные** — прохождение алерта: сервис → `vmalert` (срабатывание VMRule, алерт получает `team=`) → `Alertmanager` (route по `team=`) → `Impulse` (route по `team=` → канал команды) → чат команды в Telegram.
- **Пунктирные** — упоминания/адресация: `tg://user?id=<id>` подсвечивает конкретным людям пуш в треде инцидента; кнопка `Take It` адресуется по `from.id` нажавшего (узнаётся в момент клика, не заранее).
- **`admin_users`** получает `🔔 admins` только как фолбэк: если целевой пользователь из цепочки недостижим (`NotDefined`/`NotFound`) или инцидент перешёл в `unknown`.

### Сценарии срабатывания фолбэка `🔔 admins`

| # | Сценарий | Категория | Поведение Telegram / Impulse |
|---|---|---|---|
| 1 | Юзер не зарегистрирован в `users.<name>.id` в конфиге Impulse | Конфигурация | `UserManager` возвращает `NotDefined` |
| 2 | `users.<name>.id` указан, но TG `user_id` невалиден (опечатка, удалённый аккаунт) | Конфигурация | `NotFound` |
| 3 | Юзер сам вышел из чата команды (`status: left`) | Чат | `getChatMember` → `left`, упоминание не доставлено |
| 4 | Юзера кикнули из чата (`status: kicked`) | Чат | `getChatMember` → `kicked`, упоминание не доставлено |
| 5 | Юзер в рестрикшене — не получает пуш-уведомления об упоминаниях | Чат | `getChatMember` → `restricted`, пуш заглушён |
| 6 | Бот потерял права админа в чате — не может отправлять сообщения/упоминания | Чат | `sendMessage` → `403 Forbidden` |
| 7 | Юзер заблокировал бота в DM | DM | `sendMessage` → `403 Forbidden: bot was blocked by the user` |
| 8 | Юзер удалил/деактивировал аккаунт Telegram | DM | `sendMessage` → `403 Forbidden: user is deactivated` |
| 9 | Юзер запретил писать ему в DM (privacy setting) | DM | `sendMessage` → `403 Forbidden: chat not found` |
| 10 | Инцидент перешёл в `unknown` (алерт от vmalert перестал приходить, но Impulse не получил явного resolved) | Статус инцидента | Impulse не может определить состояние, эскалация на админов |
| 11 | Impulse потерял webhook от Alertmanager / сетевой сбой | Статус инцидента | Инцидент «завис» без обновлений, эскалация на админов |
