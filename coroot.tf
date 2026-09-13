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
    metricsRefreshInterval = "30s"

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

    # Доступ к UI через Traefik; домен coroot.<ip>.sslip.io формируется из публичного IP
    ingress = {
      className = "traefik"
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

    # Java-профилирование: node-agent динамически подгружает async-profiler
    # в HotSpot JVM (CPU/alloc/lock) без Java-агента и изменений в приложении.
    # JVM-флаги не обязательны, но в демо заданы (см. apps/java/Dockerfile),
    # чтобы минимизировать долю [unknown] во флеймграфе.
    nodeAgent = {
      env = [
        {
          name  = "ENABLE_JAVA_ASYNC_PROFILER"
          value = "true"
        }
      ]
    }

    # PVC самого Coroot (кэш метрик)
    storage = {
      size = "10Gi"
    }
  }
}

# Namespace для Coroot. Сам Coroot ставится руками через Helm (см. README),
# Terraform создаёт namespace, чтобы подготовить Secret с паролем админа.
resource "kubernetes_namespace" "coroot" {
  metadata {
    name = "coroot"
  }

  depends_on = [
    helm_release.traefik,
  ]
}

# Secret с паролем администратора Coroot. Существует до установки Coroot CR.
resource "kubernetes_secret" "coroot_admin" {
  metadata {
    name      = "coroot-admin-secret"
    namespace = kubernetes_namespace.coroot.metadata[0].name
  }

  data = {
    "admin-password" = var.coroot_admin_password
  }
}

# values.yaml для ручной установки Coroot CE. Секрета в файле нет — только
# ссылка на Secret, пароль остаётся в Kubernetes Secret выше.
# Установка: helm install coroot oci://ghcr.io/coroot/charts/coroot-ce -n coroot -f coroot-values.yaml
resource "local_file" "coroot_values" {
  filename = "${path.module}/coroot-values.yaml"
  content  = yamlencode(local.coroot_cr)

  depends_on = [
    kubernetes_secret.coroot_admin,
  ]
}

output "coroot_admin_password_command" {
  description = "Команда kubectl для получения пароля администратора Coroot из секрета (логин admin)"
  value       = "kubectl -n ${kubernetes_secret.coroot_admin.metadata[0].namespace} get secret ${kubernetes_secret.coroot_admin.metadata[0].name} -o jsonpath='{.data.admin-password}' | base64 -d"
}

output "coroot_admin_password" {
  description = "Пароль администратора Coroot для входа в UI (логин admin)"
  value       = var.coroot_admin_password
  sensitive   = true
}
