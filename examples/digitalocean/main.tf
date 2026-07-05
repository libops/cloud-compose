terraform {
  required_version = ">= 1.2.4"
}

module "wp" {
  source = "../../modules/digitalocean"

  name = var.name
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
    compose = {
      repo         = var.docker_compose_repo
      branch       = var.docker_compose_branch
      ingress_port = var.ingress_port
    }
    sitectl = {
      packages = ["sitectl", "sitectl-wp"]
      plugin   = "wp"
    }
  }
}

output "instance" {
  value = module.wp.instance
}

output "volumes" {
  value = module.wp.volumes
}
