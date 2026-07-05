output "instance" {
  value       = module.gcp.instance
  description = "The Google Compute instance ID, name, zone, data disk, and GSA."
}

output "instance_id" {
  value       = module.gcp.instance_id
  description = "The Google Compute instance ID."
}

output "external_ip" {
  value       = module.gcp.external_ip
  description = "The Google Compute instance external IPv4 address."
}

output "internal_ip" {
  value       = module.gcp.internal_ip
  description = "The Google Compute instance internal IPv4 address."
}

output "serviceGsa" {
  value       = module.gcp.serviceGsa
  description = "The Google Service Account internal services run as."
}

output "appGsa" {
  value       = module.gcp.appGsa
  description = "The Google Service Account the app can use for app-scoped auth."
}

output "urls" {
  value       = module.gcp.urls
  description = "Cloud Run ingress URLs by region."
}

output "backend" {
  value       = module.gcp.backend
  description = "Backend service ID for attaching Cloud Run ingress to an external HTTPS load balancer."
}

output "rollout" {
  value       = module.gcp.rollout
  description = "Optional rollout API endpoint details."
}

output "compose_projects" {
  value       = module.gcp.compose_projects
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value       = module.gcp.primary_compose_project
  description = "Normalized primary compose project."
}
