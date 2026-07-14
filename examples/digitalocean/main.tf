terraform {
  required_version = ">= 1.3.0"
}

module "wp" {
  source = "../../providers/do"

  name     = var.name
  template = "wp"
  digitalocean = {
    region = var.region
    droplet = {
      size     = var.size
      ssh_keys = var.ssh_keys
    }
    ssh = {
      cloud_compose_keys = var.cloud_compose_ssh_keys
    }
  }
  runtime = {
    rootfs_archive_url    = "https://github.com/libops/cloud-compose/releases/download/${var.cloud_compose_source_ref}/cloud-compose-rootfs.tar.gz"
    rootfs_archive_sha256 = var.cloud_compose_source_sha256
    compose = {
      repo         = var.docker_compose_repo
      branch       = var.docker_compose_branch
      ingress_port = var.ingress_port
    }
  }
}

output "instance" {
  value = module.wp.instance
}

output "volumes" {
  value = module.wp.volumes
}
