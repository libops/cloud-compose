terraform {
  required_version = ">= 1.3.0"
}

module "app" {
  source = "../../providers/do"

  name         = var.name
  template     = var.template
  digitalocean = var.digitalocean
  runtime      = var.runtime
}

output "instance" {
  value = module.app.instance
}

output "external_ip" {
  value = module.app.external_ip
}

output "internal_ip" {
  value = module.app.internal_ip
}

output "volumes" {
  value = module.app.volumes
}

output "primary_compose_project" {
  value = module.app.primary_compose_project
}

output "compose_projects" {
  value = module.app.compose_projects
}
