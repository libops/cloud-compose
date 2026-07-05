terraform {
  required_version = ">= 1.2.4"
}

module "archivesspace" {
  source = "../app"

  name           = var.name
  cloud_provider = var.cloud_provider
  template       = "archivesspace"
  gcp            = var.gcp
  digitalocean   = var.digitalocean
  linode         = var.linode
  runtime        = var.runtime
}

output "instance" {
  value = module.archivesspace.instance
}

output "external_ip" {
  value = module.archivesspace.external_ip
}

output "primary_compose_project" {
  value = module.archivesspace.primary_compose_project
}
