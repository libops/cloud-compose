terraform {
  required_version = ">= 1.2.4"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = local.project_id != "" ? local.project_id : "unused"
  region  = var.gcp_region
  zone    = var.gcp_zone
}

data "google_project" "current" {
  project_id = local.project_id
}

locals {
  project_id = trimspace(var.gcp_project_id)
}

module "context" {
  source = "../modules/context"

  cloud_provider           = "gcp"
  template                 = var.template
  ssh_public_key           = var.ssh_public_key
  operator_ssh_public_keys = var.operator_ssh_public_keys
  smoke_run_id             = var.smoke_run_id
  docker_compose_branch    = var.docker_compose_branch
  ingress_port             = var.ingress_port
  healthcheck_timeout      = var.healthcheck_timeout
  healthcheck_interval     = var.healthcheck_interval
}

module "app" {
  source = "../../../providers/gcp"

  name     = module.context.name
  template = module.context.template
  gcp = {
    project_id     = local.project_id
    project_number = data.google_project.current.number
    region         = var.gcp_region
    zone           = var.gcp_zone
    instance = {
      machine_type = var.gcp_machine_type
      os           = var.gcp_os
      production   = false
    }
    disks = {
      type                   = var.gcp_disk_type
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
  runtime = module.context.gcp_runtime
}

module "smoke" {
  source = "../modules/output"

  cloud_provider          = "gcp"
  template                = module.context.template
  name                    = module.context.name
  host                    = module.app.external_ip
  primary_compose_project = module.app.primary_compose_project
  healthcheck_timeout     = module.context.healthcheck_timeout
  healthcheck_interval    = var.healthcheck_interval
}

output "smoke" {
  value       = module.smoke.smoke
  description = "Remote sitectl context details for the smoke test runner."
}
