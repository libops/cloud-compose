output "zone" {
  value = google_compute_instance.cloud-compose.zone
}

output "name" {
  value = google_compute_instance.cloud-compose.name
}

output "instance_id" {
  value = google_compute_instance.cloud-compose.instance_id
}

output "gsaEmail" {
  value = google_service_account.cloud-compose.email
}

output "gsaId" {
  value = google_service_account.cloud-compose.id
}
