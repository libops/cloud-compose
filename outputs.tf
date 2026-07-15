output "cloud_provider" {
  value       = local.cloud_provider
  description = "Root entrypoint cloud provider (gcp)."
}

output "template" {
  value       = local.template_name
  description = "Selected compose template preset."
}

output "instance" {
  value       = module.gcp[0].instance
  description = "GCP VM instance details."
}

output "instance_id" {
  value       = module.gcp[0].instance_id
  description = "GCP VM instance ID."
}

output "external_ip" {
  value       = module.gcp[0].external_ip
  description = "GCP VM public IPv4 address."
}

output "internal_ip" {
  value       = module.gcp[0].internal_ip
  description = "GCP VM private IPv4 address."
}

output "network" {
  value       = module.gcp[0].network
  description = "Resolved GCP network and regional subnetwork."
}

output "volumes" {
  value       = module.gcp[0].volumes
  description = "GCP persistent application-data and Docker-volume details."
}

output "serviceGsa" {
  value       = module.gcp[0].serviceGsa
  description = "The Google Service Account internal services run as."
}

output "appGsa" {
  value       = module.gcp[0].appGsa
  description = "The Google Service Account the app can use for app-scoped auth."
}

output "urls" {
  value       = module.gcp[0].urls
  description = "Cloud Run ingress URLs by region."
}

output "backend" {
  value       = module.gcp[0].backend
  description = "Backend service ID for attaching Cloud Run ingress to an external HTTPS load balancer."
}

output "rollout" {
  value       = module.gcp[0].rollout
  description = "Optional rollout API endpoint details."
}

output "compose_projects" {
  value       = module.gcp[0].compose_projects
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value       = module.gcp[0].primary_compose_project
  description = "Normalized primary compose project."
}

output "sitectl_package_versions" {
  value       = module.gcp[0].sitectl_package_versions
  description = "Effective release selector for every installed sitectl package; values may be exact tags or latest."
}
