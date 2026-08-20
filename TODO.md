# TODO

## Инфраструктура

- [ ] Использовать mihomo как VLESS-прокси для исходящего трафика по образцу https://github.com/patsevanton/nora-yandex-k8s-deploy/blob/main/INFRASTRUCTURE.md (раздел «Шаг 2. VLESS-прокси для исходящего трафика NORA (Terraform upstream)»). Поднять mihomo отдельным Deployment + Service в кластере; правила маршрутизации отправляют в VLESS только домены telegram, остальное — DIRECT. Secret с URL VLESS-подписки брать из terraform.tfvars. Нужно сделать заготовку URL VLESS-подписки в terraform.tfvars. настроить фильтр зарубежных серверов в `proxy-groups.auto`. impulse отправляет алерты в telegram через mihomo