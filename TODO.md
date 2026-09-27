# TODO

## Направление (новая схема алертинга)

Целевая схема: **Mattermost — основной канал дежурства**, в нём заведены пользователи-дежурные и живёт рабочий поток инцидентов. **Telegram, SMS (sms.ru) и голосовой звонок (zvonok.com) — каналы эскалации**, если инцидент не взят в работу (не нажата кнопка Take It) за отведённое время. Эскалация и ротация дежурных — по образцу Google SRE / PagerDuty-модели.

```
vmalert → Alertmanager → Impulse (messenger: mattermost) → чат дежурных в Mattermost
                              │ инцидент не взят за N минут
                              ▼
                    эскалация по шагам (schedule-chain):
                    Telegram-тег → SMS (sms.ru) → звонок (zvonok.com) → следующая ступень
```

## Открытые вопросы (разобрать до реализации)

### A. Дежурство
- [ ] Точная дата «этого дня», когда дежурит владелец репозитория, и часовой пояс смены (сейчас в цепочках `Asia/Omsk` — подходит?).
- [ ] Кто дежурит в остальные дни: имя/идентификаторы (Mattermost-юзер, Telegram user_id, телефон +7...). Пока заглушка (второй дежурный = владелец, как сейчас все роли — один человек)?
- [ ] Модель чередования ротации: (а) одна дата «владелец», дальше другой; (б) по дням недели; (в) по неделям (`dow % 2` в Impulse); (г) вручную через UI chain.
- [ ] Окно дежурства: оставить «будни 09:00–20:00» или сделать 24/7.

### B. Zvonok.com
- [ ] Кампания в ЛК создана? Тип («API-обзвон» / «Свободный текст»)? Получить `campaign_id` и `public_key`.
- [ ] Текст робота (задаётся в кампании) — какой текст?
- [ ] IVR-подтверждение («нажмите 1, чтобы принять» → остановка цепочки, аналог Take It) или звонок просто уведомление?
- [ ] Кому звонить: только дежурному (L1) или всей цепочке L1 → teamlead → support.

### C. sms.ru
- [ ] `api_token` — положить в `terraform.tfvars` как sensitive (по образцу `bot_token`).
- [ ] Имя отправителя (подпись) — зарегистрировано и одобрено? Если нет, SMS пойдёт с дефолтного номера.
- [ ] Текст SMS: `alertname + summary`? Учесть: кириллица — 70 символов в SMS.

### D. «Как в Google» — объём изменений
- [ ] Маршрутизация по severity: `critical` → звонок + SMS + Telegram, `warning` → только основной канал (Mattermost)?
- [ ] Момент звонка при `critical`: сразу при инциденте (Google page) или через N минут без Take It? Порядок шагов: Telegram-тег → звонок → SMS или звонок сразу?
- [ ] Повторять звонок, если не взяли трубку / не нажали Take It? Сколько раз, с каким интервалом?
- [ ] Что ещё из google-подхода делаем в этом заходе: `inhibit_rules` (warning глушится при firing critical), `group_by`/`group_wait` в Alertmanager, `repeat_interval` по severity, `runbook_url` в annotations алертов, SLO/burn-rate алерты (большая переделка), `new_firing: true`.
- [ ] Telegram/SMS/звонок добавляются ступенями эскалации поверх Mattermost — верно?

### E. Секреты и проверка
- [ ] Ключи zvonok.com и sms.ru хранить в `terraform.tfvars` (не в git) и рендерить в env/Secret Impulse. Телефоны дежурных — тоже в `terraform.tfvars`.
- [ ] После деплоя тестовый прогон: реальный звонок + SMS на номер дежурного.

## Mattermost (основной канал дежурства)

- [ ] Поднять Mattermost (https://github.com/mattermost/mattermost) в кластере K8s: выбрать способ установки (официальный Helm-чарт mattermost/mattermost-enterprise-edition или mattermost/mattermost-team-edition), определить namespace (по умолчанию `mattermost`), настроить БД (PostgreSQL — встроенный subchart или внешний Yandex Managed PostgreSQL), хранилище (PVC для плагинов/файлов), ingress+TLS через cert-manager+ingress-nginx (домен `mattermost.<LB_IP>.sslip.io`), рендер values из `.tftpl` с плейсхолдером `${lb_ip}` по образцу vmks/impulse, применить через `helm_release` в `k8s.tf` или вручную `helm install`. Решить вопрос лицензии (Enterprise trial vs Team Edition OSS). Завести output `mattermost_url` → `https://mattermost.<LB_IP>.sslip.io`. Проверить доступность UI и работоспособность входящих вебхуков (incoming webhook).
- [ ] Создать пользователей для дежурства в Mattermost: дежурный (L1), teamlead (L2), дежурный техподдержки (L3), админ. По модели ротации (см. вопрос A) — как минимум два дежурных, чередующихся по расписанию.
- [ ] Настроить в Mattermost канал инцидентов (по образцу `incidents_team_a`) и входящий вебхук (incoming webhook), получить URL вида `https://mattermost.<LB_IP>.sslip.io/hooks/<token>`.
- [ ] Переключить Impulse на Mattermost как messenger (`messenger.type: mattermost`): users/channels/impulse_address (callback кнопок Take It/Freeze), рендер values из `.tftpl`, обновить README/AGENTS.md.
- [ ] Добавить переменные в `versions.tf` (`mattermost_webhook_url` и при необходимости идентификаторы каналов/пользователей), рендерить Secret с учётными данными Mattermost из Terraform.

## Эскалация (Telegram + SMS + звонок)

- [ ] Интеграция zvonok.com: Impulse webhooks-шаг (`url: https://zvonok.com/manager/cabapi_external/api/v1/phones/call/`, `data: campaign_id / phone / public_key`) — см. [документацию Impulse zvonok.com](https://docs.impulse.bot/stable/integrations/external/zvonok/). Env `ZVONOK_CAMPAIGN_ID` / `ZVONOK_PUBLIC_KEY` передать в Impulse через values/Secret. Один webhook на человека (телефон зашивается в webhook, jinja берёт данные из incident/env).
- [ ] Интеграция sms.ru: Impulse generic-webhook (`url: https://sms.ru/sms/send/`, `data: api_token / to / msg` или `json`). Параметры `SMS_RU_API_TOKEN`, телефон дежурного — в env/Secret. Учесть лимит 70 символов на SMS при кириллице.
- [ ] Telegram-эскалация: шаг `webhook` на Telegram Bot API (`sendMessage` в чат/личку дежурного) либо штатная внешняя интеграция Impulse `telegram.org` (см. External Notifications). Учесть, что из кластера доступ к api.telegram.org идёт через mihomo VLESS-прокси (см. вопрос про mihomo ниже).
- [ ] Переписать schedule-chain `team_a_escalation` в `values/values-impulse.yaml.tftpl`: ступени эскалации с шагами `webhook` (Telegram/SMS/звонок) и `user` (Mattermost-тег), `wait` между ступенями, вложенная `support_escalation`, остановка по Take It. Ротация дежурных по модели из вопроса A (`start_day_expr: dow / dom / date`, `dow % 2` или UI chain).
- [ ] Маршрутизация Impulse `route.routes` по severity: `critical` → цепочка с звонком+SMS+Telegram, `warning` → только тег в Mattermost (см. вопрос D).
- [ ] Google-подход в Alertmanager (`values/vmks-values.yaml.tftpl`): `group_by`/`group_wait`, `inhibit_rules`, `repeat_interval` по severity (критичные повторяются чаще до Take It).
- [ ] `runbook_url` в annotations всех алертов (`chart/templates/vmrule.yaml`) + сами runbooks.
- [ ] Включить `incident.notifications.new_firing: true` (по Google-модели уведомление о новом инциденте обязательно, с него стартует эскалация).
- [ ] Определить политику повторного дозвона при неответе (сколько раз, интервал, интервал) — см. вопрос D.

## Инфраструктура

- [ ] Отменить удаление Telegram: по новой схеме Telegram остаётся как **канал эскалации** (а не основной канал алертов). Пересмотреть план: убрать только telegram-секцию из messenger Impulse (теперь messenger — Mattermost), оставить webhook-шаги Telegram-эскалации и переменные/секреты, которые им нужны (`bot_token`, id чата/пользователей). Уточнить состав удаляемого после решения вопросов A–E.
- [ ] Пересмотреть необходимость mihomo VLESS-прокси: он нужен для доставки Telegram-эскалации (api.telegram.org из кластера). Если Telegram-эскалация остаётся — прокси оставить (или заменить на иной способ доступа); если нет — удалить `mihomo-vless-proxy.yaml.tftpl`, переменную `vless_subscription_url`, env `HTTPS_PROXY`/`http_proxy`/`NO_PROXY` в values Impulse, раздел про mihomo в AGENTS.md.
- [ ] Добавить поддержку отправки алертов в Mattermost: после поднятия сервера настроить в нём входящий вебхук (incoming webhook) для канала алертов и получить URL вида `https://mattermost.<LB_IP>.sslip.io/hooks/<token>`; добавить переменные в `versions.tf`; рендерить Secret; обновить values Impulse; обновить README/AGENTS.md.
