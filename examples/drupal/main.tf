terraform {
  required_version = ">= 1.2.4"
}

module "drupal" {
  source = "../.."

  name = var.name
  gcp = {
    project_id     = var.project_id
    project_number = var.project_number
  }
  runtime = {
    compose = {
      repo         = var.docker_compose_repo
      branch       = var.docker_compose_branch
      ingress_port = var.ingress_port
    }
    sitectl = {
      packages = ["sitectl", "sitectl-drupal"]
      plugin   = "drupal"
    }
    vault = {
      addr          = var.vault_addr
      role          = var.vault_role
      agent_enabled = var.vault_agent_enabled
    }
  }
}
