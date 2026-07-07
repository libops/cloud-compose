variable "healthcheck_interval" {
  type        = string
  description = "Interval passed to sitectl healthcheck on the VM and from the runner."
}

variable "healthcheck_timeout" {
  type        = string
  description = "Timeout passed to sitectl healthcheck."
}

variable "host" {
  type        = string
  description = "Remote host for smoke-test access."
}

variable "name" {
  type        = string
  description = "Generated smoke target name."
}

variable "primary_compose_project" {
  type = object({
    compose_project_name = string
    project_dir          = string
    sitectl_context_name = string
    sitectl_environment  = string
    sitectl_plugin       = string
  })
  description = "Normalized primary compose project from cloud-compose."
}

variable "cloud_provider" {
  type        = string
  description = "Cloud provider smoke target."
}

variable "template" {
  type        = string
  description = "Compose template smoke target."
}
