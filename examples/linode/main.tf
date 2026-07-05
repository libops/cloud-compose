terraform {
  required_version = ">= 1.2.4"
}

module "drupal" {
  source = "../../modules/linode"

  name = var.name
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
    rootfs_archive_url = "https://github.com/libops/cloud-compose/archive/${var.cloud_compose_source_ref}.tar.gz"
    compose = {
      repo         = var.docker_compose_repo
      branch       = var.docker_compose_branch
      ingress_port = var.ingress_port
    }
    sitectl = {
      packages = ["sitectl", "sitectl-drupal"]
      plugin   = "drupal"
    }
  }
}

output "instance" {
  value = module.drupal.instance
}

output "volumes" {
  value = module.drupal.volumes
}
