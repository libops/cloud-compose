output "packages" {
  value       = local.packages
  description = "Normalized package list, always including sitectl."
}

output "package_versions" {
  value       = local.package_versions
  description = "Resolved release tag for every installed package."

  precondition {
    condition     = length(local.unknown_package_versions) == 0
    error_message = "package_versions contains packages that are not installed: ${join(", ", sort(tolist(local.unknown_package_versions)))}."
  }
}
