output "instance" {
  value = {
    id : google_compute_instance.cloud-compose.instance_id,
    disk : google_compute_disk.data.name,
    zone : google_compute_instance.cloud-compose.zone,
    gsa : {
      email : google_service_account.cloud-compose.email,
      id : google_service_account.cloud-compose.id,
      name : google_service_account.cloud-compose.name,
    }
  }
  description = "The Google Compute instance ID, zone, data disk, GSA for the instance."
}

output "data_disk_name" {
  value       = google_compute_disk.data.name
  description = "Name of the data disk"
}

output "zone" {
  value       = var.zone
  description = "Zone where resources are deployed"
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
