terraform {
  required_version = ">= 1.3.0"
}

module "apps" {
  source = "../../providers/gcp"

  name = var.name
  gcp = {
    project_id = var.project_id
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
