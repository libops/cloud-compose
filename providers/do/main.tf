terraform {
  required_version = ">= 1.3.0"

  required_providers {
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

locals {
  template_name = lower(trimspace(var.template))

  app_registry   = jsondecode(file("${path.module}/../../templates/apps.json"))
  app_templates  = local.app_registry.templates
  empty_template = local.app_registry.default
  template       = local.template_name == "" ? local.empty_template : try(local.app_templates[local.template_name], local.empty_template)

  input_compose = var.runtime.compose
  input_sitectl = var.runtime.sitectl

  sitectl_packages = distinct(concat(
    ["sitectl"],
    local.input_sitectl.packages == null ? local.template.packages : local.input_sitectl.packages,
  ))
  template_sitectl_package_versions = {
    for package in local.sitectl_packages :
    package => local.template.package_versions[package]
    if contains(keys(local.template.package_versions), package)
  }

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
      packages         = local.sitectl_packages
      package_versions = merge(local.template_sitectl_package_versions, local.input_sitectl.package_versions)
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
