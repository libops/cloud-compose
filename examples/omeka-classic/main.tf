terraform {
  required_version = ">= 1.2.4"
}

module "omeka_classic" {
  source = "../app"

  name           = var.name
  cloud_provider = var.cloud_provider
  template       = "omeka-classic"
  gcp            = var.gcp
  digitalocean   = var.digitalocean
  linode         = var.linode
  runtime        = var.runtime
}

output "instance" {
  value = module.omeka_classic.instance
}

output "external_ip" {
  value = module.omeka_classic.external_ip
}

output "primary_compose_project" {
  value = module.omeka_classic.primary_compose_project
}
