# Переменная с паролем администратора Coroot (bootstrap admin password).
# Пароль попадает только в Kubernetes Secret (см. coroot.tf) — не в values и не в git.
variable "coroot_admin_password" {
  type        = string
  sensitive   = true
  description = "Пароль администратора Coroot (bootstrap admin password)"
}

locals {
  # Coroot CR (Custom Resource) для оператора. Все значения уходят в spec Coroot CR.
  # Всё хранилище данных ограничено 1 часом:
  #   - logsTTL / tracesTTL / profilesTTL — TTL таблиц ClickHouse (логи, трейсы, профили)
  #   - cacheTTL — TTL метрического кэша Coroot
  #   - prometheus.retention — retention встроенного Prometheus (метрики)
  coroot_cr = {
    metricsRefreshInterval = "15s"

    # Retention: данные Coroot хранятся не дольше 1 часа
    cacheTTL    = "1h"
    tracesTTL   = "1h"
    logsTTL     = "1h"
    profilesTTL = "1h"

    # Пароль администратора берём из Secret, а не из CR
    authBootstrapAdminPasswordSecret = {
      name = kubernetes_secret.coroot_admin.metadata[0].name
      key  = "admin-password"
    }

    # Доступ к UI через ingress-nginx; домен coroot.<ip>.sslip.io формируется из публичного IP
    ingress = {
      className = "nginx"
      host      = local.coroot_fqdn
      path      = "/"
    }

    # ClickHouse: логи/трейсы/профили. 1 shard / 1 replica — достаточно для демо.
    # Keeper по умолчанию 3 реплики; для 3 нод демо-кластера уменьшаем до 1.
    clickhouse = {
      shards   = 1
      replicas = 1
      keeper = {
        replicas = 1
      }
      storage = {
        size = "20Gi"
      }
    }

    # Встроенный Prometheus: метрики, retention 1 час
    prometheus = {
      retention = "1h"
      storage = {
        size = "10Gi"
      }
    }

    # PVC самого Coroot (кэш метрик)
    storage = {
      size = "10Gi"
    }
  }
}

# Установка оператора Coroot (управляет Coroot CR, node-agent, cluster-agent, Prometheus, ClickHouse)
resource "helm_release" "coroot_operator" {
  name             = "coroot-operator"
  repository       = "https://coroot.github.io/helm-charts"
  chart            = "coroot-operator"
  version          = "0.9.9"
  namespace        = "coroot"
  create_namespace = true

  depends_on = [
    helm_release.ingress_nginx,
  ]
}

# Secret с паролем администратора Coroot. Существует до создания Coroot CR.
resource "kubernetes_secret" "coroot_admin" {
  metadata {
    name      = "coroot-admin-secret"
    namespace = "coroot"
  }

  data = {
    "admin-password" = var.coroot_admin_password
  }

  depends_on = [
    helm_release.coroot_operator,
  ]
}

# Coroot Community Edition: Helm-чарт рендерит Coroot CR (spec — из values)
resource "helm_release" "coroot" {
  name       = "coroot"
  repository = "https://coroot.github.io/helm-charts"
  chart      = "coroot-ce"
  version    = "0.3.3"
  namespace  = "coroot"

  values = [
    yamlencode(local.coroot_cr)
  ]

  depends_on = [
    helm_release.coroot_operator,
    kubernetes_secret.coroot_admin,
  ]
}

output "coroot_admin_secret_name" {
  description = "Имя Kubernetes Secret с паролем администратора Coroot"
  value       = kubernetes_secret.coroot_admin.metadata[0].name
}
