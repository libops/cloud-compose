terraform {
  required_version = ">= 1.3.0"

  backend "local" {}

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

  lifecycle {
    precondition {
      condition     = trimspace(var.gcp_network_project_id) == local.project_id
      error_message = "gcp_network_project_id must equal gcp_project_id because the 0.10.2 baseline does not support Shared VPC."
    }
  }
}

locals {
  project_id               = trimspace(var.gcp_project_id)
  wordpress_project_dir    = "/mnt/disks/data/libops/wp.git/${var.wordpress_compose_ref}"
  application_data_size_gb = var.legacy_baseline ? 20 : 30
}

module "app" {
  # Exercise the GCP-only compatibility root across the real pre-1.0 state
  # boundary. New deployments should use ../../../providers/gcp instead.
  source = "../../.."

  name     = var.name
  template = "wp"
  gcp = {
    project_id     = local.project_id
    project_number = data.google_project.current.number
    region         = var.gcp_region
    zone           = var.gcp_zone
    identity = {
      # Preserve the pre-1.0 app JSON-key behavior through the state upgrade.
      # Keyless migration is a separate, explicit credential-retirement step.
      app_credentials_enabled = true
    }
    instance = {
      machine_type = "e2-medium"
      os           = "cos-125-19216-220-185"
      production   = false
    }
    disks = {
      type                   = "pd-standard"
      data_size_gb           = local.application_data_size_gb
      docker_volumes_size_gb = 30
    }
    snapshots = {
      enabled = false
    }
    network = {
      create                   = false
      project_id               = var.gcp_network_project_id
      name                     = var.gcp_network_name
      subnetwork               = var.gcp_subnetwork_name
      power_button_allowed_ips = [var.runner_ipv4_cidr]
      power_button_ip_depth    = 0
      ssh_ipv4                 = [var.runner_ipv4_cidr]
      ssh_ipv6                 = []
    }
    cloud_init = {
      # These commands run after write_files but before run.sh. The legacy
      # timer can suspend the disposable host during a long bootstrap, so
      # disabling it in the later runcmd phase is too late.
      initcmd = [
        "bash /home/cloud-compose/gcp-upgrade-prepare-repository.sh",
      ]
    }
    power_management = {
      enabled      = true
      start_role   = var.gcp_power_start_role
      suspend_role = var.gcp_power_suspend_role
    }
  }
  runtime = {
    rootfs = "${path.module}/rootfs"
    users = {
      cloud-compose = [var.ssh_public_key]
    }
    compose = {
      # The pinned 0.10.2 baseline had a Terraform type error when a non-empty
      # compose_projects map was combined with its dynamically keyed legacy
      # fallback. Exercise that release through its supported single-project
      # inputs, then move to the current explicit project map during upgrade.
      primary      = var.legacy_baseline ? "" : "wordpress"
      ingress_port = 80
      repo         = "https://github.com/libops/wp.git"
      branch       = var.wordpress_compose_ref
      projects = var.legacy_baseline ? {} : {
        wordpress = {
          docker_compose_repo   = "https://github.com/libops/wp.git"
          docker_compose_branch = var.wordpress_compose_ref
          project_dir           = local.wordpress_project_dir
          ingress_port          = 80
        }
      }
      up = [
        "/etc/cloud-compose/lifecycle.d/gcp-upgrade-up.sh",
      ]
    }
    sitectl = {
      environment = "smoke"
    }
    managed_runtime = {
      enabled                       = true
      internal_services_enabled     = true
      internal_services_auto_update = true
    }
    vault = {
      auth_method = "consumer-managed"
    }
  }
}

locals {
  primary_compose_project = module.app.primary_compose_project
}

output "smoke" {
  value = {
    provider             = "gcp"
    app                  = "wp"
    host                 = module.app.external_ip
    ssh_user             = "cloud-compose"
    ssh_port             = 22
    context_name         = local.primary_compose_project.sitectl_context_name
    plugin               = local.primary_compose_project.sitectl_plugin
    environment          = local.primary_compose_project.sitectl_environment
    site                 = var.name
    project_name         = var.name
    project_dir          = local.primary_compose_project.project_dir
    compose_project_name = local.primary_compose_project.compose_project_name
    ingress_url          = try(module.app.urls[var.gcp_region], "")
  }
  description = "Remote sitectl context details for both phases of the GCP upgrade smoke test."
}
