# Ресурс для создания сети VPC в Yandex Cloud
resource "yandex_vpc_network" "coroot" {
  name = "coroot-vpc" # Имя сети VPC
}

# Ресурс для создания подсети в зоне "ru-central1-b"
resource "yandex_vpc_subnet" "coroot-b" {
  v4_cidr_blocks = ["10.0.1.0/24"]              # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-b"              # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.coroot.id # ID сети, к которой будет привязана подсеть
  route_table_id = yandex_vpc_route_table.rt.id # Маршрутизация исходящего трафика через NAT-шлюз
}

# Ресурс для создания подсети в зоне "ru-central1-d"
resource "yandex_vpc_subnet" "coroot-d" {
  v4_cidr_blocks = ["10.0.2.0/24"]              # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-d"              # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.coroot.id # ID сети, к которой будет привязана подсеть
  route_table_id = yandex_vpc_route_table.rt.id # Маршрутизация исходящего трафика через NAT-шлюз
}

# Ресурс для создания подсети в зоне "ru-central1-e"
resource "yandex_vpc_subnet" "coroot-e" {
  v4_cidr_blocks = ["10.0.3.0/24"]              # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-e"              # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.coroot.id # ID сети, к которой будет привязана подсеть
  route_table_id = yandex_vpc_route_table.rt.id # Маршрутизация исходящего трафика через NAT-шлюз
}

# Публичный IP-адрес для NAT-шлюза
resource "yandex_vpc_address" "nat" {
  name = "coroot-nat-pip"
  external_ipv4_address {
    zone_id = yandex_vpc_subnet.coroot-b.zone
  }
}

# NAT-шлюз в зоне "ru-central1-b" для исходящего трафика из приватных подсетей
resource "yandex_vpc_gateway" "nat" {
  name = "coroot-nat-gw"
  shared_egress_gateway {}
}

# Таблица маршрутизации: весь исходящий трафик (0.0.0.0/0) направляем через NAT-шлюз
resource "yandex_vpc_route_table" "rt" {
  name       = "coroot-rt-nat"
  network_id = yandex_vpc_network.coroot.id
  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}
