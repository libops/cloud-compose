terraform {
  required_version = ">= 1.3.0"

  required_providers {
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

locals {
  template_name = lower(trimspace(var.template))

  app_registry   = jsondecode(file("${path.module}/../../templates/apps.json"))
  app_templates  = local.app_registry.templates
  empty_template = local.app_registry.default
  template       = local.template_name == "" ? local.empty_template : try(local.app_templates[local.template_name], local.empty_template)

  input_compose = var.runtime.compose
  input_sitectl = var.runtime.sitectl

  sitectl_packages = distinct(concat(
    ["sitectl"],
    local.input_sitectl.packages == null ? local.template.packages : local.input_sitectl.packages,
  ))
  template_sitectl_package_versions = {
    for package in local.sitectl_packages :
    package => local.template.package_versions[package]
    if contains(keys(local.template.package_versions), package)
  }

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
      packages         = local.sitectl_packages
      package_versions = merge(local.template_sitectl_package_versions, local.input_sitectl.package_versions)
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
}

module "gcp" {
  source = "../../modules/gcp"

  name           = var.name
  project_id     = var.gcp.project_id
  project_number = var.gcp.project_number
  region         = var.gcp.region
  zone           = var.gcp.zone

  service_account_email     = local.gcp_identity.vm_service_account_email
  app_service_account_email = local.gcp_identity.app_service_account_email
  app_credentials_enabled   = local.gcp_identity.app_credentials_enabled

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

  sitectl_packages         = local.sitectl.packages
  sitectl_version          = local.sitectl.version
  sitectl_package_versions = local.sitectl.package_versions
  sitectl_context_name     = local.sitectl.context_name
  sitectl_plugin           = local.sitectl.plugin
  sitectl_environment      = local.sitectl.environment
  sitectl_verify_args      = local.sitectl.verify_args

  docker_compose_version = local.docker.compose_version
  docker_buildx_version  = local.docker.buildx_version

  libops_managed_runtime_enabled       = local.managed.enabled
  libops_internal_services_enabled     = local.managed.internal_services_enabled
  libops_internal_services_auto_update = local.managed.internal_services_auto_update
  libops_managed_artifacts             = local.managed.artifacts

  allowed_ips                = local.gcp_network.power_button_allowed_ips
  allowed_ip_forwarded_depth = local.gcp_network.power_button_ip_depth
  allowed_ssh_ipv4           = local.gcp_network.ssh_ipv4
  allowed_ssh_ipv6           = local.gcp_network.ssh_ipv6

  create_network        = local.gcp_network.create
  network_project_id    = local.gcp_network.project_id
  network_name          = local.gcp_network.name
  subnetwork_name       = local.gcp_network.subnetwork
  network_ip_cidr_range = local.gcp_network.ip_cidr_range
  network_mtu           = local.gcp_network.mtu

  run_snapshots           = local.gcp_snapshots.enabled
  overlay_source_instance = local.gcp_overlay.source_instance
  volume_names            = local.gcp_overlay.volume_names

  users                 = local.runtime.users
  rootfs                = local.runtime.rootfs
  rootfs_archive_url    = local.runtime.rootfs_archive_url
  rootfs_archive_sha256 = local.runtime.rootfs_archive_sha256
  extra_env             = local.runtime.extra_env
  runcmd                = local.gcp_cloud_init.runcmd
  initcmd               = local.gcp_cloud_init.initcmd

  artifact_registry_repository = local.gcp_artifact_registry.repository
  artifact_registry_location   = local.gcp_artifact_registry.location

  power_management_enabled = local.gcp_power_management.enabled
  power_start_role         = local.gcp_power_management.start_role
  power_suspend_role       = local.gcp_power_management.suspend_role
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
