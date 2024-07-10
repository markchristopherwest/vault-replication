locals {
  cluster_manifest = {
    kms = {
      location = "north"
    },
    primary = {
      location = "north"
    },
    dr = {
      location = "south"
    },
    pr-east = {
      location = "east"
    },
    pr-west = {
      location = "west"
    },
  }
  regions = ["north", "south", "east", "west"]
  standard_tags = {
    whoami = data.external.whoami.result["whoami"]
  }
}
data "external" "whoami" {
  program = ["${path.module}/externals/external-whoami.sh"]
}
# https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet
resource "random_pet" "env" {
  length    = 2
  separator = "_"
}
# Step 1 : Generate your Certificates
module "tls_automagically" {
  source            = "github.com/markchristopherwest/terraform-tls-automagically"
  product_manifest  = local.cluster_manifest
  organization_name = "${format("%s", resource.random_pet.env.id)} Unlimited"
  common_name_ca    = "${format("%s", resource.random_pet.env.id)}.local"
  dns_names = concat(
    formatlist("vault-%s.vault-%s-internal", keys(local.cluster_manifest), keys(local.cluster_manifest)),
    formatlist("vault-%s-0.vault-%s-internal", keys(local.cluster_manifest), keys(local.cluster_manifest)),
    formatlist("vault-%s-1.vault-%s-internal", keys(local.cluster_manifest), keys(local.cluster_manifest)),
    formatlist("vault-%s-2.vault-%s-internal", keys(local.cluster_manifest), keys(local.cluster_manifest)),
    formatlist("vault-%s.vault-%s-internal.%s.svc.cluster.local", keys(local.cluster_manifest), keys(local.cluster_manifest), values(local.cluster_manifest)[*]["location"]),
    formatlist("vault-%s-0.vault-%s-internal.%s.svc.cluster.local", keys(local.cluster_manifest), keys(local.cluster_manifest), values(local.cluster_manifest)[*]["location"]),
    formatlist("vault-%s-1.vault-%s-internal.%s.svc.cluster.local", keys(local.cluster_manifest), keys(local.cluster_manifest), values(local.cluster_manifest)[*]["location"]),
    formatlist("vault-%s-2.vault-%s-internal.%s.svc.cluster.local", keys(local.cluster_manifest), keys(local.cluster_manifest), values(local.cluster_manifest)[*]["location"])
  )
  ip_addresses          = ["127.0.0.1"]
  validity_period_hours = 87600
  tags                  = local.standard_tags
}
resource "local_file" "ca_key" {
  content  = module.tls_automagically.content_tls_ca_key
  filename = "${path.module}/tls/_ca.key"
}
resource "local_file" "ca_crt" {
  content  = module.tls_automagically.content_tls_ca_crt
  filename = "${path.module}/tls/_ca.crt"
}
# resource "local_file" "ca_csr" {
#   content  = tls_self_signed_cert.ca.
#   filename = "${path.module}/_ca.csr"
# }
resource "local_file" "subordinate_key" {
  for_each = {
    for k, v in local.cluster_manifest : k => v
  }
  content  = module.tls_automagically.content_tls_server_key["${each.key}"]
  filename = "${path.module}/tls/${resource.random_pet.env.id}_${each.key}.key"
}
resource "local_file" "subordinate_crt" {
  for_each = {
    for k, v in local.cluster_manifest : k => v
  }
  content  = module.tls_automagically.content_tls_server_crt["${each.key}"]
  filename = "${path.module}/tls/${resource.random_pet.env.id}_${each.key}.crt"
}
resource "kubernetes_namespace" "example" {
  for_each = toset(local.regions)
  metadata {
    annotations = {
      name = "example-annotation-${each.value}"
    }
    labels = {
      mylabel = "label-${each.value}"
    }
    name = each.value
  }
}
resource "kubernetes_secret" "vault_license" {
  for_each = toset(local.regions)
  metadata {
    name      = "vault-license"
    namespace = each.value
  }
  data = {
    license = file("./../../../Downloads/vault.hclic")
  }
  type = "Opaque"
  depends_on = [
    kubernetes_namespace.example
  ]
}
resource "kubernetes_secret" "tls_ca" {
  for_each = {
    for k, v in local.cluster_manifest : k => v
    if fileexists(local_file.ca_crt.filename) != null
  }
  metadata {
    name      = "vault-tls-${each.key}"
    namespace = each.value.location
  }
  data = {
    "ca.crt"  = try(file(local_file.ca_crt.filename), "${path.module}/README.md")
    "tls.crt" = try(file(local_file.subordinate_crt[each.key].filename), "${path.module}/README.md")
    "tls.key" = try(file(local_file.subordinate_key[each.key].filename), "${path.module}/README.md")
  }
  type = "kubernetes.io/tls"
  depends_on = [
    module.tls_automagically,
    kubernetes_secret.vault_license,
    kubernetes_namespace.example
  ]
}
resource "helm_release" "vault" {
  for_each = {
    for k, v in local.cluster_manifest : k => v
    if fileexists(local_file.ca_crt.filename) != null
  }
  name       = "vault-${each.key}"
  namespace  = each.value.location
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.25.0"
  set {
    name  = "global.certs.certName"
    value = "vault-tls-${each.key}"
  }
  set {
    name  = "global.certs.keyName"
    value = "vault-tls-${each.key}"
  }
  set {
    name  = "global.certs.secretName"
    value = "vault-tls-${each.key}"
  }
  set {
    name  = "global.enabled"
    value = "true"
  }
  set {
    name  = "global.extraEnvironmentVars.VAULT_CACERT"
    value = "/vault/userconfig/vault-${each.key}/vault-tls-${each.key}"
  }
  set {
    name  = "global.tlsDisable"
    value = "false"
  }
  set {
    name  = "server.volumes[0].name"
    value = "userconfig-vault-${each.key}"
  }
  set {
    name  = "server.volumes[0].secret.defaultMode"
    value = "420"
  }
  set {
    name  = "server.volumes[0].secret.secretName"
    value = "vault-tls-${each.key}"
  }
  set {
    name  = "server.volumeMounts[0].mountPath"
    value = "/vault/userconfig/vault-${each.key}"
  }
  set {
    name  = "server.volumeMounts[0].name"
    value = "userconfig-vault-${each.key}"
  }
  set {
    name  = "server.volumeMounts[0].readOnly"
    value = "true"
  }
  set {
    name  = "image.repository"
    value = "hashicorp/vault-enterprise"
  }
  set {
    name  = "agent.image.tag"
    value = "1.15.1"
  }
  set {
    name  = "injector.agentImage.tag"
    value = "1.15.1"
  }
  set {
    name  = "server.image.repository"
    value = "hashicorp/vault-enterprise"
  }
  set {
    name  = "server.image.tag"
    value = "1.15.1-ent"
  }
  set {
    name  = "agentImage.repository"
    value = "hashicorp/vault"
  }
  set {
    name  = "agentImage.tag"
    value = "1.15.1"
  }
  # set {
  #   name  = "livenessProbe.enabled"
  #   value = true
  # }
  # set {
  #   name  = "livenessProbe.path"
  #   value = "/v1/sys/health?standbyok=true"
  # }
  # set {
  #   name  = "readinessProbe.enabled"
  #   value = true
  # }
  # set {
  #   name  = "readinessProbe.initialDelaySeconds"
  #   value = "60"
  # }
  # set {
  #   name  = "readinessProbe.path"
  #   value = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
  # }
  # set {
  #   name  = "resources.requests.cpu"
  #   value = "500m"
  # }
  # set {
  #   name  = "resources.requests.memory"
  #   value = "256Mi"
  # }
  # set {
  #   name  = "resources.limits.cpu"
  #   value = "500m"
  # }
  # set {
  #   name  = "resources.limits.memory"
  #   value = "256Mi"
  # }
  # set {
  #   name  = "server.auditStorage.enabled"
  #   value = true
  # }
  # set {
  #   name  = "server.dataStorage.enabled"
  #   value = true
  # }
  # set {
  #   name  = "server.dataStorage.storageClass"
  #   value = "local-storage"
  # }
  set {
    name  = "server.ha.apiAddr"
    value = "https://$(HOSTNAME).vault-${each.key}-internal.${each.value.location}.svc.cluster.local:8200"
  }
  set {
    name  = "server.ha.clusterAddr"
    value = "https://$(HOSTNAME).vault-${each.key}-internal.${each.value.location}.svc.cluster.local:8201"
  }
  set {
    name  = "server.ha.enabled"
    value = "true"
  }
  set {
    name  = "server.ha.replicas"
    value = "3"
  }
  set {
    name  = "server.ha.raft.enabled"
    value = true
  }
  set {
    name  = "server.ha.raft.setNodeId"
    value = true
  }
  set {
    name  = "server.enterpriseLicense.secretName"
    value = "vault-license"
  }
  set {
    name  = "server.standalone.enabled"
    value = false
  }
  set {
    name  = "server.affinity"
    value = ""
  }
  set {
    name  = "server.ha.raft.config"
    value = <<EOT
        # https://developer.hashicorp.com/vault/docs/configuration#log_level
        log_level = "debug"
        # https://developer.hashicorp.com/vault/docs/configuration#parameters
        # api_addr      = "https://vault-${each.key}.vault-${each.key}-internal.${each.value.location}.svc.cluster.local:8200"
        # cluster_addr  = "https://vault-${each.key}.vault-${each.key}-internal.${each.value.location}.svc.cluster.local:8201"
        ui = true
        # https://developer.hashicorp.com/vault/docs/configuration#disable_mlock
        disable_mlock = true
        listener "tcp" {
          tls_disable = 0
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/vault/userconfig/vault-${each.key}/tls.crt"
          tls_key_file  = "/vault/userconfig/vault-${each.key}/tls.key"
          tls_client_ca_file = "/vault/userconfig/vault-${each.key}/ca.crt"
        }
        storage "raft" {
            path = "/vault/data"
            retry_join {
                leader_api_addr = "https://vault-${each.key}-0.vault-${each.key}-internal.${each.value.location}.svc.cluster.local:8200"
                leader_ca_cert_file = "/vault/userconfig/vault-${each.key}/tls.crt"
                leader_tls_servername = "vault-${each.key}-0.vault-${each.key}-internal.${each.value.location}.svc.cluster.local"
            }
            retry_join {
                leader_api_addr = "https://vault-${each.key}-1.vault-${each.key}-internal.${each.value.location}.svc.cluster.local:8200"
                leader_ca_cert_file = "/vault/userconfig/vault-${each.key}/tls.crt"
                leader_tls_servername = "vault-${each.key}-1.vault-${each.key}-internal.${each.value.location}.svc.cluster.local"
            }
            retry_join {
                leader_api_addr = "https://vault-${each.key}-2.vault-${each.key}-internal.${each.value.location}.svc.cluster.local:8200"
                leader_ca_cert_file = "/vault/userconfig/vault-${each.key}/tls.crt"
                leader_tls_servername = "vault-${each.key}-2.vault-${each.key}-internal.${each.value.location}.svc.cluster.local"
            }
        }
        # https://developer.hashicorp.com/vault/tutorials/monitoring/monitor-telemetry-grafana-prometheus#vault-configuration
        telemetry {
          disable_hostname = true
          prometheus_retention_time = "12h"
          unauthenticated_metrics_access = true
        }
        service_registration "kubernetes" {}
EOT
  }
  depends_on = [
    # kubernetes_secret.tls_ca, 
    kubernetes_secret.vault_license,
    kubernetes_namespace.example
  ]
}
resource "helm_release" "vault_operator" {
  for_each   = toset(local.regions)
  name       = "hashicorp-vso-${each.key}"
  namespace  = each.key
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault-secrets-operator"
  version    = "0.3.2"
}


resource "kubernetes_namespace" "telemetry" {
  metadata {
    annotations = {
      name = "telemetry"
    }
    labels = {
      mylabel = "label-telemetry"
    }
    name = "telemetry"
  }
}
# resource "helm_release" "cadvisor" {
#   name       = "cadvisor"
#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "promtail"
#   version    = "6.15.3"
#   namespace  = kubernetes_namespace.telemetry.id
#   values = [
#     "${file("${path.root}/config/promtail-values.yml")}"
#   ]
# }
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "5.35.0"
  namespace  = kubernetes_namespace.telemetry.id
  set {
    name  = "loki.auth_enabled"
    value = false
  }
  set {
    name  = "loki.commonConfig.replication_factor"
    value = "1"
  }
  set {
    name  = "loki.commonConfig.storage.type"
    value = "filesystem"
  }
  set {
    name  = "singleBinary.replicas"
    value = "1"
  }
  values = [
    "${file("${path.root}/config/loki-values.yml")}"
  ]
}
resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.15.3"
  namespace  = kubernetes_namespace.telemetry.id
  values = [
    "${file("${path.root}/config/promtail-values.yml")}"
  ]
}

# 
