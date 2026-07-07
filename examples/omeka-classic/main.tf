terraform {
  required_version = ">= 1.2.4"
}

module "omeka_classic" {
  source = "../app"

  name         = var.name
  template     = "omeka-classic"
  digitalocean = var.digitalocean
  runtime      = var.runtime
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
