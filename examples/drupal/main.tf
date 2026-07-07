terraform {
  required_version = ">= 1.2.4"
}

module "drupal" {
  source = "../app"

  name         = var.name
  template     = "drupal"
  digitalocean = var.digitalocean
  runtime      = var.runtime
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
