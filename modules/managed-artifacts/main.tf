terraform {
  required_version = ">= 1.3.0"
}

locals {
  artifacts_valid = alltrue([
    for artifact in var.artifacts :
    can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", artifact.name)) &&
    can(regex("^https://[^[:space:]]+$", artifact.url)) &&
    can(regex("^[0-9a-f]{64}$", artifact.sha256)) &&
    startswith(artifact.path, "/") &&
    artifact.path != "/" &&
    !can(regex("[\\x00-\\x1f\\x7f]", artifact.path)) &&
    alltrue([
      for segment in split("/", trimprefix(artifact.path, "/")) :
      segment != "" && segment != "." && segment != ".."
    ]) &&
    can(regex("^0?[0-7]{3}$", artifact.mode)) &&
    can(regex("^[a-z_][a-z0-9_-]{0,31}\\$?$", artifact.owner)) &&
    can(regex("^[a-z_][a-z0-9_-]{0,31}\\$?$", artifact.group)) &&
    (artifact.restart == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9_.@:-]*\\.service$", artifact.restart)))
  ])

  artifacts_unique = (
    length(distinct([for artifact in var.artifacts : artifact.name])) == length(var.artifacts) &&
    length(distinct([for artifact in var.artifacts : artifact.path])) == length(var.artifacts)
  )
}

output "artifacts" {
  value       = var.artifacts
  description = "Managed artifacts after enforcing the shared installation contract."

  precondition {
    condition     = local.artifacts_valid
    error_message = "Managed artifacts require a safe basename, HTTPS URL, lowercase SHA-256, non-root absolute path without dot/empty/control segments, octal mode, safe owner/group, and an optional safe .service restart unit."
  }

  precondition {
    condition     = local.artifacts_unique
    error_message = "Managed artifact names and target paths must be unique."
  }
}
