output "name" {
  value       = local.name
  description = "Generated smoke target name."
}

output "runtime" {
  value       = local.runtime_base
  description = "Provider-neutral runtime with template defaults and private fixture inputs resolved for hosted smoke tests."
}

output "gcp_runtime" {
  value       = local.gcp_runtime
  description = "GCP runtime overrides for smoke tests."
}

output "ssh_keys" {
  value       = local.ssh_keys
  description = "SSH public keys authorized for smoke-test access."
}

output "tags" {
  value       = local.tags
  description = "Provider tags for smoke-test resource cleanup."
}

output "template" {
  value       = local.template
  description = "Normalized smoke template."
}
