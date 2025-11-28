terraform {
  required_version = ">= 1.2.4"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  rootFs = "${path.module}/rootfs"
  write_files_content = join("\n", [
    for file in fileset(local.rootFs, "**") : <<-EOT
      - path: "/${replace(file, "${local.rootFs}/", "")}"
        permissions: "0644"
        content: |
          ${indent(4, file("${local.rootFs}/${file}"))}
EOT
  ])
  docker_compose_scripts = join("\n", [
    for name, cmd in {
      "init" = var.docker_compose_init
      "up"   = var.docker_compose_up
      "down" = var.docker_compose_down
    } : <<-EOT
      - path: "/mnt/disks/data/${name}"
        permissions: "0755"
        content: |
          #!/usr/bin/env bash

          set -eou pipefail

          echo "Running docker compose ${name}"
          ${cmd}
EOT
  ])
  env_file_content = <<-EOT
    - path: "/home/cloud-compose/.env"
      permissions: "0640"
      content: |
        HOME=/home/cloud-compose
        GCP_PROJECT="${var.project_id}"
        GCP_PROJECT_NUMBER="${var.project_number}"
        GCP_INSTANCE_NAME="${var.name}"
        GCP_REGION="${var.region}"
        GCP_ZONE="${var.zone}"
        DOCKER_COMPOSE_DIR=/mnt/disks/data/compose
        DOCKER_COMPOSE_REPO="${var.docker_compose_repo}"
        DOCKER_COMPOSE_BRANCH="${var.docker_compose_branch}"
EOT
  cloud_init_yaml = templatefile("${path.module}/templates/cloud-init.yml", {
    WRITE_FILES_CONTENT    = local.write_files_content,
    DOCKER_COMPOSE_SCRIPTS = local.docker_compose_scripts,
    ENV_FILE_CONTENT       = local.env_file_content,
  })
}

data "cloudinit_config" "ci" {
  part {
    content_type = "text/cloud-config"
    content      = local.cloud_init_yaml
  }
}

resource "google_service_account" "cloud-compose" {
  account_id = format("cloud-compose-%s", var.name)
  project    = var.project_id
}

# docker pull app images
resource "google_artifact_registry_repository_iam_member" "private-policy-cloud-compose" {
  project    = var.project_id
  location   = "us"
  repository = "private"
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.cloud-compose.email}"
}

# let VM run as the GSA
resource "google_service_account_iam_member" "gsa-user" {
  service_account_id = google_service_account.cloud-compose.id
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.project_number}-compute@developer.gserviceaccount.com"
}

resource "google_service_account_iam_member" "token-creator" {
  service_account_id = google_service_account.cloud-compose.id
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.cloud-compose.email}"
}

# push logs to GCP
resource "google_project_iam_member" "log" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud-compose.email}"
}

resource "google_compute_disk" "boot" {
  # force re-create VM when cloud-init changes
  name                      = format("%s-boot-%s", var.name, md5(data.cloudinit_config.ci.rendered))
  project                   = var.project_id
  type                      = "hyperdisk-balanced"
  zone                      = var.zone
  size                      = 20
  image                     = "projects/cos-cloud/global/images/${var.os}"
  physical_block_size_bytes = 4096
}

resource "google_compute_disk" "data" {
  name                      = format("%s-data-disk", var.name)
  project                   = var.project_id
  type                      = "hyperdisk-balanced"
  zone                      = var.zone
  size                      = var.disk_size_gb
  image                     = "debian-13-trixie-v20251111"
  physical_block_size_bytes = 4096
}

resource "google_compute_instance" "cloud-compose" {
  name                      = var.name
  project                   = var.project_id
  machine_type              = var.machine_type
  zone                      = var.zone
  allow_stopping_for_update = true
  tags                      = ["cloud-compose", var.name]
  can_ip_forward            = "false"

  boot_disk {
    auto_delete = "true"
    device_name = "boot"
    source      = google_compute_disk.boot.self_link
  }
  attached_disk {
    device_name = "data"
    source      = google_compute_disk.data.self_link
  }

  metadata = {
    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"
    google-monitoring-enabled    = "true"
    user-data                    = data.cloudinit_config.ci.part[0].content
  }

  network_interface {
    network = "default"
    access_config {}
  }

  reservation_affinity {
    type = "ANY_RESERVATION"
  }

  scheduling {
    automatic_restart   = "true"
    min_node_cpus       = "0"
    on_host_maintenance = "MIGRATE"
    preemptible         = "false"
    provisioning_model  = "STANDARD"
  }

  service_account {
    email = google_service_account.cloud-compose.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/iam",
    ]
  }

  shielded_instance_config {
    enable_integrity_monitoring = "true"
    enable_secure_boot          = "true"
    enable_vtpm                 = "true"
  }
}

# machine needs to be able to suspend itself
data "google_project_iam_custom_role" "gce-suspend" {
  project = var.project_id
  role_id = "suspendVM"
}


# =============================================================================
# LIBOPS ADMIN SERVICES IDENTITY
# =============================================================================

resource "google_service_account" "internal-services" {
  account_id = format("internal-services-%s", var.name)
  project    = var.project_id
}

resource "google_service_account_iam_member" "internal-services-keys" {
  service_account_id = google_service_account.internal-services.id
  role               = "roles/iam.serviceAccountKeyAdmin"
  member             = "serviceAccount:${google_service_account.cloud-compose.email}"
}

# push metrics to GCP
resource "google_project_iam_member" "stackdriver" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.internal-services.email}"
}

# suspend the GCP instance
resource "google_project_iam_member" "gce-suspend" {
  project = var.project_id
  role    = data.google_project_iam_custom_role.gce-suspend.name
  member  = "serviceAccount:${google_service_account.internal-services.email}"
}

# =============================================================================
# DOCKER COMPOSE APP IDENTITY
# =============================================================================

resource "google_service_account" "app" {
  account_id = var.name
  project    = var.project_id
}

resource "google_service_account_iam_member" "app-keys" {
  service_account_id = google_service_account.app.id
  role               = "roles/iam.serviceAccountKeyAdmin"
  member             = "serviceAccount:${google_service_account.cloud-compose.email}"
}

# =============================================================================
# CLOUD RUN INGRESS
# =============================================================================

locals {
  base_config = yamldecode(
    <<EOT
type: google_compute_engine
port: 80
scheme: http
ipForwardedHeader: X-Forwarded-For
ipDepth: 0
powerOnCooldown: 30
proxyTimeouts:
  dialTimeout: 120
  keepAlive: 120
  idleConnTimeout: 90
  tlsHandshakeTimeout: 10
  expectContinueTimeout: 1
  maxIdleConns: 100
EOT
  )

  machine = {
    project_id   = var.project_id
    zone         = var.zone
    name         = var.name
    usePrivateIp = "true"
  }
  allowed_ips = tolist([
    "127.0.0.1/32",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
  ])

  dynamic_properties = {
    allowedIps      = concat(local.allowed_ips, var.allowed_ips)
    machineMetadata = local.machine
  }

  startup_config = merge(local.base_config, local.dynamic_properties)
}

resource "google_service_account" "ppb" {
  project     = var.project_id
  account_id  = format("ppb-%s", var.name)
  description = "Service account for Cloud Run Ingress"
}

module "ppb" {
  source = "git::https://github.com/libops/terraform-cloudrun-v2?ref=0.4.0"

  name              = var.name
  project           = var.project_id
  gsa               = google_service_account.ppb.name
  skipNeg           = true
  vpc_direct_egress = "PRIVATE_RANGES_ONLY"
  containers = tolist([
    {
      name   = "proxy-power-button",
      image  = "us-docker.pkg.dev/libops-images/public/ppb:main",
      cpu    = "1000m"
      memory = "1Gi",
      port   = 8080
    }
  ])
  invokers = [
    "allUsers"
  ]
  min_instances = 0
  max_instances = 5
  regions       = [var.region]
  addl_env_vars = tolist([
    {
      name  = "PPB_YAML"
      value = yamlencode(local.startup_config)
    }
  ])
}

# cloud run ingress needs to be able to turn on a machine
data "google_project_iam_custom_role" "gce-start" {
  project = var.project_id
  role_id = "startVM"
}

resource "google_project_iam_member" "gce-start" {
  project = var.project_id
  role    = data.google_project_iam_custom_role.gce-start.name
  member  = "serviceAccount:${google_service_account.ppb.email}"
}
