terraform {
  required_version = ">= 1.2.4"
}

module "apps" {
  source = "../.."

  name = var.name
  gcp = {
    project_id     = var.project_id
    project_number = var.project_number
  }
  runtime = {
    compose = {
      primary = "wp"
      projects = {
        wp = {
          docker_compose_repo = "https://github.com/libops/wp.git"
          ingress_port        = 8080
          sitectl_plugin      = "wp"
          sitectl_packages    = ["sitectl-wp"]
        }
        drupal = {
          docker_compose_repo = "https://github.com/libops/drupal.git"
          ingress_port        = 8081
          sitectl_plugin      = "drupal"
          sitectl_packages    = ["sitectl-drupal"]
        }
      }
    }
  }
}
