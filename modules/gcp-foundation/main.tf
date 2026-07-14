locals {
  service_project_id = trimspace(var.service_project_id)
  host_project_id = (
    trimspace(var.host_project_id) != ""
    ? trimspace(var.host_project_id)
    : local.service_project_id
  )
  uses_shared_vpc = local.host_project_id != local.service_project_id
  shared_vpc_subnetworks = {
    for subnet in var.shared_vpc_subnetworks :
    "${trimspace(subnet.region)}/${trimspace(subnet.name)}" => {
      name   = trimspace(subnet.name)
      region = trimspace(subnet.region)
    }
  }

  required_services = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
  ])

  project_number                         = tostring(data.google_project.service.number)
  expected_cloud_run_service_agent_email = "service-${local.project_number}@serverless-robot-prod.iam.gserviceaccount.com"
  cloud_compose_start_role_name          = "projects/${local.service_project_id}/roles/cloudComposeStart"
  cloud_compose_suspend_role_name        = "projects/${local.service_project_id}/roles/cloudComposeSuspend"
}

data "google_project" "service" {
  project_id = local.service_project_id

  depends_on = [google_project_service.required]

  lifecycle {
    precondition {
      condition = (
        !local.uses_shared_vpc ||
        length(local.shared_vpc_subnetworks) > 0
      )
      error_message = "At least one shared_vpc_subnetworks entry is required when host_project_id differs from service_project_id."
    }

    precondition {
      condition     = !var.attach_shared_vpc || local.uses_shared_vpc
      error_message = "attach_shared_vpc can be true only when host_project_id differs from service_project_id."
    }
  }
}

resource "google_project_service" "required" {
  for_each = var.manage_project_services ? local.required_services : toset([])

  project            = local.service_project_id
  service            = each.value
  disable_on_destroy = false
  deletion_policy    = "ABANDON"
}

# Enabling run.googleapis.com normally creates this Google-managed identity,
# but making the one-time service-identity call explicit removes an eventual
# consistency race before Shared VPC IAM is applied.
resource "google_project_service_identity" "cloud_run" {
  provider = google-beta

  project = local.service_project_id
  service = "run.googleapis.com"

  lifecycle {
    postcondition {
      condition     = self.email == local.expected_cloud_run_service_agent_email
      error_message = "Cloud Run returned an unexpected service-agent identity for service_project_id."
    }
  }

  depends_on = [google_project_service.required]
}

# Keep the Google-managed Cloud Run identity on its documented service-agent
# role even when a project IAM policy was previously edited by hand.
resource "google_project_iam_member" "cloud_run_service_agent" {
  project = local.service_project_id
  role    = "roles/run.serviceAgent"
  member  = google_project_service_identity.cloud_run.member

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_custom_role" "cloud_compose_start" {
  count = var.manage_power_roles ? 1 : 0

  project     = local.service_project_id
  role_id     = "cloudComposeStart"
  title       = "Cloud Compose Start"
  description = "Allows the Cloud Compose power controller to inspect and start or resume Compute Engine instances."
  permissions = [
    "compute.instances.get",
    "compute.instances.resume",
    "compute.instances.start",
  ]
  stage           = "GA"
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.required]
}

resource "google_project_iam_custom_role" "cloud_compose_suspend" {
  count = var.manage_power_roles ? 1 : 0

  project     = local.service_project_id
  role_id     = "cloudComposeSuspend"
  title       = "Cloud Compose Suspend"
  description = "Allows the Cloud Compose runtime to inspect and suspend Compute Engine instances."
  permissions = [
    "compute.instances.get",
    "compute.instances.suspend",
  ]
  stage           = "GA"
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.required]
}

resource "google_compute_shared_vpc_service_project" "attachment" {
  count = var.attach_shared_vpc ? 1 : 0

  host_project    = local.host_project_id
  service_project = local.service_project_id
  deletion_policy = "ABANDON"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "cloud_run_network_viewer" {
  count = local.uses_shared_vpc ? 1 : 0

  project = local.host_project_id
  role    = "roles/compute.networkViewer"
  member  = google_project_service_identity.cloud_run.member

  depends_on = [
    google_project_service.required,
    google_compute_shared_vpc_service_project.attachment,
  ]
}

resource "google_compute_subnetwork_iam_member" "cloud_run_network_user" {
  for_each = local.uses_shared_vpc ? local.shared_vpc_subnetworks : {}

  project    = local.host_project_id
  region     = each.value.region
  subnetwork = each.value.name
  role       = "roles/compute.networkUser"
  member     = google_project_service_identity.cloud_run.member

  depends_on = [
    google_project_service.required,
    google_compute_shared_vpc_service_project.attachment,
  ]
}
