terraform {
  required_version = ">= 1.2.4"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
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

provider "digitalocean" {}

provider "google" {
  project = local.project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

provider "linode" {}

data "google_project" "current" {
  count      = local.cloud_provider == "gcp" ? 1 : 0
  project_id = local.project_id
}

resource "random_id" "suffix" {
  byte_length = local.cloud_provider == "gcp" ? 2 : 3
}

locals {
  cloud_provider = lower(trimspace(var.cloud_provider))
  template       = lower(trimspace(var.template))
  target         = "${local.cloud_provider}-${local.template}"
  project_id     = trimspace(var.gcp_project_id)

  provider_prefixes = {
    digitalocean = "do"
    gcp          = "g"
    linode       = "ln"
  }
  template_slugs = {
    archivesspace   = "as"
    ojs             = "ojs"
    isle            = "isle"
    drupal          = "dr"
    wp              = "wp"
    "omeka-s"       = "os"
    "omeka-classic" = "oc"
  }

  smoke_run_id = substr(replace(lower(var.smoke_run_id), "/[^a-z0-9-]/", "-"), 0, local.cloud_provider == "gcp" ? 8 : 16)
  name_prefix  = "cc-${local.provider_prefixes[local.cloud_provider]}-${local.template_slugs[local.template]}"
  name_limit   = local.cloud_provider == "gcp" ? 21 : 46
  name         = substr(join("-", compact([local.name_prefix, local.smoke_run_id, random_id.suffix.hex])), 0, local.name_limit)
  run_tag      = local.smoke_run_id != "" ? "gha-run-${local.smoke_run_id}" : ""
  tags         = distinct(concat(var.tags, ["cloud-compose-smoke", local.target], local.run_tag != "" ? [local.run_tag] : []))

  ssh_keys            = distinct(concat([var.ssh_public_key], var.operator_ssh_public_keys))
  healthcheck_timeout = trimspace(var.healthcheck_timeout) != "" ? var.healthcheck_timeout : contains(["isle"], local.template) ? "30m" : "20m"

  runtime = {
    rootfs_archive_url = local.cloud_provider == "linode" ? "https://github.com/libops/cloud-compose/archive/${var.cloud_compose_source_ref}.tar.gz" : ""
    users              = local.cloud_provider == "gcp" ? { cloud-compose = local.ssh_keys } : {}
    compose = {
      branch       = var.docker_compose_branch
      ingress_port = var.ingress_port
      up = [
        "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" up -d --remove-orphans",
        "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\""
      ]
    }
    sitectl = {
      environment          = "smoke"
      healthcheck_timeout  = local.healthcheck_timeout
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

module "app" {
  source = "../../../examples/app"

  name           = local.name
  cloud_provider = local.cloud_provider
  template       = local.template
  gcp = {
    project_id     = local.project_id
    project_number = local.cloud_provider == "gcp" ? data.google_project.current[0].number : ""
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
  digitalocean = {
    region = var.digitalocean_region
    tags   = local.tags
    droplet = {
      size       = var.digitalocean_size
      image      = var.digitalocean_image
      monitoring = true
      ipv6       = true
      backups    = false
    }
    ssh = {
      cloud_compose_keys = local.ssh_keys
    }
    volumes = {
      data_size_gb           = var.data_volume_size_gb
      docker_volumes_size_gb = var.docker_volumes_volume_size_gb
    }
  }
  linode = {
    region = var.linode_region
    tags   = local.tags
    instance = {
      type            = var.linode_type
      image           = var.linode_image
      authorized_keys = local.ssh_keys
    }
    ssh = {
      cloud_compose_keys = local.ssh_keys
    }
    volumes = {
      data_size_gb           = var.data_volume_size_gb
      docker_volumes_size_gb = var.docker_volumes_volume_size_gb
    }
  }
  runtime = local.runtime
}

output "smoke" {
  description = "Remote sitectl context details for the smoke test runner."
  value = {
    provider             = local.cloud_provider
    app                  = local.template
    host                 = module.app.external_ip
    ssh_user             = "cloud-compose"
    ssh_port             = 22
    context_name         = module.app.primary_compose_project.sitectl_context_name
    plugin               = module.app.primary_compose_project.sitectl_plugin
    environment          = module.app.primary_compose_project.sitectl_environment
    site                 = local.name
    project_name         = local.name
    project_dir          = module.app.primary_compose_project.project_dir
    compose_project_name = module.app.primary_compose_project.compose_project_name
    healthcheck_timeout  = local.healthcheck_timeout
    healthcheck_interval = var.healthcheck_interval
  }
}
