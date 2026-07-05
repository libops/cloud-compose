resource "random_shuffle" "zone" {
  input        = var.region == "us-central1" ? ["a", "b", "c", "f"] : ["a", "b", "c"]
  result_count = 1
}

module "production" {
  source = "../.."

  name = "ojs-production"
  gcp = {
    project_id     = var.project_id
    project_number = var.project_number
    region         = var.region
    zone           = format("%s-%s", var.region, random_shuffle.zone.result[0])
    instance = {
      production = true
    }
    snapshots = {
      enabled = true
    }
    network = {
      power_button_allowed_ips = var.allowed_ips
    }
  }
  runtime = {
    compose = {
      repo   = var.docker_compose_repo
      branch = var.docker_compose_branch
      init   = var.docker_compose_init
    }
    sitectl = {
      packages = ["sitectl", "sitectl-ojs"]
      plugin   = "ojs"
    }
  }
}

module "staging" {
  source = "../.."

  name = "ojs-staging"
  gcp = {
    project_id     = var.project_id
    project_number = var.project_number
    region         = var.region
    zone           = format("%s-%s", var.region, random_shuffle.zone.result[0])
    disks = {
      docker_volumes_size_gb = 20
    }
    network = {
      power_button_allowed_ips = var.allowed_ips
    }
    overlay = {
      source_instance = "ojs-production"
      volume_names = [
        "compose_ojs-public",
        "compose_ojs-files"
      ]
    }
  }
  runtime = {
    compose = {
      repo   = var.docker_compose_repo
      branch = var.docker_compose_branch
      init   = var.docker_compose_init
    }
    sitectl = {
      packages    = ["sitectl", "sitectl-ojs"]
      plugin      = "ojs"
      environment = "staging"
    }
  }
}
