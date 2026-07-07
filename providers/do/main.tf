terraform {
  required_version = ">= 1.2.4"
}

locals {
  template_name = lower(trimspace(var.template))

  app_registry   = jsondecode(file("${path.module}/../../templates/apps.json"))
  app_templates  = local.app_registry.templates
  empty_template = local.app_registry.default
  template       = local.template_name == "" ? local.empty_template : try(local.app_templates[local.template_name], local.empty_template)

  input_compose = var.runtime.compose
  input_sitectl = var.runtime.sitectl

  runtime = merge(var.runtime, {
    compose = merge(local.input_compose, {
      repo = (
        trimspace(local.input_compose.repo) != ""
        ? local.input_compose.repo
        : local.template.repo
      )
      branch = (
        trimspace(local.input_compose.branch) != ""
        ? local.input_compose.branch
        : local.template.branch
      )
    })
    sitectl = merge(local.input_sitectl, {
      packages = (
        local.template_name != "" && length(local.input_sitectl.packages) == 1 && local.input_sitectl.packages[0] == "sitectl"
        ? local.template.packages
        : local.input_sitectl.packages
      )
      plugin = (
        local.template_name != "" && local.input_sitectl.plugin == "core"
        ? local.template.plugin
        : local.input_sitectl.plugin
      )
    })
  })
}

module "digitalocean" {
  source = "../../modules/digitalocean"

  name         = var.name
  digitalocean = var.digitalocean
  runtime      = local.runtime
}
