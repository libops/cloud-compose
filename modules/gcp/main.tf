terraform {
  required_version = ">= 1.2.4"

  required_providers {
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

locals {
  rootFs            = "${path.module}/../../rootfs"
  additional_rootfs = var.rootfs != "" ? var.rootfs : ""

  single_compose_project = {
    (var.name) = {
      docker_compose_repo    = var.docker_compose_repo
      docker_compose_branch  = var.docker_compose_branch
      ingress_port           = var.ingress_port
      ingress                = var.sitectl_ingress
      sitectl_context_name   = trimspace(var.sitectl_context_name) != "" ? trimspace(var.sitectl_context_name) : var.name
      sitectl_plugin         = var.sitectl_plugin
      sitectl_environment    = var.sitectl_environment
      sitectl_packages       = var.sitectl_packages
      sitectl_verify_args    = var.sitectl_verify_args
      docker_compose_init    = var.docker_compose_init
      docker_compose_up      = var.docker_compose_up
      docker_compose_down    = var.docker_compose_down
      docker_compose_rollout = var.docker_compose_rollout
    }
  }
  raw_compose_projects        = length(var.compose_projects) > 0 ? var.compose_projects : local.single_compose_project
  primary_compose_project_key = trimspace(var.primary_compose_project) != "" ? trimspace(var.primary_compose_project) : keys(local.raw_compose_projects)[0]
  compose_projects = {
    for app_name, app in local.raw_compose_projects : app_name => {
      name                  = app_name
      docker_compose_repo   = trimspace(app.docker_compose_repo)
      docker_compose_branch = trimspace(coalesce(try(app.docker_compose_branch, null), var.docker_compose_branch))
      repo_path             = trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/")
      project_dir = (
        trimspace(try(app.project_dir, "")) != ""
        ? trimspace(try(app.project_dir, ""))
        : "/mnt/disks/data/${trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/")}/${trimspace(coalesce(try(app.docker_compose_branch, null), var.docker_compose_branch))}"
      )
      compose_project_name = (
        trimspace(try(app.compose_project_name, "")) != ""
        ? trimspace(try(app.compose_project_name, ""))
        : replace(lower(replace(replace(format("%s-%s", trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/"), trimspace(coalesce(try(app.docker_compose_branch, null), var.docker_compose_branch))), ".git", ""), "/[^a-zA-Z0-9]/", "-")), "/-+/", "-")
      )
      ingress_port = coalesce(try(app.ingress_port, null), var.ingress_port)
      ingress = {
        letsencrypt     = coalesce(try(app.ingress.letsencrypt, null), var.sitectl_ingress.letsencrypt)
        bot_mitigation  = coalesce(try(app.ingress.bot_mitigation, null), var.sitectl_ingress.bot_mitigation)
        mode            = try(app.ingress.mode, null) != null ? trimspace(app.ingress.mode) : trimspace(var.sitectl_ingress.mode)
        domain          = try(app.ingress.domain, null) != null ? trimspace(app.ingress.domain) : trimspace(var.sitectl_ingress.domain)
        acme_email      = try(app.ingress.acme_email, null) != null ? trimspace(app.ingress.acme_email) : trimspace(var.sitectl_ingress.acme_email)
        trusted_ips     = try(app.ingress.trusted_ips, null) != null ? app.ingress.trusted_ips : var.sitectl_ingress.trusted_ips
        max_upload_size = try(app.ingress.max_upload_size, null) != null ? trimspace(app.ingress.max_upload_size) : trimspace(var.sitectl_ingress.max_upload_size)
        upload_timeout  = try(app.ingress.upload_timeout, null) != null ? trimspace(app.ingress.upload_timeout) : trimspace(var.sitectl_ingress.upload_timeout)
      }
      sitectl_context_name = (
        trimspace(try(app.sitectl_context_name, "")) != ""
        ? trimspace(try(app.sitectl_context_name, ""))
        : app_name
      )
      sitectl_plugin      = trimspace(coalesce(try(app.sitectl_plugin, null), var.sitectl_plugin))
      sitectl_environment = trimspace(coalesce(try(app.sitectl_environment, null), var.sitectl_environment))
      sitectl_packages    = distinct(concat(["sitectl"], try(app.sitectl_packages, [])))
      sitectl_verify_args = try(app.sitectl_verify_args, var.sitectl_verify_args)
      init_commands       = try(app.docker_compose_init, null) != null ? app.docker_compose_init : var.docker_compose_init
      up_commands         = try(app.docker_compose_up, null) != null ? app.docker_compose_up : var.docker_compose_up
      down_commands       = try(app.docker_compose_down, null) != null ? app.docker_compose_down : var.docker_compose_down
      rollout_commands    = try(app.docker_compose_rollout, null) != null ? app.docker_compose_rollout : var.docker_compose_rollout
    }
  }
  primary_compose_project = local.compose_projects[local.primary_compose_project_key]
  sitectl_packages = distinct(concat(
    ["sitectl"],
    var.sitectl_packages,
    flatten([for _, app in local.compose_projects : app.sitectl_packages])
  ))
  create_network  = var.create_network && trimspace(var.network_name) == "" && trimspace(var.subnetwork_name) == ""
  network_name    = trimspace(var.network_name) != "" ? trimspace(var.network_name) : (local.create_network ? google_compute_network.cloud-compose[0].self_link : "default")
  subnetwork_name = trimspace(var.subnetwork_name) != "" ? trimspace(var.subnetwork_name) : (local.create_network ? google_compute_subnetwork.cloud-compose[0].self_link : null)

  # Get files from base rootfs
  base_files = fileset(local.rootFs, "**")

  # Get files from additional rootfs if path is provided
  additional_files = local.additional_rootfs != "" ? fileset(local.additional_rootfs, "**") : []

  # Combine both file sets (additional files will override base files with same path)
  all_files = merge(
    { for file in local.base_files : file => "${local.rootFs}/${file}" },
    { for file in local.additional_files : file => "${local.additional_rootfs}/${file}" }
  )

  write_files_content = join("\n", [
    for file, fullpath in local.all_files : <<-EOT
      - path: ${jsonencode("/${file}")}
        permissions: ${jsonencode(endswith(file, ".sh") ? "0755" : "0644")}
        encoding: gzip+base64
        content: ${jsonencode(base64gzip(file(fullpath)))}
EOT
  ])
  docker_compose_scripts = join("\n", [
    for name in ["init", "up", "down", "rollout"] : <<-EOT
      - path: "/home/cloud-compose/${name}"
        permissions: "0755"
        encoding: gzip+base64
        content: ${jsonencode(base64gzip(<<-EOS
          #!/usr/bin/env bash

          set -eou pipefail

          source /home/cloud-compose/profile.sh
          exec bash /home/cloud-compose/compose-dispatch.sh "${name}"
        EOS
))}
EOT
])
compose_projects_file = <<-EOT
    - path: "/home/cloud-compose/compose-projects.json"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(jsonencode(local.compose_projects)))}
EOT
managed_runtime_artifact_lines = [
  for artifact in var.libops_managed_artifacts : join("\t", [
    artifact.name,
    artifact.url,
    artifact.sha256,
    artifact.path,
    try(artifact.mode, "0755"),
    try(artifact.owner, "root"),
    try(artifact.group, "root"),
    try(artifact.restart, ""),
  ])
]
managed_runtime_artifacts_file = <<-EOT
    - path: "/home/cloud-compose/managed-runtime-artifacts.tsv"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(join("\n", local.managed_runtime_artifact_lines)))}
EOT
vault_agent_template_stanzas = join("\n", [
  for template in var.vault_agent_templates : <<-EOT
      template {
        destination = ${jsonencode(template.destination)}
        contents = <<EOH
      ${indent(2, template.contents)}
      EOH
        perms = ${jsonencode(try(template.perms, "0640"))}
      %{if trimspace(try(template.command, "")) != ""}
        command = ${jsonencode(template.command)}
      %{endif}
      }
    EOT
])
vault_agent_auto_auth_gcp  = <<-EOT
    auto_auth {
      method "gcp" {
        mount_path = ${jsonencode(var.vault_gcp_auth_mount_path)}
        config = {
          type            = "iam"
          role            = ${jsonencode(trimspace(var.vault_role))}
          service_account = ${jsonencode(local.app_service_account_email)}
          jwt_exp         = 15
        }
      }

      sink "file" {
        config = {
          path = ${jsonencode(var.vault_agent_token_path)}
        }
      }
    }
  EOT
vault_agent_auto_auth      = var.vault_auth_method == "gcp-iam" ? local.vault_agent_auto_auth_gcp : trimspace(var.vault_agent_additional_config)
vault_agent_env_content    = <<-EOT
    VAULT_ADDR=${trimspace(var.vault_addr)}
    VAULT_NAMESPACE=${trimspace(var.vault_namespace)}
    VAULT_ROLE=${trimspace(var.vault_role)}
    VAULT_AUTH_METHOD=${var.vault_auth_method}
    GOOGLE_APPLICATION_CREDENTIALS=/mnt/disks/data/cloud-compose/app/GOOGLE_APPLICATION_CREDENTIALS
  EOT
vault_agent_config_content = <<-EOT
    vault {
      address = ${jsonencode(trimspace(var.vault_addr))}
%{if trimspace(var.vault_namespace) != ""}
      namespace = ${jsonencode(trimspace(var.vault_namespace))}
%{endif}
    }

    ${indent(4, local.vault_agent_auto_auth)}

    ${indent(4, local.vault_agent_template_stanzas)}
  EOT
vault_agent_files_raw      = <<-EOT
    - path: "/etc/default/vault-agent"
      permissions: "0600"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.vault_agent_env_content))}
    - path: "/etc/vault-agent.d/cloud-compose.hcl"
      permissions: "0600"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.vault_agent_config_content))}
  EOT
vault_agent_files          = var.vault_agent_enabled && trimspace(var.vault_addr) != "" ? local.vault_agent_files_raw : ""
rollout_env_lines = var.rollout_enabled ? [
  "ROLLOUT_ENABLED=true",
  "ROLLOUT_DOWNLOAD_URL=\"${trimspace(var.rollout_release_url)}\"",
  "ROLLOUT_DOWNLOAD_SHA256=\"${trimspace(var.rollout_release_sha256)}\"",
  "PORT=\"${var.rollout_port}\"",
  "JWKS_URI=\"${trimspace(var.rollout_jwks_uri)}\"",
  "JWT_AUD=\"${trimspace(var.rollout_jwt_audience)}\"",
  "CUSTOM_CLAIMS='${trimspace(var.rollout_custom_claims)}'",
  "ROLLOUT_CMD=\"/bin/bash\"",
  "ROLLOUT_ARGS=\"/home/cloud-compose/rollout\"",
  "ROLLOUT_LOCK_FILE=\"/mnt/disks/data/rollout.lock\"",
  ] : [
  "ROLLOUT_ENABLED=false",
]
rollout_env      = join("\n", local.rollout_env_lines)
env_file_plain   = <<-EOT
    HOME=/home/cloud-compose
    GCP_PROJECT="${var.project_id}"
    GCP_PROJECT_NUMBER="${var.project_number}"
    GCP_INSTANCE_NAME="${var.name}"
    CLOUD_COMPOSE_INSTANCE_NAME="${var.name}"
    GCP_REGION="${var.region}"
    GCP_ZONE="${var.zone}"
    CLOUD_COMPOSE_PROVIDER="gcp"
    CLOUD_COMPOSE_APPS="${join(" ", keys(local.compose_projects))}"
    CLOUD_COMPOSE_PRIMARY_APP="${local.primary_compose_project_key}"
    COMPOSE_PROJECTS_FILE="/home/cloud-compose/compose-projects.json"
    COMPOSE_PROJECT_NAME=${local.primary_compose_project.compose_project_name}
    COMPOSE_BIND_PORT="${local.primary_compose_project.ingress_port}"
    DOCKER_COMPOSE_DIR=${local.primary_compose_project.project_dir}
    DOCKER_COMPOSE_REPO="${local.primary_compose_project.docker_compose_repo}"
    DOCKER_COMPOSE_BRANCH="${local.primary_compose_project.docker_compose_branch}"
    DOCKER_COMPOSE_VERSION="${var.docker_compose_version}"
    DOCKER_BUILDX_VERSION="${var.docker_buildx_version}"
    SITECTL_PACKAGES="${join(" ", local.sitectl_packages)}"
    SITECTL_VERSION="${var.sitectl_version}"
    SITECTL_CONTEXT_NAME="${local.primary_compose_project.sitectl_context_name}"
    SITECTL_PLUGIN="${local.primary_compose_project.sitectl_plugin}"
    SITECTL_ENVIRONMENT="${local.primary_compose_project.sitectl_environment}"
    PRODUCTION="${var.production}"
    SITECTL_VERIFY_ARGS="${join(" ", local.primary_compose_project.sitectl_verify_args)}"
    GCP_APP_SERVICE_ACCOUNT_EMAIL="${local.app_service_account_email}"
    POWER_MANAGEMENT_ENABLED="${var.power_management_enabled}"
    COMPOSE_PROFILES="${local.internal_services_compose_profiles}"
    VAULT_ADDR="${trimspace(var.vault_addr)}"
    VAULT_NAMESPACE="${trimspace(var.vault_namespace)}"
    VAULT_ROLE="${trimspace(var.vault_role)}"
    VAULT_AGENT_ENABLED="${var.vault_agent_enabled && trimspace(var.vault_addr) != "" ? "true" : "false"}"
    VAULT_AUTH_METHOD="${var.vault_auth_method}"
    VAULT_AGENT_TOKEN_PATH="${var.vault_agent_token_path}"
    LIBOPS_MANAGED_RUNTIME_ENABLED="${var.libops_managed_runtime_enabled}"
    LIBOPS_INTERNAL_SERVICES_ENABLED="${var.libops_internal_services_enabled}"
    LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE="${var.libops_internal_services_auto_update}"
    ${local.rollout_env}
  EOT
env_file_content = <<-EOT
    - path: "/home/cloud-compose/.env"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.env_file_plain))}
EOT
use_overlay      = length(var.volume_names) > 0
prod_disk_name   = var.overlay_source_instance != "" ? format("%s-data-disk", var.overlay_source_instance) : ""
prod_disk_url    = var.overlay_source_instance != "" ? format("https://www.googleapis.com/compute/v1/projects/%s/zones/%s/disks/%s-docker-volumes", var.project_id, var.zone, var.overlay_source_instance) : ""
rollout_runcmd = var.rollout_enabled ? [
  "bash /home/cloud-compose/deploy-rollout.sh >> /home/cloud-compose/run.log 2>&1",
] : []
cloud_init_yaml = templatefile("${path.module}/../../templates/cloud-init.yml", {
  WRITE_FILES_CONTENT            = local.write_files_content,
  DOCKER_COMPOSE_SCRIPTS         = local.docker_compose_scripts,
  COMPOSE_PROJECTS_FILE          = local.compose_projects_file,
  ENV_FILE_CONTENT               = local.env_file_content,
  VAULT_AGENT_FILES              = local.vault_agent_files,
  MANAGED_RUNTIME_ARTIFACTS_FILE = local.managed_runtime_artifacts_file,
  USE_OVERLAY                    = local.use_overlay,
  DOCKER_VOLUME_OVERLAYS         = var.volume_names,
  CLOUD_COMPOSE_SSH_KEYS         = try(var.users["cloud-compose"], []),
  SSH_USERS                      = { for username, ssh_keys in var.users : username => ssh_keys if username != "cloud-compose" },
  ADDITIONAL_INITCMD             = var.initcmd,
  ADDITIONAL_RUNCMD              = concat(local.rollout_runcmd, var.runcmd),
})

vm_service_account_email = var.service_account_email != "" ? var.service_account_email : google_service_account.cloud-compose[0].email
vm_service_account_id    = var.service_account_email != "" ? "projects/${var.project_id}/serviceAccounts/${var.service_account_email}" : google_service_account.cloud-compose[0].id
vm_service_account_name  = var.service_account_email != "" ? local.vm_service_account_id : google_service_account.cloud-compose[0].name

app_service_account_email = var.app_service_account_email != "" ? var.app_service_account_email : google_service_account.app[0].email
app_service_account_id    = var.app_service_account_email != "" ? "projects/${var.project_id}/serviceAccounts/${var.app_service_account_email}" : google_service_account.app[0].id
app_service_account_name  = var.app_service_account_email != "" ? local.app_service_account_id : google_service_account.app[0].name

internal_services_compose_profiles = var.power_management_enabled ? "lightsout" : ""
scheduled_snapshots_enabled        = var.production && var.run_snapshots
# have prod snapshot begin near the initial run so non-prod overlays can
# discover a production snapshot; non-production plans avoid snapshot resources.
snapshot_start_time = local.scheduled_snapshots_enabled ? formatdate("h:00", time_static.snapshot_time_static[0].rfc3339) : "00:00"
}

resource "time_static" "snapshot_time_static" {
  count = local.scheduled_snapshots_enabled ? 1 : 0
}

data "cloudinit_config" "ci" {
  part {
    content_type = "text/cloud-config"
    content      = local.cloud_init_yaml
  }
}

resource "google_service_account" "cloud-compose" {
  count      = var.service_account_email == "" ? 1 : 0
  account_id = format("vm-%s", var.name)
  project    = var.project_id
}

# docker pull app images
resource "google_artifact_registry_repository_iam_member" "private-policy-cloud-compose" {
  count      = var.artifact_registry_repository != "" ? 1 : 0
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.vm_service_account_email}"
}

# let VM run as the GSA
resource "google_service_account_iam_member" "gsa-user" {
  service_account_id = local.vm_service_account_id
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.project_number}-compute@developer.gserviceaccount.com"
}

resource "google_service_account_iam_member" "token-creator" {
  service_account_id = local.vm_service_account_id
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.vm_service_account_email}"
}

# push logs to GCP
resource "google_project_iam_member" "log" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.vm_service_account_email}"
}

resource "google_compute_network" "cloud-compose" {
  count                   = local.create_network ? 1 : 0
  name                    = var.name
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "cloud-compose" {
  count                    = local.create_network ? 1 : 0
  name                     = var.name
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.cloud-compose[0].self_link
  ip_cidr_range            = var.network_ip_cidr_range
  private_ip_google_access = true
}

resource "google_compute_disk" "boot" {
  # force re-create VM when cloud-init changes
  name                      = format("%s-boot-%s", var.name, md5(data.cloudinit_config.ci.rendered))
  project                   = var.project_id
  type                      = var.disk_type
  zone                      = var.zone
  size                      = 15
  image                     = "projects/cos-cloud/global/images/${var.os}"
  physical_block_size_bytes = 4096
}

resource "google_compute_disk" "data" {
  name                      = format("%s-data-disk", var.name)
  project                   = var.project_id
  type                      = var.disk_type
  zone                      = var.zone
  size                      = 20
  physical_block_size_bytes = 4096
}

resource "google_compute_disk" "docker-volumes" {
  name                      = format("%s-docker-volumes", var.name)
  project                   = var.project_id
  type                      = var.disk_type
  zone                      = var.zone
  size                      = var.disk_size_gb
  physical_block_size_bytes = 4096
}

resource "google_compute_reservation" "production" {
  count   = var.production ? 1 : 0
  name    = format("%s-production", var.name)
  project = var.project_id
  zone    = var.zone

  specific_reservation {
    count = 1
    instance_properties {
      machine_type = var.machine_type
    }
  }
  specific_reservation_required = true
}

# Daily snapshot schedule for production docker volume disk
resource "google_compute_resource_policy" "daily_snapshot" {
  count   = local.scheduled_snapshots_enabled ? 1 : 0
  name    = format("%s-daily-snapshot", var.name)
  project = var.project_id
  region  = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = local.snapshot_start_time
      }
    }

    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }

    snapshot_properties {
      labels = {
        managed_by = "terraform"
        instance   = var.name
      }
      storage_locations = [var.region]
      guest_flush       = false
    }
  }
}

resource "google_compute_resource_policy" "weekly_snapshot" {
  count   = local.scheduled_snapshots_enabled ? 1 : 0
  name    = format("%s-weekly-snapshot", var.name)
  project = var.project_id
  region  = var.region

  snapshot_schedule_policy {
    schedule {
      weekly_schedule {
        day_of_weeks {
          day        = "SUNDAY"
          start_time = "01:00"
        }
      }
    }

    retention_policy {
      max_retention_days    = 365
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }

    snapshot_properties {
      storage_locations = [var.region]
      guest_flush       = false
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "daily_snapshot" {
  for_each = local.scheduled_snapshots_enabled ? toset([
    google_compute_disk.docker-volumes.name,
    google_compute_disk.data.name
  ]) : []

  name    = google_compute_resource_policy.daily_snapshot[0].name
  disk    = each.value
  project = var.project_id
  zone    = var.zone
}

resource "google_compute_disk_resource_policy_attachment" "weekly_snapshot" {
  for_each = local.scheduled_snapshots_enabled ? toset([
    google_compute_disk.docker-volumes.name,
    google_compute_disk.data.name
  ]) : []

  name    = google_compute_resource_policy.weekly_snapshot[0].name
  disk    = each.value
  project = var.project_id
  zone    = var.zone
}

# Get the latest snapshot from production instance's data disk
data "google_compute_snapshot" "latest_prod" {
  count   = local.use_overlay ? 1 : 0
  project = var.project_id

  # Filter to snapshots of the production data disk, get most recent
  most_recent = true
  filter      = "sourceDisk eq ${local.prod_disk_url}"
}

# Restore production snapshot to a staging-specific disk for overlays
resource "google_compute_disk" "overlay_disk" {
  count                     = local.use_overlay ? 1 : 0
  name                      = data.google_compute_snapshot.latest_prod[0].name
  project                   = var.project_id
  type                      = var.disk_type
  zone                      = var.zone
  snapshot                  = data.google_compute_snapshot.latest_prod[0].self_link
  physical_block_size_bytes = 4096

  lifecycle {
    create_before_destroy = true
  }
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
  attached_disk {
    device_name = "docker-volumes"
    source      = google_compute_disk.docker-volumes.self_link
  }

  dynamic "attached_disk" {
    for_each = local.use_overlay ? [1] : []
    content {
      device_name = "prod-volumes"
      source      = google_compute_disk.overlay_disk[0].self_link
      # hyperdisk needs to be attached rw
      # even though we're setting this as lowerdir read only
      mode = "READ_WRITE"
    }
  }

  metadata = {
    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"
    google-monitoring-enabled    = "true"
    user-data                    = data.cloudinit_config.ci.part[0].content
  }

  network_interface {
    network    = local.network_name
    subnetwork = local.subnetwork_name
    access_config {}
  }

  reservation_affinity {
    type = var.production ? "SPECIFIC_RESERVATION" : "ANY_RESERVATION"

    dynamic "specific_reservation" {
      for_each = var.production ? [google_compute_reservation.production[0].name] : []
      content {
        key    = "compute.googleapis.com/reservation-name"
        values = [specific_reservation.value]
      }
    }
  }

  scheduling {
    automatic_restart   = "true"
    min_node_cpus       = "0"
    on_host_maintenance = "MIGRATE"
    preemptible         = "false"
    provisioning_model  = "STANDARD"
  }

  service_account {
    email = local.vm_service_account_email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  shielded_instance_config {
    enable_integrity_monitoring = "true"
    enable_secure_boot          = "true"
    enable_vtpm                 = "true"
  }

  lifecycle {
    precondition {
      condition     = contains(keys(local.compose_projects), local.primary_compose_project_key)
      error_message = "primary_compose_project must be one of the compose_projects keys."
    }
    precondition {
      condition     = !var.vault_agent_enabled || trimspace(var.vault_addr) != ""
      error_message = "vault_addr is required when vault_agent_enabled is true."
    }
    precondition {
      condition     = !var.vault_agent_enabled || var.vault_auth_method != "gcp-iam" || trimspace(var.vault_role) != ""
      error_message = "vault_role is required when vault_agent_enabled uses gcp-iam."
    }
    precondition {
      condition     = !var.vault_agent_enabled || var.vault_auth_method != "consumer-managed" || trimspace(var.vault_agent_additional_config) != ""
      error_message = "vault_agent_additional_config is required when vault_agent_enabled uses consumer-managed auth."
    }
    precondition {
      condition = alltrue([
        for _, app in local.compose_projects : trimspace(app.docker_compose_repo) != ""
      ])
      error_message = "Each compose project must define docker_compose_repo. Set docker_compose_repo for legacy single-app deployments or pass compose_projects."
    }
    precondition {
      condition = alltrue([
        for _, app in local.compose_projects :
        !(contains(["https-letsencrypt", "letsencrypt", "le"], app.ingress.mode) || app.ingress.letsencrypt) ||
        trimspace(app.ingress.domain) != "" && trimspace(app.ingress.acme_email) != ""
      ])
      error_message = "Let's Encrypt ingress requires ingress.domain and ingress.acme_email for each enabled compose project."
    }
    precondition {
      condition = (
        startswith(var.machine_type, "e2") ?
        contains(["pd-ssd", "pd-standard"], var.disk_type) :
        true
      )
      error_message = "When using an 'e2' machine type, 'disk_type' must be 'pd-ssd' or 'pd-standard'."
    }
    precondition {
      condition     = !var.rollout_enabled || trimspace(var.rollout_release_url) != ""
      error_message = "rollout_release_url is required when rollout_enabled is true."
    }
    precondition {
      condition     = !var.rollout_enabled || can(regex("^[0-9a-f]{64}$", trimspace(var.rollout_release_sha256)))
      error_message = "rollout_release_sha256 must be a lowercase SHA256 hex digest when rollout_enabled is true."
    }
    precondition {
      condition     = !var.rollout_enabled || trimspace(var.rollout_jwks_uri) != ""
      error_message = "rollout_jwks_uri is required when rollout_enabled is true."
    }
    precondition {
      condition     = !var.rollout_enabled || trimspace(var.rollout_jwt_audience) != ""
      error_message = "rollout_jwt_audience is required when rollout_enabled is true."
    }
  }

  depends_on = [google_compute_disk.overlay_disk]
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
  account_id = format("internal-%s", var.name)
  project    = var.project_id
}

resource "google_service_account_iam_member" "internal-services-keys" {
  service_account_id = google_service_account.internal-services.id
  role               = "roles/iam.serviceAccountKeyAdmin"
  member             = "serviceAccount:${local.vm_service_account_email}"
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
  count      = var.app_service_account_email == "" ? 1 : 0
  account_id = var.name
  project    = var.project_id
}

resource "google_service_account_iam_member" "app-keys" {
  service_account_id = local.app_service_account_id
  role               = "roles/iam.serviceAccountKeyAdmin"
  member             = "serviceAccount:${local.vm_service_account_email}"
}

resource "google_service_account_iam_member" "self_jwt_signer_policy" {
  service_account_id = local.app_service_account_id
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = format("serviceAccount:%s", local.app_service_account_email)
}

# =============================================================================
# CLOUD RUN INGRESS
# =============================================================================

locals {
  base_config = yamldecode(
    <<EOT
type: google_compute_engine
port: ${local.primary_compose_project.ingress_port}
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
    usePrivateIp = true
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

  frontend_proxy_target = var.frontend == null ? {} : {
    proxyTarget = {
      scheme = "http"
      host   = "localhost"
      port   = var.frontend.port
    }
  }

  # Sidecar container: no Cloud Run ingress port mapping (port = 0).
  # The process still listens on var.frontend.port internally so ppb can
  # reach it via localhost.
  frontend_container = var.frontend == null ? [] : [
    {
      name   = "frontend"
      image  = var.frontend.image
      cpu    = var.frontend.cpu
      memory = var.frontend.memory
      port   = 0
    }
  ]

  startup_config = merge(local.base_config, local.dynamic_properties, local.frontend_proxy_target)
}

resource "google_service_account" "ppb" {
  count       = var.power_management_enabled ? 1 : 0
  project     = var.project_id
  account_id  = format("ppb-%s", var.name)
  description = "Service account for Cloud Run Ingress"
}

module "ppb" {
  count  = var.power_management_enabled ? 1 : 0
  source = "https://github.com/libops/terraform-cloudrun-v2/archive/refs/tags/0.5.3.zip//terraform-cloudrun-v2-0.5.3"

  name                         = var.name
  project                      = var.project_id
  gsa                          = google_service_account.ppb[0].name
  skipNeg                      = true
  vpc_direct_egress            = "PRIVATE_RANGES_ONLY"
  vpc_direct_egress_network    = local.network_name
  vpc_direct_egress_subnetwork = local.subnetwork_name != null ? local.subnetwork_name : "default"
  containers = concat(
    tolist([
      {
        name   = "proxy-power-button",
        image  = "us-docker.pkg.dev/libops-images/public/ppb:0.4.2@sha256:e073702aab35db2661dc5f16bbdeaa32bfc79223212d5ba5f2892776cd94205e",
        cpu    = "1000m"
        memory = "1Gi",
        port   = 8080
      }
    ]),
    local.frontend_container,
  )
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
  count   = var.power_management_enabled ? 1 : 0
  project = var.project_id
  role_id = "startVM"
}

resource "google_project_iam_member" "gce-start" {
  count   = var.power_management_enabled ? 1 : 0
  project = var.project_id
  role    = data.google_project_iam_custom_role.gce-start[0].name
  member  = "serviceAccount:${google_service_account.ppb[0].email}"
}

resource "google_compute_firewall" "allow_ssh_ipv4" {
  project   = var.project_id
  name      = format("allow-ssh-ipv4-%s", var.name)
  network   = local.network_name
  priority  = 10
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  target_tags = [var.name]

  source_ranges = length(var.allowed_ssh_ipv4) > 0 ? var.allowed_ssh_ipv4 : ["127.0.0.1/32"]
}

resource "google_compute_firewall" "allow_ssh_ipv6" {
  project   = var.project_id
  name      = format("allow-ssh-ipv6-%s", var.name)
  network   = local.network_name
  priority  = 10
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = [var.name]

  source_ranges = length(var.allowed_ssh_ipv6) > 0 ? var.allowed_ssh_ipv6 : ["127.0.0.1/32"]
}

resource "google_compute_firewall" "allow_rollout_ipv4" {
  count     = var.rollout_enabled ? 1 : 0
  project   = var.project_id
  name      = format("allow-rollout-ipv4-%s", var.name)
  network   = local.network_name
  priority  = 20
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = [tostring(var.rollout_port)]
  }

  target_tags   = [var.name]
  source_ranges = length(var.rollout_allowed_ipv4) > 0 ? var.rollout_allowed_ipv4 : ["127.0.0.1/32"]
}
