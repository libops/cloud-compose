terraform {
  required_version = ">= 1.3.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
  }
}

provider "linode" {}

module "context" {
  source = "../modules/context"

  cloud_provider           = "linode"
  template                 = var.template
  ssh_public_key           = var.ssh_public_key
  operator_ssh_public_keys = var.operator_ssh_public_keys
  smoke_run_id             = var.smoke_run_id
  docker_compose_branch    = var.docker_compose_branch
  ingress_port             = var.ingress_port
  rootfs_archive_url       = "https://github.com/libops/cloud-compose/archive/${var.cloud_compose_source_ref}.tar.gz"
  rootfs_archive_sha256    = var.cloud_compose_source_sha256
  tags                     = var.tags
}

module "app" {
  source = "../../../providers/linode"

  name     = module.context.name
  template = module.context.template
  linode = {
    region = var.linode_region
    tags   = module.context.tags
    instance = {
      type            = var.linode_type
      image           = var.linode_image
      authorized_keys = module.context.ssh_keys
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

  cloud_provider          = "linode"
  template                = module.context.template
  name                    = module.context.name
  host                    = module.app.external_ip
  primary_compose_project = module.app.primary_compose_project
}

output "smoke" {
  value       = module.smoke.smoke
  description = "Remote sitectl context details for the smoke test runner."
}
