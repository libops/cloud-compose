terraform {
  required_version = ">= 1.2.4"
}

module "omeka_s" {
  source = "../app"

  name           = var.name
  cloud_provider = var.cloud_provider
  template       = "omeka-s"
  gcp            = var.gcp
  digitalocean   = var.digitalocean
  linode         = var.linode
  runtime        = var.runtime
}

output "instance" {
  value = module.omeka_s.instance
}

output "external_ip" {
  value = module.omeka_s.external_ip
}

output "primary_compose_project" {
  value = module.omeka_s.primary_compose_project
}
