# Graph Report - alert-templates-helm-vmalert-impulse  (2026-08-20)

## Corpus Check
- 18 files · ~8,071 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 92 nodes · 144 edges · 11 communities (9 shown, 2 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 21 edges (avg confidence: 0.88)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Terraform Outputs & VMKS Values
- mihomo VLESS Proxy
- Impulse & Alertmanager Routing
- Terraform Telegram Secrets
- Ingress LB & cert-manager
- Yandex VPC Network & NAT
- Helm Cleanup Script
- Go Module
- Helm Chart & VMRule Alerts
- Terraform Rendering Rationale

## God Nodes (most connected - your core abstractions)
1. `local.lb_ip` - 10 edges
2. `yandex_kubernetes_cluster.impulse` - 10 edges
3. `Impulse (incident management over Alertmanager + Telegram)` - 9 edges
4. `VMRule template (golden-signal-alerts)` - 8 edges
5. `local.impulse_values` - 7 edges
6. `yandex_vpc_address.addr` - 6 edges
7. `yandex_kubernetes_node_group.k8s-node-group` - 6 edges
8. `yandex_vpc_network.impulse` - 6 edges
9. `yandex_vpc_route_table.nat-route-table` - 6 edges
10. `helm_release.ingress_nginx` - 5 edges

## Surprising Connections (you probably didn't know these)
- `local_file.vmks_values` --shares_data_with--> `VMRule template (golden-signal-alerts)`  [INFERRED]
  k8s.tf → chart/templates/vmrule.yaml
- `local_file.mihomo_vless_proxy` --shares_data_with--> `mihomo VLESS proxy (Telegram-only routing)`  [INFERRED]
  k8s.tf → INFRASTRUCTURE.md
- `local_file.impulse_values` --shares_data_with--> `Impulse (incident management over Alertmanager + Telegram)`  [INFERRED]
  k8s.tf → README.md
- `VMRule template (golden-signal-alerts)` --references--> `vmalert (VictoriaMetrics alert evaluator, picks up VMRule)`  [INFERRED]
  chart/templates/vmrule.yaml → README.md
- `local.lb_ip` --references--> `yandex_vpc_address.addr`  [EXTRACTED]
  k8s.tf → ip-dns.tf

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Alert pipeline: app metrics -> vmalert VMRule -> Alertmanager -> Impulse -> Telegram** — concept_app_errors_total, concept_app_requests_total, concept_app_request_latency_seconds, concept_app_goroutines, chart_templates_vmrule, concept_vmalert, concept_alertmanager, concept_impulse, concept_route_channel, concept_schedule_chain [INFERRED 0.85]
- **Impulse Telegram addressing model (users config + route + impulse_address + Take It/Freeze callbacks)** — concept_impulse, concept_users_config, concept_route_channel, concept_impulse_address, concept_take_it_freeze, concept_schedule_chain [INFERRED 0.85]
- **golden-signal-app Helm chart templates (Deployment+Service+VMServiceScrape+VMRule fed by values.yaml)** — chart_chart, chart_templates_deployment, chart_templates_service, chart_templates_servicemonitor, chart_templates_vmrule, chart_values [INFERRED 0.95]

## Communities (11 total, 2 thin omitted)

### Community 1 - "Terraform Outputs & VMKS Values"
Cohesion: 0.20
Nodes (18): data.yandex_client_config.client, local_file.vmks_values, local.lb_ip, local.vmks_values, output.alertmanager_url, output.grafana_admin_password_command, output.grafana_admin_user, output.grafana_url (+10 more)

### Community 10 - "mihomo VLESS Proxy"
Cohesion: 0.29
Nodes (6): local_file.mihomo_vless_proxy, local.mihomo_vless_proxy, var.vless_subscription_url, cert-manager + Let's Encrypt ClusterIssuer, mihomo VLESS proxy (Telegram-only routing), Why mihomo routes only Telegram domains via VLESS (save VLESS traffic, geo-blocks)

### Community 2 - "Impulse & Alertmanager Routing"
Cohesion: 0.22
Nodes (11): local_file.impulse_values, Alertmanager (stateless alert router), Impulse (incident management over Alertmanager + Telegram), impulse_address (HTTPS webhook for Telegram callbacks), Impulse route.channel + route.chain, Impulse schedule chains (Asia/Omsk escalation), Take It / Freeze inline buttons (from.id callback), team label routing (team=team-a -> chat) (+3 more)

### Community 3 - "Terraform Telegram Secrets"
Cohesion: 0.31
Nodes (8): local_file.impulse_telegram_secret, local.impulse_values, local.telegram_secret, var.bot_token, var.telegram_admin_id, var.telegram_chat_id, var.telegram_support_id, var.telegram_teamlead_id

### Community 4 - "Ingress LB & cert-manager"
Cohesion: 0.32
Nodes (7): helm_release.ingress_nginx, local.acme_email, local.cluster_issuer, local_file.cluster_issuer, time_sleep.wait_lb_release, var.acme_email, yandex_vpc_address.addr

### Community 5 - "Yandex VPC Network & NAT"
Cohesion: 0.61
Nodes (7): yandex_kubernetes_node_group.k8s-node-group, yandex_vpc_gateway.nat-gateway, yandex_vpc_network.impulse, yandex_vpc_route_table.nat-route-table, yandex_vpc_subnet.impulse-a, yandex_vpc_subnet.impulse-b, yandex_vpc_subnet.impulse-d

### Community 0 - "Helm Chart & VMRule Alerts"
Cohesion: 0.13
Nodes (19): Helm chart golden-signal-app (Chart.yaml), Deployment template (golden-signal-app), Service template (golden-signal-app), VMServiceScrape template (golden-signal-app), VMRule template (golden-signal-alerts), chart/values.yaml (alert thresholds, image, service), Release and Docker GitHub Actions Workflow, Build and push Docker image step (docker/build-push-action) (+11 more)

### Community 6 - "Terraform Rendering Rationale"
Cohesion: 0.40
Nodes (5): sslip.io wildcard DNS naming scheme, Terraform .tftpl -> rendered values (local_file), Why Terraform does not call kubectl (avoid API access errors during apply), Why sslip.io (IP known only after apply, no DNS zone needed), Why render values from .tftpl (LB IP known only after apply)

## Knowledge Gaps
- **13 isolated node(s):** `output.grafana_admin_password_command`, `output.grafana_admin_user`, `cleanup-helm-releases.sh script`, `github.com/patsevanton/alert-templates-helm-vmalert-impulse/app`, `Semver Release Step (huggingface/semver-release-action)` (+8 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `VMRule template (golden-signal-alerts)` connect `Helm Chart & VMRule Alerts` to `Terraform Outputs & VMKS Values`, `Impulse & Alertmanager Routing`?**
  _High betweenness centrality (0.313) - this node is a cross-community bridge._
- **Why does `local_file.vmks_values` connect `Terraform Outputs & VMKS Values` to `Helm Chart & VMRule Alerts`?**
  _High betweenness centrality (0.238) - this node is a cross-community bridge._
- **Why does `Impulse (incident management over Alertmanager + Telegram)` connect `Impulse & Alertmanager Routing` to `mihomo VLESS Proxy`?**
  _High betweenness centrality (0.151) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Impulse (incident management over Alertmanager + Telegram)` (e.g. with `local_file.impulse_values` and `Alertmanager (stateless alert router)`) actually correct?**
  _`Impulse (incident management over Alertmanager + Telegram)` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 4 inferred relationships involving `VMRule template (golden-signal-alerts)` (e.g. with `local_file.vmks_values` and `vmalert (VictoriaMetrics alert evaluator, picks up VMRule)`) actually correct?**
  _`VMRule template (golden-signal-alerts)` has 4 INFERRED edges - model-reasoned connections that need verification._
- **What connects `output.grafana_admin_password_command`, `output.grafana_admin_user`, `cleanup-helm-releases.sh script` to the rest of the system?**
  _13 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Helm Chart & VMRule Alerts` be split into smaller, more focused modules?**
  _Cohesion score 0.1286549707602339 - nodes in this community are weakly interconnected._