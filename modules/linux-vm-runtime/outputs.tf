output "cloud_init" {
  value       = local.cloud_init
  description = "Rendered cloud-init user data."

  precondition {
    condition = (
      (local.rootfs_archive_url == "") == (local.rootfs_archive_sha256 == "") &&
      (local.rootfs_archive_sha256 == "" || can(regex("^[0-9a-f]{64}$", local.rootfs_archive_sha256)))
    )
    error_message = "rootfs_archive_url and a 64-character rootfs_archive_sha256 must be supplied together."
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
