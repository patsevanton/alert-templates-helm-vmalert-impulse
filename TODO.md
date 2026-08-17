# TODO

## Инфраструктура

- [ ] Использовать mihomo как VLESS-прокси для исходящего трафика по образцу https://github.com/patsevanton/nora-yandex-k8s-deploy/blob/main/INFRASTRUCTURE.md (раздел «Шаг 2. VLESS-прокси для исходящего трафика NORA (Terraform upstream)»). Поднять mihomo отдельным Deployment + Service в кластере; правила маршрутизации отправляют в VLESS только домены Terraform/HashiCorp, остальное — DIRECT. Заполнить Secret с URL VLESS-подписки, настроить фильтр зарубежных серверов в `proxy-groups.auto`.
