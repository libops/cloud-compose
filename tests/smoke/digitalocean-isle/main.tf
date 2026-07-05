terraform {
  required_version = ">= 1.2.4"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "digitalocean" {}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  smoke_run_id = substr(replace(lower(var.smoke_run_id), "/[^a-z0-9-]/", "-"), 0, 16)
  name         = substr(join("-", compact([var.name_prefix, local.smoke_run_id, random_id.suffix.hex])), 0, 46)
  tags         = distinct(concat(var.tags, ["cloud-compose-smoke", "digitalocean-isle"], local.smoke_run_id != "" ? ["gha-run-${local.smoke_run_id}"] : []))
}

module "isle" {
  source = "../../../modules/digitalocean"

  name = local.name
  digitalocean = {
    region = var.region
    tags   = local.tags
    droplet = {
      size       = var.size
      image      = var.image
      monitoring = true
      ipv6       = true
      backups    = false
    }
    ssh = {
      cloud_compose_keys = distinct(concat([var.ssh_public_key], var.operator_ssh_public_keys))
    }
    volumes = {
      data_size_gb           = var.data_volume_size_gb
      docker_volumes_size_gb = var.docker_volumes_volume_size_gb
    }
  }
  runtime = {
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
      packages             = ["sitectl", "sitectl-drupal", "sitectl-isle"]
      plugin               = "isle"
      environment          = "smoke"
      healthcheck_timeout  = var.healthcheck_timeout
      healthcheck_interval = var.healthcheck_interval
    }
  }
}

output "smoke" {
  description = "Remote sitectl context details for the smoke test runner."
  value = {
    provider             = "digitalocean"
    app                  = "isle"
    host                 = module.isle.instance.ipv4
    ssh_user             = "cloud-compose"
    ssh_port             = 22
    context_name         = module.isle.primary_compose_project.sitectl_context_name
    plugin               = module.isle.primary_compose_project.sitectl_plugin
    environment          = module.isle.primary_compose_project.sitectl_environment
    site                 = local.name
    project_name         = local.name
    project_dir          = module.isle.primary_compose_project.project_dir
    compose_project_name = module.isle.primary_compose_project.compose_project_name
    healthcheck_timeout  = var.healthcheck_timeout
    healthcheck_interval = var.healthcheck_interval
  }
}
