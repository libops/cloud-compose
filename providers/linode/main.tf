terraform {
  required_version = ">= 1.2.4"
}

locals {
  template_name = lower(trimspace(var.template))

  app_templates = {
    archivesspace = {
      repo     = "https://github.com/libops/archivesspace.git"
      branch   = "main"
      plugin   = "archivesspace"
      packages = ["sitectl", "sitectl-archivesspace"]
    }
    ojs = {
      repo     = "https://github.com/libops/ojs.git"
      branch   = "main"
      plugin   = "ojs"
      packages = ["sitectl", "sitectl-ojs"]
    }
    isle = {
      repo     = "https://github.com/libops/isle"
      branch   = "main"
      plugin   = "isle"
      packages = ["sitectl", "sitectl-drupal", "sitectl-isle"]
    }
    drupal = {
      repo     = "https://github.com/libops/drupal.git"
      branch   = "main"
      plugin   = "drupal"
      packages = ["sitectl", "sitectl-drupal"]
    }
    wp = {
      repo     = "https://github.com/libops/wp.git"
      branch   = "main"
      plugin   = "wp"
      packages = ["sitectl", "sitectl-wp"]
    }
    "omeka-s" = {
      repo     = "https://github.com/libops/omeka-s.git"
      branch   = "main"
      plugin   = "omeka-s"
      packages = ["sitectl", "sitectl-omeka-s"]
    }
    "omeka-classic" = {
      repo     = "https://github.com/libops/omeka-classic.git"
      branch   = "main"
      plugin   = "omeka-classic"
      packages = ["sitectl", "sitectl-omeka-classic"]
    }
  }
  empty_template = {
    repo     = ""
    branch   = "main"
    plugin   = "core"
    packages = ["sitectl"]
  }
  template = local.template_name == "" ? local.empty_template : try(local.app_templates[local.template_name], local.empty_template)

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

module "linode" {
  source = "../../modules/linode"

  name    = var.name
  linode  = var.linode
  runtime = local.runtime
}
