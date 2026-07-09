locals {
  primary = var.primary_compose_project

  smoke = {
    provider             = var.cloud_provider
    app                  = var.template
    host                 = var.host
    ssh_user             = "cloud-compose"
    ssh_port             = 22
    context_name         = local.primary.sitectl_context_name
    plugin               = local.primary.sitectl_plugin
    environment          = local.primary.sitectl_environment
    site                 = var.name
    project_name         = var.name
    project_dir          = local.primary.project_dir
    compose_project_name = local.primary.compose_project_name
  }
}
