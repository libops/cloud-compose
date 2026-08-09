locals {
  do                         = var.digitalocean
  runtime                    = var.runtime
  compose                    = var.runtime.compose
  sitectl                    = var.runtime.sitectl
  docker                     = var.runtime.docker
  managed                    = var.runtime.managed_runtime
  vault                      = var.runtime.vault
  data_volume_name           = "${var.name}-data"
  docker_volumes_volume_name = "${var.name}-docker-volumes"
}

module "runtime" {
  source = "../linux-vm-runtime"

  name                              = var.name
  provider_name                     = "digitalocean"
  region                            = local.do.region
  data_device                       = "/dev/disk/by-id/scsi-0DO_Volume_${local.data_volume_name}"
  volumes_device                    = "/dev/disk/by-id/scsi-0DO_Volume_${local.docker_volumes_volume_name}"
  ssh_users                         = merge(local.runtime.users, local.do.ssh.users)
  cloud_compose_ssh_keys            = local.do.ssh.cloud_compose_keys
  rootfs                            = local.runtime.rootfs
  rootfs_archive_url                = local.runtime.rootfs_archive_url
  rootfs_archive_sha256             = local.runtime.rootfs_archive_sha256
  rootfs_test_source_archive_prefix = local.runtime.rootfs_test_source_archive_prefix
  offhost_backup_required           = local.runtime.disaster_recovery.required
  offhost_backup_driver_path        = local.runtime.disaster_recovery.driver_path
  ingress_port                      = local.compose.ingress_port
  primary_compose_project           = local.compose.primary
  sitectl_ingress                   = local.compose.ingress
  docker_compose_repo               = local.compose.repo
  docker_compose_branch             = local.compose.branch
  compose_projects                  = local.compose.projects
  docker_compose_init               = local.compose.init
  docker_compose_up                 = local.compose.up
  docker_compose_down               = local.compose.down
  docker_compose_rollout            = local.compose.rollout
  rollout_enabled                   = local.do.rollout.enabled
  rollout_release_url               = local.do.rollout.release_url
  rollout_release_sha256            = local.do.rollout.release_sha256
  rollout_port                      = local.do.rollout.port
  rollout_jwks_uri                  = local.do.rollout.jwks_uri
  rollout_jwt_audience              = local.do.rollout.jwt_audience
  rollout_custom_claims             = local.do.rollout.custom_claims

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

resource "digitalocean_volume" "data" {
  region      = local.do.region
  name        = local.data_volume_name
  size        = local.do.volumes.data_size_gb
  description = "cloud-compose persistent data for ${var.name}"
  tags        = local.do.tags

  lifecycle {
    # Older cloud-compose releases asked DigitalOcean to format and automount
    # this volume. Ignore that creation-only state when upgrading so removing
    # the request never replaces a durable volume. New volumes stay raw until
    # the verified host bootstrap formats and mounts them exactly once.
    ignore_changes = [initial_filesystem_type]
  }
}

resource "digitalocean_volume" "docker_volumes" {
  region      = local.do.region
  name        = local.docker_volumes_volume_name
  size        = local.do.volumes.docker_volumes_size_gb
  description = "cloud-compose Docker volumes for ${var.name}"
  tags        = local.do.tags

  lifecycle {
    # See the data-volume lifecycle above. Existing volume identity and data
    # must survive the transition away from provider-side initial formatting.
    ignore_changes = [initial_filesystem_type]
  }
}

resource "digitalocean_droplet" "cloud_compose" {
  name              = var.name
  region            = local.do.region
  size              = local.do.droplet.size
  image             = local.do.droplet.image
  ssh_keys          = local.do.droplet.ssh_keys
  tags              = local.do.tags
  vpc_uuid          = local.do.droplet.vpc_uuid
  monitoring        = local.do.droplet.monitoring
  ipv6              = local.do.droplet.ipv6
  backups           = local.do.droplet.backups
  graceful_shutdown = true
  user_data         = module.runtime.cloud_init

  lifecycle {
    precondition {
      # DigitalOcean accepts at most 64 KiB of raw user_data. Bounding the
      # base64 representation at 87,380 characters conservatively caps the
      # UTF-8 payload at 65,535 bytes without treating Unicode code points as
      # bytes. Archive mode keeps the bootstrap comfortably below this limit.
      condition     = length(base64encode(module.runtime.cloud_init)) <= 87380
      error_message = "DigitalOcean Droplet user_data is limited to 64 KiB. Set runtime.rootfs_archive_url and runtime.rootfs_archive_sha256 so the verified cloud-compose rootfs is fetched during boot instead of embedded in cloud-init."
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
      condition     = !local.vault.agent_enabled || trimspace(local.vault.addr) != ""
      error_message = "vault_addr is required when vault_agent_enabled is true."
    }
    precondition {
      condition     = !local.vault.agent_enabled || local.vault.auth_method != "consumer-managed" || trimspace(local.vault.agent_additional_config) != ""
      error_message = "vault_agent_additional_config is required when vault_agent_enabled uses consumer-managed auth."
    }
    precondition {
      condition     = !local.managed.internal_services_enabled
      error_message = "DigitalOcean does not support the GCP-specific privileged internal-services stack. Leave runtime.managed_runtime.internal_services_enabled false."
    }
  }
}

resource "digitalocean_volume_attachment" "data" {
  droplet_id = digitalocean_droplet.cloud_compose.id
  volume_id  = digitalocean_volume.data.id
}

resource "digitalocean_volume_attachment" "docker_volumes" {
  droplet_id = digitalocean_droplet.cloud_compose.id
  volume_id  = digitalocean_volume.docker_volumes.id
}

resource "digitalocean_firewall" "cloud_compose" {
  count = local.do.firewall.enabled ? 1 : 0
  name  = "${var.name}-cloud-compose"

  droplet_ids = [digitalocean_droplet.cloud_compose.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = local.do.firewall.ssh_source_addresses
  }

  dynamic "inbound_rule" {
    for_each = toset(local.ingress_ports)
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.value
      source_addresses = local.do.firewall.web_source_addresses
    }
  }

  dynamic "inbound_rule" {
    for_each = local.do.rollout.enabled ? [local.do.rollout] : []
    content {
      protocol         = "tcp"
      port_range       = tostring(inbound_rule.value.port)
      source_addresses = inbound_rule.value.source_addresses
    }
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
