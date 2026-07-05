terraform {
  required_version = ">= 1.2.4"
}

module "app" {
  source = "../.."

  name           = var.name
  cloud_provider = var.cloud_provider
  template       = var.template
  gcp            = var.gcp
  digitalocean   = var.digitalocean
  linode         = var.linode
  runtime        = var.runtime
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
