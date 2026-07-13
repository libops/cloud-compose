terraform {
  required_version = ">= 1.3.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = local.cloud_provider == "gcp" ? 2 : 3

  lifecycle {
    precondition {
      condition = local.smoke_run_namespace == "" || try(
        tostring(parseint(var.smoke_run_id, 10)) == var.smoke_run_id &&
        parseint(var.smoke_run_id, 10) <= 17592186044415 &&
        parseint(local.smoke_run_namespace, 36) == parseint(var.smoke_run_id, 10),
        false
      )
      error_message = "smoke_run_namespace must be the cloud-compose-ci encoding of the canonical, at-most-44-bit smoke_run_id."
    }
  }
}

locals {
  cloud_provider = lower(trimspace(var.cloud_provider))
  template       = lower(trimspace(var.template))

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

  smoke_run_id        = substr(replace(lower(var.smoke_run_id), "/[^a-z0-9-]/", "-"), 0, local.cloud_provider == "gcp" ? 8 : 16)
  smoke_run_namespace = local.cloud_provider == "gcp" ? var.smoke_run_namespace : ""
  name_run_namespace  = local.smoke_run_namespace != "" ? local.smoke_run_namespace : local.smoke_run_id
  name_limit          = local.cloud_provider == "gcp" ? 21 : 46
  target              = "${local.cloud_provider}-${local.template}"
  name_prefix         = "cc-${local.provider_prefixes[local.cloud_provider]}-${local.template_slugs[local.template]}"
  name                = substr(join("-", compact([local.name_prefix, local.name_run_namespace, random_id.suffix.hex])), 0, local.name_limit)
  run_tag             = local.smoke_run_id != "" ? "gha-run-${local.smoke_run_id}" : ""
  tags                = distinct(concat(var.tags, ["cloud-compose-smoke", local.target], local.run_tag != "" ? [local.run_tag] : []))
  ssh_keys            = distinct(concat([var.ssh_public_key], var.operator_ssh_public_keys))
  runtime_base = {
    rootfs_archive_url    = var.rootfs_archive_url
    rootfs_archive_sha256 = var.rootfs_archive_sha256
    compose = {
      branch       = var.docker_compose_branch
      ingress_port = var.ingress_port
      up = [
        "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" up -d --remove-orphans",
        "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist"
      ]
    }
    sitectl = {
      environment = "smoke"
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

  gcp_runtime = merge(local.runtime_base, {
    users = {
      cloud-compose = local.ssh_keys
    }
  })
}
