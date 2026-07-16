output "cloud_provider" {
  value       = "linode"
  description = "Selected cloud provider."
}

output "template" {
  value       = local.template_name
  description = "Selected compose template preset."
}

output "instance" {
  value       = module.linode.instance
  description = "Selected provider VM instance details."
}

output "instance_id" {
  value       = module.linode.instance.id
  description = "Selected provider VM instance ID."
}

output "external_ip" {
  value       = module.linode.instance.public_ipv4
  description = "Selected provider VM public IPv4 address."
}

output "internal_ip" {
  value       = module.linode.instance.private_ip
  description = "Selected provider VM private IPv4 address."
}

output "network" {
  value       = null
  description = "GCP network details; always null for Linode."
}

output "volumes" {
  value       = module.linode.volumes
  description = "Selected provider persistent application-data and Docker-volume details."
}

output "serviceGsa" {
  value       = null
  description = "The Google Service Account internal services run as."
}

output "appGsa" {
  value       = null
  description = "The Google Service Account the app can use for app-scoped auth."
}

output "urls" {
  value       = {}
  description = "Cloud Run ingress URLs by region."
}

output "backend" {
  value       = null
  description = "Backend service ID for attaching Cloud Run ingress to an external HTTPS load balancer."
}

output "rollout" {
  value       = null
  description = "Optional rollout API endpoint details."
}

output "compose_projects" {
  value       = module.linode.compose_projects
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value       = module.linode.primary_compose_project
  description = "Normalized primary compose project."
}

output "sitectl_package_versions" {
  value       = module.linode.sitectl_package_versions
  description = "Effective release selector for every installed sitectl package; values may be exact tags or latest."
}
