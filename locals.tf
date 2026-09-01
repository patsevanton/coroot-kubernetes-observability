locals {
  folder_id  = var.folder_id
  network_id = yandex_vpc_network.coroot.id

  subnet_b_id   = yandex_vpc_subnet.coroot-b.id
  subnet_d_id   = yandex_vpc_subnet.coroot-d.id
  subnet_e_id   = yandex_vpc_subnet.coroot-e.id
  subnet_b_zone = yandex_vpc_subnet.coroot-b.zone
  subnet_d_zone = yandex_vpc_subnet.coroot-d.zone
  subnet_e_zone = yandex_vpc_subnet.coroot-e.zone

  # Публичный IP балансировщика ingress-nginx. FQDN Coroot формируется через sslip.io
  # из этого адреса (см. outputs в k8s.tf и coroot.tf).
  ingress_public_ip = yandex_vpc_address.addr.external_ipv4_address[0].address
  coroot_fqdn       = "coroot.${local.ingress_public_ip}.sslip.io"
}
