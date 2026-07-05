output "cloud_provider" {
  value       = local.cloud_provider
  description = "Selected cloud provider."
}

output "template" {
  value       = local.template_name
  description = "Selected compose template preset."
}

output "instance" {
  value = try(
    module.gcp[0].instance,
    module.digitalocean[0].instance,
    module.linode[0].instance,
    null,
  )
  description = "Selected provider VM instance details."
}

output "instance_id" {
  value = try(
    module.gcp[0].instance_id,
    module.digitalocean[0].instance.id,
    module.linode[0].instance.id,
    null,
  )
  description = "Selected provider VM instance ID."
}

output "external_ip" {
  value = try(
    module.gcp[0].external_ip,
    module.digitalocean[0].instance.ipv4,
    module.linode[0].instance.public_ipv4,
    null,
  )
  description = "Selected provider VM public IPv4 address."
}

output "internal_ip" {
  value = try(
    module.gcp[0].internal_ip,
    module.digitalocean[0].instance.private_ip,
    module.linode[0].instance.private_ip,
    null,
  )
  description = "Selected provider VM private IPv4 address."
}

output "volumes" {
  value = try(
    module.digitalocean[0].volumes,
    module.linode[0].volumes,
    null,
  )
  description = "Selected provider persistent volume details where available."
}

output "serviceGsa" {
  value       = try(module.gcp[0].serviceGsa, null)
  description = "The Google Service Account internal services run as."
}

output "appGsa" {
  value       = try(module.gcp[0].appGsa, null)
  description = "The Google Service Account the app can use for app-scoped auth."
}

output "urls" {
  value       = try(module.gcp[0].urls, {})
  description = "Cloud Run ingress URLs by region."
}

output "backend" {
  value       = try(module.gcp[0].backend, null)
  description = "Backend service ID for attaching Cloud Run ingress to an external HTTPS load balancer."
}

output "rollout" {
  value       = try(module.gcp[0].rollout, null)
  description = "Optional rollout API endpoint details."
}

output "compose_projects" {
  value = try(
    module.gcp[0].compose_projects,
    module.digitalocean[0].compose_projects,
    module.linode[0].compose_projects,
    {},
  )
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value = try(
    module.gcp[0].primary_compose_project,
    module.digitalocean[0].primary_compose_project,
    module.linode[0].primary_compose_project,
    null,
  )
  description = "Normalized primary compose project."
}
