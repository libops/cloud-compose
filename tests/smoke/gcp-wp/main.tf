terraform {
  required_version = ">= 1.2.4"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "google" {
  project = local.project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

data "google_project" "current" {
  project_id = local.project_id
}

resource "random_id" "suffix" {
  byte_length = 2
}

locals {
  project_id   = trimspace(var.gcp_project_id)
  smoke_run_id = substr(replace(lower(var.smoke_run_id), "/[^a-z0-9-]/", "-"), 0, 8)
  name         = substr(join("-", compact([var.name_prefix, local.smoke_run_id, random_id.suffix.hex])), 0, 21)
}

module "wp" {
  source = "../../.."

  name = local.name
  gcp = {
    project_id     = local.project_id
    project_number = data.google_project.current.number
    region         = var.gcp_region
    zone           = var.gcp_zone
    instance = {
      machine_type = var.machine_type
      os           = var.os
      production   = false
    }
    disks = {
      type                   = var.disk_type
      docker_volumes_size_gb = var.docker_volumes_volume_size_gb
    }
    snapshots = {
      enabled = false
    }
    network = {
      ssh_ipv4 = var.ssh_source_ranges
      ssh_ipv6 = []
    }
    power_management = {
      enabled = false
    }
  }
  runtime = {
    users = {
      cloud-compose = distinct(concat([var.ssh_public_key], var.operator_ssh_public_keys))
    }
    compose = {
      repo         = var.docker_compose_repo
      branch       = var.docker_compose_branch
      ingress_port = var.ingress_port
      up = [
        "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" up -d --remove-orphans",
        "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\""
      ]
    }
    sitectl = {
      packages             = ["sitectl", "sitectl-wp"]
      plugin               = "wp"
      environment          = "smoke"
      healthcheck_timeout  = var.healthcheck_timeout
      healthcheck_interval = var.healthcheck_interval
    }
    managed_runtime = {
      enabled                       = true
      internal_services_enabled     = false
      internal_services_auto_update = false
    }
    vault = {
      auth_method = "consumer-managed"
    }
  }
}

output "smoke" {
  description = "Remote sitectl context details for the smoke test runner."
  value = {
    provider             = "gcp"
    app                  = "wp"
    host                 = module.wp.external_ip
    ssh_user             = "cloud-compose"
    ssh_port             = 22
    context_name         = module.wp.primary_compose_project.sitectl_context_name
    plugin               = module.wp.primary_compose_project.sitectl_plugin
    environment          = module.wp.primary_compose_project.sitectl_environment
    site                 = local.name
    project_name         = local.name
    project_dir          = module.wp.primary_compose_project.project_dir
    compose_project_name = module.wp.primary_compose_project.compose_project_name
    healthcheck_timeout  = var.healthcheck_timeout
    healthcheck_interval = var.healthcheck_interval
  }
}
