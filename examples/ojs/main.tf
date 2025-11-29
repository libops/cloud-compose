resource "random_shuffle" "zone" {
  input        = var.region == "us-central1" ? ["a", "b", "c", "f"] : ["a", "b", "c"]
  result_count = 1
}

module "production" {
  source = "../.."

  name                = "ojs-production"
  project_id          = var.project_id
  project_number      = var.project_number
  docker_compose_repo = var.docker_compose_repo
  docker_compose_init = var.docker_compose_init
  region              = var.region
  zone                = format("%s-%s", var.region, random_shuffle.zone.result[0])
  run_snapshots       = true
  allowed_ips         = var.allowed_ips
}

module "staging" {
  source = "../.."

  name                = "ojs-staging"
  project_id          = var.project_id
  project_number      = var.project_number
  docker_compose_repo = var.docker_compose_repo
  docker_compose_init = var.docker_compose_init
  region              = var.region
  zone                = format("%s-%s", var.region, random_shuffle.zone.result[0])
  disk_size_gb        = 20
  allowed_ips         = var.allowed_ips

  # make production public files available in staging
  overlay_source_instance = "ojs-production"
  volume_names = [
    "compose_ojs-public"
  ]
}
