output "project_number" {
  description = "Numeric service project identifier used in Google-managed service-agent identities."
  value       = local.project_number
}

output "cloud_run_service_agent_email" {
  description = "Cloud Run service agent email derived from project_number."
  value       = google_project_service_identity.cloud_run.email
}

output "cloud_run_service_agent_member" {
  description = "Cloud Run service agent IAM member string."
  value       = google_project_service_identity.cloud_run.member
}

output "cloud_compose_start_role_name" {
  description = "Canonical project custom-role name for starting or resuming instances. The caller must provision it externally when manage_power_roles is false."
  value       = local.cloud_compose_start_role_name
}

output "cloud_compose_suspend_role_name" {
  description = "Canonical project custom-role name for suspending instances. The caller must provision it externally when manage_power_roles is false."
  value       = local.cloud_compose_suspend_role_name
}
