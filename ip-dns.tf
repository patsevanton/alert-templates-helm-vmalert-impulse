# Создание внешнего IP-адреса в Yandex Cloud
resource "yandex_vpc_address" "addr" {
  name = "impulse-pip" # Имя ресурса внешнего IP-адреса

  external_ipv4_address {
    zone_id = yandex_vpc_subnet.impulse-a.zone # Зона доступности, где будет выделен IP-адрес
  }
}

# Публичный DNS не требуется: используются sslip.io-имена вида <сервис>.<LB_IP>.sslip.io
# (grafana, vmselect, alertmanager, vmalert, impulse), которые резолвятся в IP балансировщика.
