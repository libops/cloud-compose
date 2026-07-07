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
  method       = lower(trimspace(var.method))
  template     = lower(trimspace(var.template))
  smoke_run_id = substr(replace(lower(var.smoke_run_id), "/[^a-z0-9-]/", "-"), 0, 16)
  run_tag      = local.smoke_run_id != "" ? "gha-run-${local.smoke_run_id}" : ""
  name         = substr(join("-", compact(["cc-cm-ln", local.method, "dr", local.smoke_run_id, random_id.suffix.hex])), 0, 46)

  data_volume_label           = substr("${local.name}-data", 0, 32)
  docker_volumes_volume_label = substr("${local.name}-dock", 0, 32)
  firewall_label              = substr("${local.name}-fw", 0, 32)
  target_tag                  = "config-management-${local.method}-${local.template}"
  tags                        = distinct(concat(var.tags, ["cloud-compose-smoke", "config-management-smoke", local.target_tag], local.run_tag != "" ? [local.run_tag] : []))

  cloud_init = templatefile("${path.module}/templates/cloud-init.yml", {
    DATA_DEVICE     = "/dev/disk/by-id/scsi-0Linode_Volume_${local.data_volume_label}"
    VOLUMES_DEVICE  = "/dev/disk/by-id/scsi-0Linode_Volume_${local.docker_volumes_volume_label}"
    SSH_PUBLIC_KEYS = distinct(concat([var.ssh_public_key], var.operator_ssh_public_keys))
  })
}

resource "linode_instance" "host" {
  label            = local.name
  region           = var.linode_region
  type             = var.linode_type
  image            = var.linode_image
  authorized_keys  = distinct(concat([var.ssh_public_key], var.operator_ssh_public_keys))
  private_ip       = true
  backups_enabled  = false
  watchdog_enabled = true
  tags             = local.tags

  metadata {
    user_data = base64gzip(local.cloud_init)
  }
}

resource "linode_volume" "data" {
  label     = local.data_volume_label
  region    = var.linode_region
  size      = var.data_volume_size_gb
  linode_id = linode_instance.host.id
  tags      = local.tags
}

resource "linode_volume" "docker_volumes" {
  label     = local.docker_volumes_volume_label
  region    = var.linode_region
  size      = var.docker_volumes_volume_size_gb
  linode_id = linode_instance.host.id
  tags      = local.tags
}

resource "linode_firewall" "host" {
  label = local.firewall_label

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.ssh_source_ipv4
    ipv6     = var.ssh_source_ipv6
  }

  inbound {
    label    = "http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = var.web_source_ipv4
    ipv6     = var.web_source_ipv6
  }

  inbound {
    label    = "https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = var.web_source_ipv4
    ipv6     = var.web_source_ipv6
  }

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  linodes         = [linode_instance.host.id]
  tags            = local.tags
}

output "smoke" {
  value = {
    provider             = "linode"
    method               = local.method
    app                  = local.template
    name                 = local.name
    host                 = one(setsubtract(linode_instance.host.ipv4, [linode_instance.host.private_ip_address]))
    ssh_user             = "root"
    ssh_port             = 22
    cloud_compose_name   = "${local.method}-${local.template}"
    context_name         = "${local.method}-${local.template}"
    plugin               = local.template
    environment          = "smoke"
    project_dir          = "/mnt/disks/data/libops/${local.template}.git/main"
    compose_project_name = "libops-${local.template}-main"
    healthcheck_timeout  = var.healthcheck_timeout
    healthcheck_interval = var.healthcheck_interval
    target_tag           = local.target_tag
  }
  description = "Raw Linode host and app details for config-management smoke tests."
}
