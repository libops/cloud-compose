terraform {
  required_version = ">= 1.2.4"
}

locals {
  cloud_provider = lower(trimspace(var.cloud_provider))
  template_name  = lower(trimspace(var.template))

  app_registry   = jsondecode(file("${path.module}/templates/apps.json"))
  app_templates  = local.app_registry.templates
  empty_template = local.app_registry.default
  template       = local.template_name == "" ? local.empty_template : try(local.app_templates[local.template_name], local.empty_template)

  input_compose = var.runtime.compose
  input_sitectl = var.runtime.sitectl

  runtime = merge(var.runtime, {
    compose = merge(local.input_compose, {
      repo = (
        trimspace(local.input_compose.repo) != ""
        ? local.input_compose.repo
        : local.template.repo
      )
      branch = (
        trimspace(local.input_compose.branch) != ""
        ? local.input_compose.branch
        : local.template.branch
      )
    })
    sitectl = merge(local.input_sitectl, {
      packages = (
        local.template_name != "" && length(local.input_sitectl.packages) == 1 && local.input_sitectl.packages[0] == "sitectl"
        ? local.template.packages
        : local.input_sitectl.packages
      )
      plugin = (
        local.template_name != "" && local.input_sitectl.plugin == "core"
        ? local.template.plugin
        : local.input_sitectl.plugin
      )
    })
  })

  compose = local.runtime.compose
  sitectl = local.runtime.sitectl
  docker  = local.runtime.docker
  managed = local.runtime.managed_runtime
  vault   = local.runtime.vault

  gcp_instance          = var.gcp.instance
  gcp_disks             = var.gcp.disks
  gcp_identity          = var.gcp.identity
  gcp_network           = var.gcp.network
  gcp_snapshots         = var.gcp.snapshots
  gcp_overlay           = var.gcp.overlay
  gcp_artifact_registry = var.gcp.artifact_registry
  gcp_cloud_init        = var.gcp.cloud_init
  gcp_power_management  = var.gcp.power_management
  gcp_rollout           = var.gcp.rollout

  linux_runtime = {
    rootfs                = local.runtime.rootfs
    rootfs_archive_url    = local.runtime.rootfs_archive_url
    rootfs_archive_sha256 = local.runtime.rootfs_archive_sha256
    compose               = local.compose
    sitectl               = local.sitectl
    docker                = local.docker
    managed_runtime = {
      enabled                       = local.managed.enabled
      internal_services_enabled     = local.managed.internal_services_enabled
      internal_services_auto_update = local.managed.internal_services_auto_update
      artifacts                     = local.managed.artifacts
    }
    vault = {
      addr                    = local.vault.addr
      namespace               = local.vault.namespace
      role                    = local.vault.role
      agent_enabled           = local.vault.agent_enabled
      auth_method             = local.vault.auth_method
      agent_token_path        = local.vault.agent_token_path
      agent_additional_config = local.vault.agent_additional_config
      agent_templates         = local.vault.agent_templates
    }
    extra_env = local.runtime.extra_env
  }
}

module "gcp" {
  count  = local.cloud_provider == "gcp" ? 1 : 0
  source = "./modules/gcp"

  name           = var.name
  project_id     = var.gcp.project_id
  project_number = var.gcp.project_number
  region         = var.gcp.region
  zone           = var.gcp.zone

  service_account_email     = local.gcp_identity.vm_service_account_email
  app_service_account_email = local.gcp_identity.app_service_account_email

  machine_type = local.gcp_instance.machine_type
  os           = local.gcp_instance.os
  production   = local.gcp_instance.production

  disk_type    = local.gcp_disks.type
  disk_size_gb = local.gcp_disks.docker_volumes_size_gb

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

  sitectl_packages             = local.sitectl.packages
  sitectl_version              = local.sitectl.version
  sitectl_context_name         = local.sitectl.context_name
  sitectl_plugin               = local.sitectl.plugin
  sitectl_environment          = local.sitectl.environment
  sitectl_healthcheck_timeout  = local.sitectl.healthcheck_timeout
  sitectl_healthcheck_interval = local.sitectl.healthcheck_interval
  sitectl_verify_args          = local.sitectl.verify_args

  docker_compose_version = local.docker.compose_version
  docker_buildx_version  = local.docker.buildx_version

  libops_managed_runtime_enabled       = local.managed.enabled
  libops_internal_services_enabled     = local.managed.internal_services_enabled
  libops_internal_services_auto_update = local.managed.internal_services_auto_update
  libops_lightsout_image               = local.managed.lightsout_image
  libops_cap_image                     = local.managed.cap_image
  libops_cadvisor_image                = local.managed.cadvisor_image
  libops_managed_artifacts             = local.managed.artifacts

  allowed_ips      = local.gcp_network.power_button_allowed_ips
  allowed_ssh_ipv4 = local.gcp_network.ssh_ipv4
  allowed_ssh_ipv6 = local.gcp_network.ssh_ipv6

  create_network        = local.gcp_network.create
  network_name          = local.gcp_network.name
  subnetwork_name       = local.gcp_network.subnetwork
  network_ip_cidr_range = local.gcp_network.ip_cidr_range

  run_snapshots           = local.gcp_snapshots.enabled
  overlay_source_instance = local.gcp_overlay.source_instance
  volume_names            = local.gcp_overlay.volume_names

  users   = local.runtime.users
  rootfs  = local.runtime.rootfs
  runcmd  = local.gcp_cloud_init.runcmd
  initcmd = local.gcp_cloud_init.initcmd

  artifact_registry_repository = local.gcp_artifact_registry.repository
  artifact_registry_location   = local.gcp_artifact_registry.location

  power_management_enabled = local.gcp_power_management.enabled
  frontend                 = local.gcp_power_management.frontend

  rollout_enabled        = local.gcp_rollout.enabled
  rollout_release_url    = local.gcp_rollout.release_url
  rollout_release_sha256 = local.gcp_rollout.release_sha256
  rollout_port           = local.gcp_rollout.port
  rollout_jwks_uri       = local.gcp_rollout.jwks_uri
  rollout_jwt_audience   = local.gcp_rollout.jwt_audience
  rollout_custom_claims  = local.gcp_rollout.custom_claims
  rollout_allowed_ipv4   = local.gcp_rollout.allowed_ipv4

  vault_addr                    = local.vault.addr
  vault_namespace               = local.vault.namespace
  vault_role                    = local.vault.role
  vault_agent_enabled           = local.vault.agent_enabled
  vault_auth_method             = local.vault.auth_method
  vault_gcp_auth_mount_path     = local.vault.gcp_auth_mount_path
  vault_agent_token_path        = local.vault.agent_token_path
  vault_agent_templates         = local.vault.agent_templates
  vault_agent_additional_config = local.vault.agent_additional_config
}

module "digitalocean" {
  count  = local.cloud_provider == "digitalocean" ? 1 : 0
  source = "./modules/digitalocean"

  name         = var.name
  digitalocean = var.digitalocean
  runtime      = local.linux_runtime
}

module "linode" {
  count  = local.cloud_provider == "linode" ? 1 : 0
  source = "./modules/linode"

  name    = var.name
  linode  = var.linode
  runtime = local.linux_runtime
}
