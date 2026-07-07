terraform {
  required_version = ">= 1.2.4"
}

module "ojs" {
  source = "../app"

  name         = var.name
  template     = "ojs"
  digitalocean = var.digitalocean
  runtime      = var.runtime
}

output "instance" {
  value = module.ojs.instance
}

output "external_ip" {
  value = module.ojs.external_ip
}

output "primary_compose_project" {
  value = module.ojs.primary_compose_project
}
