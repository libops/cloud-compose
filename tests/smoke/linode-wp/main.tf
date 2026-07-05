terraform {
  required_version = ">= 1.2.4"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "linode" {}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  smoke_run_id = substr(replace(lower(var.smoke_run_id), "/[^a-z0-9-]/", "-"), 0, 16)
  name         = substr(join("-", compact([var.name_prefix, local.smoke_run_id, random_id.suffix.hex])), 0, 46)
  tags         = distinct(concat(var.tags, ["cloud-compose-smoke", "linode-wp"], local.smoke_run_id != "" ? ["gha-run-${local.smoke_run_id}"] : []))
}

module "wp" {
  source = "../../../modules/linode"

  name = local.name
  linode = {
    region = var.region
    tags   = local.tags
    instance = {
      type            = var.type
      image           = var.image
      authorized_keys = distinct(concat([var.ssh_public_key], var.operator_ssh_public_keys))
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
    rootfs_archive_url = "https://github.com/libops/cloud-compose/archive/${var.cloud_compose_source_ref}.tar.gz"
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
  }
}

output "smoke" {
  description = "Remote sitectl context details for the smoke test runner."
  value = {
    provider             = "linode"
    app                  = "wp"
    host                 = module.wp.instance.public_ipv4
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
