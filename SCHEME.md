# Схема адресации инцидентов в Telegram

Сценарий: 2 сервиса (`golden-signal-app` с `team=team-a` и `team=team-b`) → 2 команды разработки (в каждой `teamlead` + `oncall`-дежурный) + 2 чата команд в Telegram. Роутинг по `team=` выбран в `route.routes` Impulse; порядок уведомлений внутри чата задаётся schedule-chain.

```mermaid
flowchart TD
    subgraph Apps["Сервисы (Helm-чарт golden-signal-app)"]
        APPA["app-team-a<br/>label: team=team-a<br/>метрики app_*"]
        APPB["app-team-b<br/>label: team=team-b<br/>метрики app_*"]
    end

    VMALERT["vmalert<br/>VMRule: HighErrorRate / HighLatency / HighGoroutineCount<br/>алерт наследует label team="]
    AM["Alertmanager<br/>route по team= → webhook"]
    IMPULSE["Impulse<br/>route по team= → channel + chain команды"]

    subgraph Chains["Escalation chains (type: schedule, Asia/Omsk)"]
        CHA_ON["team_a_escalation<br/>будни 09:00–20:00<br/>oncall-a → wait 5m → teamlead-a"]
        CHA_OFF["team_a_escalation (вне окна / выходные)<br/>wait 5m → teamlead-a"]
        CHB_ON["team_b_escalation<br/>будни 09:00–20:00<br/>oncall-b → wait 5m → teamlead-b"]
        CHB_OFF["team_b_escalation (вне окна / выходные)<br/>wait 5m → teamlead-b"]
    end

    subgraph Telegram["Telegram (чат — форум с Topics)"]
        CHATA["team-a chat<br/>incidents_team_a"]
        CHATB["team-b chat<br/>incidents_team_b"]
    end

    subgraph People["Люди (telegram_user_id / telegram_teamlead_id)"]
        DEVOPS["devops<br/>admin_user<br/>TG ID: telegram_user_id"]
        TLA["teamlead-a<br/>TG ID: telegram_teamlead_id"]
        TLB["teamlead-b<br/>TG ID: telegram_teamlead_id"]
        ONCA["oncall-a<br/>TG ID: telegram_user_id"]
        ONCB["oncall-b<br/>TG ID: telegram_user_id"]
    end

    APPA --> VMALERT
    APPB --> VMALERT
    VMALERT -->|"алерт team=team-a"| AM
    VMALERT -->|"алерт team=team-b"| AM
    AM --> IMPULSE
    IMPULSE -->|"team=team-a → chain team_a_escalation"| CHA_ON
    IMPULSE -->|"team=team-a (вне окна)"| CHA_OFF
    IMPULSE -->|"team=team-b → chain team_b_escalation"| CHB_ON
    IMPULSE -->|"team=team-b (вне окна)"| CHB_OFF

    CHA_ON -->|"тег дежурного сразу"| CHATA
    CHA_ON -->|"wait 5m → тег teamlead"| CHATA
    CHA_OFF -->|"wait 5m → тег teamlead"| CHATA
    CHB_ON -->|"тег дежурного сразу"| CHATB
    CHB_ON -->|"wait 5m → тег teamlead"| CHATB
    CHB_OFF -->|"wait 5m → тег teamlead"| CHATB

    CHATA -.->|"упоминание tg://user?id="| ONCA
    CHATA -.-> TLA
    CHATB -.-> ONCB
    CHATB -.-> TLB

    CHATA -.->|"кнопка Take It<br/>from.id из callback"| ONCA
    CHATA -.-> TLA
    CHATB -.-> ONCB
    CHATB -.-> TLB

    CHATA -.->|"если @oncall-a/@teamlead-a недостижимы<br/>→ 🔔 admins"| DEVOPS
    CHATB -.->|"если @oncall-b/@teamlead-b недостижимы<br/>→ 🔔 admins"| DEVOPS

    classDef app fill:#e8f5e9,stroke:#388e3c,color:#000
    classDef alert fill:#ffebee,stroke:#c62828,color:#000
    classDef impulse fill:#f3e5f5,stroke:#7b1fa2,color:#000
    classDef chain fill:#ede7f6,stroke:#5e35b1,color:#000
    classDef chat fill:#fff3e0,stroke:#f57c00,color:#000
    classDef person fill:#e1f5ff,stroke:#0288d1,color:#000

    class APPA,APPB app
    class VMALERT,AM alert
    class IMPULSE impulse
    class CHA_ON,CHA_OFF,CHB_ON,CHB_OFF chain
    class CHATA,CHATB chat
    class DEVOPS,TLA,TLB,ONCA,ONCB person
```

## Легенда связей

- **Сплошные** — прохождение алерта: сервис → `vmalert` (срабатывание VMRule, алерт получает `team=`) → `Alertmanager` (route по `team=`) → `Impulse` (route по `team=` → channel + chain команды) → чат команды в Telegram.
- **Сплошные через chains** — порядок эскалации внутри чата: schedule-chain (Asia/Omsk) в будни 09:00–20:00 тегает `oncall` сразу, через 5 минут — `teamlead`; вне этого окна (будни 20:00–09:00 и выходные) `oncall` отсутствует, остаётся `wait 5m → teamlead`. Матчеры оцениваются сверху вниз, ветка без matcher — fallback.
- **Пунктирные** — упоминания/адресация: `tg://user?id=<id>` подсвечивает конкретным людям пуш в треде инцидента; кнопка `Take It` адресуется по `from.id` нажавшего (узнаётся в момент клика, не заранее).
- **`admin_users`** получает `🔔 admins` только как фолбэк: если целевой пользователь из цепочки недостижим (`NotDefined`/`NotFound`) или инцидент перешёл в `unknown`.

> В демо-инфраструктуре `oncall-a`, `oncall-b` и `admin_user` свернуты в один `telegram_user_id` (один физический аккаунт), а `teamlead-a`/`teamlead-b` — в один `telegram_teamlead_id`. Схема изображает их как отдельных людей; в проде каждому соответствует свой TG ID.

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
