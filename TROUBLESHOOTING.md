# Оставшиеся задачи

## Задача 1 (критичная): Impulse не отправляет алерты в Telegram

**Симптом:** Вебхуки от Alertmanager доходят до Impulse (видны в логах `Alert received`), но Impulse не может отправить сообщение в Telegram:
```
Telegram topic creation failed — Bad Request: the chat is not a forum
Incident creation aborted: failed to create thread
channel_id: -810044683
```

**Причина:** Impulse пытается создать топик в чате `-810044683`, но чат не является форумом (супергруппой с включёнными темами). Impulse требует Telegram-чат в формате форума для создания отдельных топиков под инциденты.

**Варианты решения:**
1. Преобразовать существующий чат в супергруппу и включить темы (форум) в настройках Telegram.
2. Создать новый чат-форум и обновить `telegram_chat_id` в `terraform.tfvars`, затем `terraform apply` → `kubectl apply -f impulse-telegram-secret.yaml` → `helm upgrade my-impulse ...`.

**Статус:** Не исправлено. Требует действий пользователя в Telegram.

---

## Задача 2 (разовое): Перезапуск vmalert после установки/обновления VMRule golden-signal-app

**Симптом:** После `helm install/upgrade golden-signal-app` группа правил `golden-signal-alerts` может не загрузиться в vmalert до принудительного reload.

**Workaround:** После установки/обновления demo-приложения выполнить:
```bash
kubectl exec -n vmks deploy/vmalert-vmks-victoria-metrics-k8s-stack -c vmalert -- \
  /bin/sh -c 'wget -qO- --post-data="" http://127.0.0.1:8080/-/reload'
```

**Статус:** Не исправлено. Воспроизводимость бага не подтверждена (возможно разовая проблема v1.149.0).

---

## Задача 3 (разовое): Новый под Impulse зависал на старте после `helm upgrade` (смена `telegram_chat_id`)

**Симптом:** После `helm upgrade my-impulse -f values/values-impulse.yaml` (выполнялся при смене `telegram_chat_id`) новый под Impulse не переходил в primary — висел на старте, `/readyz` отвечал `503` (standby), алерты не отправлялись.

**Причина:** Impulse использует файловый лок для HA-режима (`app/file_lock.py`, `docs/content/concepts/ha.md`):

- При старте под создаёт каталог `.lock.d` в `DATA_PATH` (переменная окружения, обычно PVC, примонтированный в `/data`) — `app/file_lock.py:31`.
- `app/lifespan.py:140-170`: если `.lock.d` уже занят и `can_take_over_lock()` = False → под уходит в **standby** и ждёт `_wait_and_become_primary`, пока лок не освободится.
- `app/file_lock.py:93-116` — `can_take_over_lock()` возвращает True только если совпадают `hostname` (имя пода) и `boot_id`, а записанный PID не активен. При k8s rolling update имя пода меняется (`my-impulse-<rand1>` → `my-impulse-<rand2>`), поэтому takeover не срабатывает.
- `app/file_lock.py:25,134-151` — `is_locked()` возвращает True, пока heartbeat свежая (≤ `STALE_SEC = 18` сек, обновляется каждые `HEARTBEAT_SEC = 6` сек). Новый под ждёт до истечения этого окна.

Сценарий: при `helm upgrade` PVC перемонтировался на новый под, но в нём остался `.lock.d` от старого пода с свежей heartbeat. Поскольку hostname нового пода отличается, takeover не срабатывает → новый под уходит в standby и ждёт, пока heartbeat не устареет (до ~18 сек). Это документированное HA-поведение, но при единственном инстансе в k8s выглядит как зависание на старте. Затянулось, вероятно, из-за того, что readiness-проба на `/readyz` уже успела зайлиться за это время.

**Варианты решения/обхода:**
1. Дождаться истечения `STALE_SEC` (~18 сек) — heartbeat устареет, `_cleanup_stale_lock` удалит `.lock.d`, под перейдёт в primary автоматически (`app/file_lock.py:187-198`, `app/lifespan.py:193-205`).
2. Если не дождался / readiness уже зафейлился — вручную удалить `.lock.d` из PVC:
   ```bash
   kubectl exec -n impulse deploy/my-impulse -- rm -rf /data/.lock.d
   kubectl rollout restart deployment/my-impulse -n impulse
   ```
   (путь `/data` — это `DATA_PATH` из env; проверить через `kubectl exec -n impulse deploy/my-impulse -- env | grep DATA_PATH`).
3. Предотвратить рецидив: убедиться, что `livenessProbe` использует `/livez` (всегда 200, `docs/content/concepts/ha.md:13`), а `readinessProbe` — `/readyz` с `initialDelaySeconds` ≥ 20 и `failureThreshold` ≥ 3, чтобы переход standby→primary за ~18 сек не фейлил под.

**Статус:** Разовое. Воспроизведено один раз при смене `telegram_chat_id`.
