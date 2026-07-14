terraform {
  required_version = ">= 1.3.0"
}

module "archivesspace" {
  source = "../app"

  name         = var.name
  template     = "archivesspace"
  digitalocean = var.digitalocean
  runtime      = var.runtime
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
