# Оставшиеся задачи

## Задача 2 (разовое): Новый под Impulse зависал на старте после `helm upgrade` (смена `telegram_chat_id`)

**Симптом:** После `helm upgrade impulse -f values/values-impulse.yaml` (выполнялся при смене `telegram_chat_id`) новый под Impulse не переходил в primary — висел на старте, `/readyz` отвечал `503` (standby), алерты не отправлялись.

**Причина:** Impulse использует файловый лок для HA-режима (`app/file_lock.py`, `docs/content/concepts/ha.md`):

- При старте под создаёт каталог `.lock.d` в `DATA_PATH` (переменная окружения, обычно PVC, примонтированный в `/data`) — `app/file_lock.py:31`.
- `app/lifespan.py:140-170`: если `.lock.d` уже занят и `can_take_over_lock()` = False → под уходит в **standby** и ждёт `_wait_and_become_primary`, пока лок не освободится.
- `app/file_lock.py:93-116` — `can_take_over_lock()` возвращает True только если совпадают `hostname` (имя пода) и `boot_id`, а записанный PID не активен. При k8s rolling update имя пода меняется (`impulse-<rand1>` → `impulse-<rand2>`), поэтому takeover не срабатывает.
- `app/file_lock.py:25,134-151` — `is_locked()` возвращает True, пока heartbeat свежая (≤ `STALE_SEC = 18` сек, обновляется каждые `HEARTBEAT_SEC = 6` сек). Новый под ждёт до истечения этого окна.

Сценарий: при `helm upgrade` PVC перемонтировался на новый под, но в нём остался `.lock.d` от старого пода с свежей heartbeat. Поскольку hostname нового пода отличается, takeover не срабатывает → новый под уходит в standby и ждёт, пока heartbeat не устареет (до ~18 сек). Это документированное HA-поведение, но при единственном инстансе в k8s выглядит как зависание на старте. Затянулось, вероятно, из-за того, что readiness-проба на `/readyz` уже успела зайлиться за это время.

**Варианты решения/обхода:**
1. Дождаться истечения `STALE_SEC` (~18 сек) — heartbeat устареет, `_cleanup_stale_lock` удалит `.lock.d`, под перейдёт в primary автоматически (`app/file_lock.py:187-198`, `app/lifespan.py:193-205`).
2. Если не дождался / readiness уже зафейлился — вручную удалить `.lock.d` из PVC:
   ```bash
   kubectl exec -n impulse deploy/impulse -- rm -rf /data/.lock.d
   kubectl rollout restart deployment/impulse -n impulse
   ```
   (путь `/data` — это `DATA_PATH` из env; проверить через `kubectl exec -n impulse deploy/impulse -- env | grep DATA_PATH`).
3. Предотвратить рецидив: убедиться, что `livenessProbe` использует `/livez` (всегда 200, `docs/content/concepts/ha.md:13`), а `readinessProbe` — `/readyz` с `initialDelaySeconds` ≥ 20 и `failureThreshold` ≥ 3, чтобы переход standby→primary за ~18 сек не фейлил под.

**Статус:** Разовое. Воспроизведено один раз при смене `telegram_chat_id`.
