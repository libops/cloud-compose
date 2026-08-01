locals {
  linode                      = var.linode
  runtime                     = var.runtime
  compose                     = var.runtime.compose
  sitectl                     = var.runtime.sitectl
  docker                      = var.runtime.docker
  managed                     = var.runtime.managed_runtime
  vault                       = var.runtime.vault
  label_prefix                = trimsuffix(substr(var.name, 0, 20), "-")
  label_hash                  = substr(sha1(var.name), 0, 6)
  data_volume_label           = "${local.label_prefix}-${local.label_hash}-data"
  docker_volumes_volume_label = "${local.label_prefix}-${local.label_hash}-dock"
  firewall_label              = "${local.label_prefix}-${local.label_hash}-fw"
}

module "runtime" {
  source = "../linux-vm-runtime"

  name                    = var.name
  provider_name           = "linode"
  region                  = local.linode.region
  data_device             = "/dev/disk/by-id/scsi-0Linode_Volume_${local.data_volume_label}"
  volumes_device          = "/dev/disk/by-id/scsi-0Linode_Volume_${local.docker_volumes_volume_label}"
  ssh_users               = merge(local.runtime.users, local.linode.ssh.users)
  cloud_compose_ssh_keys  = local.linode.ssh.cloud_compose_keys
  rootfs                  = local.runtime.rootfs
  rootfs_archive_url      = local.runtime.rootfs_archive_url
  rootfs_archive_sha256   = local.runtime.rootfs_archive_sha256
  ingress_port            = local.compose.ingress_port
  primary_compose_project = local.compose.primary
  sitectl_ingress         = local.compose.ingress
  docker_compose_repo     = local.compose.repo
  docker_compose_branch   = local.compose.branch
  compose_projects        = local.compose.projects
  docker_compose_init     = local.compose.init
  docker_compose_up       = local.compose.up
  docker_compose_down     = local.compose.down
  docker_compose_rollout  = local.compose.rollout
  rollout_enabled         = local.linode.rollout.enabled
  rollout_release_url     = local.linode.rollout.release_url
  rollout_release_sha256  = local.linode.rollout.release_sha256
  rollout_port            = local.linode.rollout.port
  rollout_jwks_uri        = local.linode.rollout.jwks_uri
  rollout_jwt_audience    = local.linode.rollout.jwt_audience
  rollout_custom_claims   = local.linode.rollout.custom_claims

  sitectl_packages         = local.sitectl.packages
  sitectl_version          = local.sitectl.version
  sitectl_package_versions = local.sitectl.package_versions
  sitectl_context_name     = local.sitectl.context_name
  sitectl_plugin           = local.sitectl.plugin
  sitectl_environment      = local.sitectl.environment
  sitectl_verify_args      = local.sitectl.verify_args
  docker_compose_version   = local.docker.compose_version
  docker_buildx_version    = local.docker.buildx_version

  libops_managed_runtime_enabled       = local.managed.enabled
  libops_internal_services_enabled     = local.managed.internal_services_enabled
  libops_internal_services_auto_update = local.managed.internal_services_auto_update
  libops_managed_artifacts             = local.managed.artifacts

  vault_addr                    = local.vault.addr
  vault_namespace               = local.vault.namespace
  vault_role                    = local.vault.role
  vault_agent_enabled           = local.vault.agent_enabled
  vault_auth_method             = local.vault.auth_method
  vault_agent_token_path        = local.vault.agent_token_path
  vault_agent_templates         = local.vault.agent_templates
  vault_agent_additional_config = local.vault.agent_additional_config
  extra_env                     = local.runtime.extra_env
}

locals {
  ingress_ports = distinct([for _, app in module.runtime.compose_projects : tostring(app.ingress_port)])
}

resource "linode_instance" "cloud_compose" {
  label            = var.name
  region           = local.linode.region
  type             = local.linode.instance.type
  image            = local.linode.instance.image
  authorized_keys  = local.linode.instance.authorized_keys
  authorized_users = local.linode.instance.authorized_users
  root_pass        = local.linode.instance.root_pass
  private_ip       = local.linode.instance.private_ip
  backups_enabled  = local.linode.instance.backups_enabled
  watchdog_enabled = local.linode.instance.watchdog_enabled
  tags             = local.linode.tags

  metadata {
    user_data = base64gzip(module.runtime.cloud_init)
  }

  lifecycle {
    precondition {
      condition     = length(local.linode.instance.authorized_keys) > 0 || length(local.linode.instance.authorized_users) > 0 || local.linode.instance.root_pass != null
      error_message = "Linode image deployments require authorized_keys, authorized_users, or root_pass."
    }
    precondition {
      condition = alltrue([
        for _, app in module.runtime.compose_projects : trimspace(app.docker_compose_repo) != ""
      ])
      error_message = "Each compose project must define docker_compose_repo."
    }
    precondition {
      condition = alltrue([
        for _, app in module.runtime.compose_projects :
        !(contains(["https-letsencrypt", "letsencrypt", "le"], app.ingress.mode) || app.ingress.letsencrypt) ||
        trimspace(app.ingress.domain) != "" && trimspace(app.ingress.acme_email) != ""
      ])
      error_message = "Let's Encrypt ingress requires ingress.domain and ingress.acme_email for each enabled compose project."
    }
    precondition {
      condition     = length(base64gzip(module.runtime.cloud_init)) <= 16384
      error_message = "Linode metadata.user_data is limited to 16 KiB after gzip and base64 encoding. Use a verified runtime.rootfs_archive_url for the managed rootfs and reduce unusually large SSH or runtime inputs."
    }
    precondition {
      condition     = !local.vault.agent_enabled || trimspace(local.vault.addr) != ""
      error_message = "vault_addr is required when vault_agent_enabled is true."
    }
    precondition {
      condition     = !local.vault.agent_enabled || local.vault.auth_method != "consumer-managed" || trimspace(local.vault.agent_additional_config) != ""
      error_message = "vault_agent_additional_config is required when vault_agent_enabled uses consumer-managed auth."
    }
    precondition {
      condition     = !local.managed.internal_services_enabled
      error_message = "Linode does not support the GCP-specific privileged internal-services stack. Leave runtime.managed_runtime.internal_services_enabled false."
    }
  }
}

resource "linode_volume" "data" {
  label     = local.data_volume_label
  region    = local.linode.region
  size      = local.linode.volumes.data_size_gb
  linode_id = linode_instance.cloud_compose.id
  tags      = local.linode.tags
}

resource "linode_volume" "docker_volumes" {
  label     = local.docker_volumes_volume_label
  region    = local.linode.region
  size      = local.linode.volumes.docker_volumes_size_gb
  linode_id = linode_instance.cloud_compose.id
  tags      = local.linode.tags
}

resource "linode_firewall" "cloud_compose" {
  count = local.linode.firewall.enabled ? 1 : 0
  label = local.firewall_label

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = local.linode.firewall.ssh_source_ipv4
    ipv6     = local.linode.firewall.ssh_source_ipv6
  }

  dynamic "inbound" {
    for_each = toset(local.ingress_ports)
    content {
      label    = "app-${inbound.value}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.value
      ipv4     = local.linode.firewall.web_source_ipv4
      ipv6     = local.linode.firewall.web_source_ipv6
    }
  }


  dynamic "inbound" {
    for_each = local.linode.rollout.enabled ? [local.linode.rollout] : []
    content {
      label    = "rollout"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = tostring(inbound.value.port)
      ipv4     = inbound.value.source_ipv4
      ipv6     = inbound.value.source_ipv6
    }
  }

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  linodes         = [linode_instance.cloud_compose.id]
  tags            = local.linode.tags
}
