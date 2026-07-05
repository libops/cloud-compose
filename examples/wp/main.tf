terraform {
  required_version = ">= 1.2.4"
}

module "wp" {
  source = "../app"

  name           = var.name
  cloud_provider = var.cloud_provider
  template       = "wp"
  gcp            = var.gcp
  digitalocean   = var.digitalocean
  linode         = var.linode
  runtime        = var.runtime
}

output "instance" {
  value = module.wp.instance
}

output "external_ip" {
  value = module.wp.external_ip
}

output "primary_compose_project" {
  value = module.wp.primary_compose_project
}
