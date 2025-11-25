output "zone" {
  value = google_compute_instance.cloud-compose.zone
}

output "name" {
  value = google_compute_instance.cloud-compose.name
}

output "instance_id" {
  value = google_compute_instance.cloud-compose.instance_id
}


output "instanceGsa" {
  value = {
    email : google_service_account.cloud-compose.email,
    id : google_service_account.cloud-compose.id,
    name : google_service_account.cloud-compose.name,
  }
  description = "The Google Service Account the compute instance runs as"
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
