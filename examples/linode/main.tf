terraform {
  required_version = ">= 1.3.0"
}

module "drupal" {
  source = "../../providers/linode"

  name     = var.name
  template = "drupal"
  linode = {
    region = var.region
    instance = {
      type             = var.type
      authorized_keys  = var.authorized_keys
      authorized_users = var.authorized_users
      root_pass        = var.root_pass
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
  }
}

output "instance" {
  value = module.drupal.instance
}

output "volumes" {
  value = module.drupal.volumes
}
