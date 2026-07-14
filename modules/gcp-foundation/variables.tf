variable "service_project_id" {
  description = "GCP project ID that owns the Cloud Run and Compute workloads."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]$", trimspace(var.service_project_id)))
    error_message = "service_project_id must be a valid lowercase GCP project ID; legacy domain-scoped prefixes are accepted."
  }
}

variable "host_project_id" {
  description = "Shared VPC host project ID. Leave empty when networking belongs to the service project."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition = (
      trimspace(var.host_project_id) == "" ||
      can(regex("^([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]$", trimspace(var.host_project_id)))
    )
    error_message = "host_project_id must be empty or a valid lowercase GCP project ID; legacy domain-scoped prefixes are accepted."
  }
}

variable "shared_vpc_subnetworks" {
  description = "Shared VPC subnets available to Cloud Run Direct VPC egress. At least one is required when host_project_id differs from service_project_id."
  type = set(object({
    name   = string
    region = string
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for subnet in var.shared_vpc_subnetworks :
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", trimspace(subnet.name))) &&
      can(regex("^[a-z]+(-[a-z0-9]+)+[0-9]$", trimspace(subnet.region)))
    ])
    error_message = "Each shared_vpc_subnetworks entry must contain a valid lowercase GCP subnet name and region such as us-east5."
  }
}

variable "manage_project_services" {
  description = "Whether this module enables the required Compute Engine, IAM, and Cloud Run APIs. Disable only when a separate foundation state manages them."
  type        = bool
  default     = true
  nullable    = false
}

variable "manage_power_roles" {
  description = "Whether this module creates the cloudComposeStart and cloudComposeSuspend project custom roles. Disable only when they are managed externally with the same permissions."
  type        = bool
  default     = true
  nullable    = false
}

variable "attach_shared_vpc" {
  description = "Whether to associate the service project with host_project_id as a Shared VPC service project. Leave false when that singleton association is managed elsewhere."
  type        = bool
  default     = false
  nullable    = false
}
