output "cloud_init" {
  value       = local.cloud_init
  description = "Rendered cloud-init user data."
}

output "compose_projects" {
  value       = local.compose_projects
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value       = local.primary_compose_project
  description = "Normalized primary compose project."
}

output "primary_compose_project_key" {
  value       = local.primary_compose_project_key
  description = "Primary compose project key."
}

output "sitectl_packages" {
  value       = local.sitectl_packages
  description = "Normalized sitectl package list."
}
