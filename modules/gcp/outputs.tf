output "instance" {
  value = {
    id          = google_compute_instance.cloud-compose.instance_id
    name        = google_compute_instance.cloud-compose.name
    disk        = google_compute_disk.docker-volumes.name
    zone        = google_compute_instance.cloud-compose.zone
    internal_ip = google_compute_instance.cloud-compose.network_interface[0].network_ip
    network = {
      project_id = local.network_project_id
      self_link  = local.network_name
      subnetwork = local.subnetwork_name
      ipv4_cidr  = local.cloud_run_subnetwork_cidr
      mtu        = local.cloud_run_network_mtu
      direct_vpc = var.power_management_enabled
      vm_tag     = local.network_namespace
    }
    boot_disk = {
      id        = google_compute_disk.boot.id
      name      = google_compute_disk.boot.name
      self_link = google_compute_disk.boot.self_link
    }
    data_disk = {
      id        = google_compute_disk.data.id
      name      = google_compute_disk.data.name
      self_link = google_compute_disk.data.self_link
      size_gb   = google_compute_disk.data.size
    }
    docker_volumes_disk = {
      id        = google_compute_disk.docker-volumes.id
      name      = google_compute_disk.docker-volumes.name
      self_link = google_compute_disk.docker-volumes.self_link
      size_gb   = google_compute_disk.docker-volumes.size
    }
    gsa : {
      email : local.vm_service_account_email,
      id : local.vm_service_account_id,
      name : local.vm_service_account_name,
    }
  }
  description = "The GCP instance identity, network placement, replaceable boot disk, persistent disks, and VM service account. The legacy disk field remains the Docker-volume disk name."
}

output "network" {
  value = {
    project_id = local.network_project_id
    self_link  = local.network_name
    subnetwork = local.subnetwork_name
    ipv4_cidr  = local.cloud_run_subnetwork_cidr
    mtu        = local.cloud_run_network_mtu
    direct_vpc = var.power_management_enabled
    vm_tag     = local.network_namespace
  }
  description = "Resolved GCP network and regional subnetwork shared by the VM and optional Cloud Run Direct VPC egress."
}

output "volumes" {
  value = {
    data = {
      id        = google_compute_disk.data.id
      name      = google_compute_disk.data.name
      self_link = google_compute_disk.data.self_link
      size_gb   = google_compute_disk.data.size
    }
    docker_volumes = {
      id        = google_compute_disk.docker-volumes.id
      name      = google_compute_disk.docker-volumes.name
      self_link = google_compute_disk.docker-volumes.self_link
      size_gb   = google_compute_disk.docker-volumes.size
    }
  }
  description = "Persistent GCP application-data and Docker-volume disks. The replaceable boot disk is exposed under instance.boot_disk."
}

output "instance_id" {
  value       = google_compute_instance.cloud-compose.instance_id
  description = "The Google Compute instance ID."
}

output "external_ip" {
  value       = google_compute_instance.cloud-compose.network_interface[0].access_config[0].nat_ip
  description = "The Google Compute instance external IPv4 address."
}

output "internal_ip" {
  value       = google_compute_instance.cloud-compose.network_interface[0].network_ip
  description = "The Google Compute instance internal IPv4 address."
}

output "serviceGsa" {
  value = local.internal_services_enabled ? {
    email : google_service_account.internal-services[0].email,
    id : google_service_account.internal-services[0].id,
    name : google_service_account.internal-services[0].name,
  } : null
  description = "The internal-services Google service account when that privileged runtime is enabled, otherwise null."
}

output "appGsa" {
  value = {
    email : local.app_service_account_email,
    id : local.app_service_account_id,
    name : local.app_service_account_name,
    credentials_enabled : local.app_credentials_enabled,
  }
  description = "The Google Service Account the app can leverage to authenticate to other Google services, including whether managed file credentials are enabled."
}

output "urls" {
  value       = var.power_management_enabled ? module.ppb[0].urls : {}
  description = "Cloud Run ingress URLs by region."
}

output "backend" {
  value       = var.power_management_enabled ? module.ppb[0].backend : null
  description = "Backend service ID for attaching the Cloud Run ingress to an external HTTPS load balancer."
}

output "rollout" {
  value = {
    enabled : var.rollout_enabled,
    port : var.rollout_port,
    url : var.rollout_enabled ? "http://${google_compute_instance.cloud-compose.network_interface[0].network_ip}:${var.rollout_port}" : null,
    internal_url : var.rollout_enabled ? "http://${google_compute_instance.cloud-compose.network_interface[0].network_ip}:${var.rollout_port}" : null,
    audience : var.rollout_jwt_audience,
  }
  description = "Optional rollout API endpoint details. The URL is the VPC-internal endpoint."
}

output "compose_projects" {
  value       = local.validated_compose_projects
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value       = local.primary_compose_project
  description = "Normalized primary compose project."
}

output "sitectl_package_versions" {
  value       = module.sitectl_runtime.package_versions
  description = "Effective release selector for every installed sitectl package; values may be exact tags or latest."
}
