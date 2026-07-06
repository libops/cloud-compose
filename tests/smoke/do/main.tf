terraform {
  required_version = ">= 1.2.4"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {}

module "context" {
  source = "../modules/context"

  cloud_provider           = "digitalocean"
  template                 = var.template
  ssh_public_key           = var.ssh_public_key
  operator_ssh_public_keys = var.operator_ssh_public_keys
  smoke_run_id             = var.smoke_run_id
  docker_compose_branch    = var.docker_compose_branch
  ingress_port             = var.ingress_port
  healthcheck_timeout      = var.healthcheck_timeout
  healthcheck_interval     = var.healthcheck_interval
  tags                     = var.tags
}

module "app" {
  source = "../../../providers/do"

  name     = module.context.name
  template = module.context.template
  digitalocean = {
    region = var.digitalocean_region
    tags   = module.context.tags
    droplet = {
      size       = var.digitalocean_size
      image      = var.digitalocean_image
      monitoring = true
      ipv6       = true
      backups    = false
    }
    ssh = {
      cloud_compose_keys = module.context.ssh_keys
    }
    volumes = {
      data_size_gb           = var.data_volume_size_gb
      docker_volumes_size_gb = var.docker_volumes_volume_size_gb
    }
  }
  runtime = module.context.runtime
}

module "smoke" {
  source = "../modules/output"

  cloud_provider          = "digitalocean"
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
