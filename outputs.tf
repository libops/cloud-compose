output "instance" {
  value = {
    id : google_compute_instance.cloud-compose.instance_id,
    name : google_compute_instance.cloud-compose.name,
    disk : google_compute_disk.docker-volumes.name,
    zone : google_compute_instance.cloud-compose.zone,
    internal_ip : google_compute_instance.cloud-compose.network_interface[0].network_ip,
    gsa : {
      email : local.vm_service_account_email,
      id : local.vm_service_account_id,
      name : local.vm_service_account_name,
    }
  }
  description = "The Google Compute instance ID, name, zone, data disk, GSA for the instance."
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
  value = {
    email : google_service_account.internal-services.email,
    id : google_service_account.internal-services.id,
    name : google_service_account.internal-services.name,
  }
  description = "The Google Service Account internal services that manage the VM runs as"
}

output "appGsa" {
  value = {
    email : google_service_account.app.email,
    id : google_service_account.app.id,
    name : google_service_account.app.name,
  }
  description = "The Google Service Account the app can leverage to auth to other Google services"
}

output "urls" {
  value       = module.ppb.urls
  description = "Cloud Run ingress URLs by region."
}

output "backend" {
  value       = module.ppb.backend
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
