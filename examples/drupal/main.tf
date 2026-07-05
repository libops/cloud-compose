terraform {
  required_version = ">= 1.2.4"
}

module "drupal" {
  source = "../app"

  name           = var.name
  cloud_provider = var.cloud_provider
  template       = "drupal"
  gcp            = var.gcp
  digitalocean   = var.digitalocean
  linode         = var.linode
  runtime        = var.runtime
}

output "instance" {
  value = module.drupal.instance
}

output "external_ip" {
  value = module.drupal.external_ip
}

output "primary_compose_project" {
  value = module.drupal.primary_compose_project
}
