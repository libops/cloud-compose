terraform {
  required_version = ">= 1.2.4"
}

module "isle" {
  source = "../app"

  name           = var.name
  cloud_provider = var.cloud_provider
  template       = "isle"
  gcp            = var.gcp
  digitalocean   = var.digitalocean
  linode         = var.linode
  runtime        = var.runtime
}

output "instance" {
  value = module.isle.instance
}

output "external_ip" {
  value = module.isle.external_ip
}

output "primary_compose_project" {
  value = module.isle.primary_compose_project
}
