# Ресурс для создания сети VPC в Yandex Cloud
resource "yandex_vpc_network" "impulse" {
  name = "impulse" # Имя сети VPC
}

# NAT-шлюз для исходящего трафика из приватных подсетей
resource "yandex_vpc_gateway" "nat-gateway" {
  name = "nat-gateway" # Имя NAT-шлюза
}

# Таблица маршрутизации, направляющая 0.0.0.0/0 через NAT-шлюз
resource "yandex_vpc_route_table" "nat-route-table" {
  name       = "nat-route-table"             # Имя таблицы маршрутизации
  network_id = yandex_vpc_network.impulse.id # Сеть, к которой привязана таблица

  static_route {
    destination_prefix = "0.0.0.0/0"                       # Маршрут по умолчанию
    gateway_id         = yandex_vpc_gateway.nat-gateway.id # Следующий хоп — NAT-шлюз
  }
}

# Ресурс для создания подсети в зоне "ru-central1-a"
resource "yandex_vpc_subnet" "impulse-a" {
  v4_cidr_blocks = ["10.0.1.0/24"]                           # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-a"                           # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.impulse.id             # ID сети, к которой будет привязана подсеть
  route_table_id = yandex_vpc_route_table.nat-route-table.id # Таблица маршрутизации через NAT-шлюз
}

# Ресурс для создания подсети в зоне "ru-central1-b"
resource "yandex_vpc_subnet" "impulse-b" {
  v4_cidr_blocks = ["10.0.2.0/24"]                           # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-b"                           # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.impulse.id             # ID сети, к которой будет привязана подсеть
  route_table_id = yandex_vpc_route_table.nat-route-table.id # Таблица маршрутизации через NAT-шлюз
}

# Ресурс для создания подсети в зоне "ru-central1-d"
resource "yandex_vpc_subnet" "impulse-d" {
  v4_cidr_blocks = ["10.0.3.0/24"]                           # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-d"                           # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.impulse.id             # ID сети, к которой будет привязана подсеть
  route_table_id = yandex_vpc_route_table.nat-route-table.id # Таблица маршрутизации через NAT-шлюз
}
