output "cloud_init" {
  value       = local.cloud_init
  description = "Rendered cloud-init user data."

  precondition {
    condition     = length(local.cloud_init) <= 65535
    error_message = "Rendered Cloud Compose user data exceeds the 65,535-byte provider limit; move implementation into sitectl or external documentation."
  }
}

output "compose_projects" {
  value       = local.validated_compose_projects
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
  value       = module.sitectl_runtime.packages
  description = "Normalized sitectl package list."
}

output "sitectl_package_versions" {
  value       = module.sitectl_runtime.package_versions
  description = "Effective release selector for every installed sitectl package; values may be exact tags or latest."
}
