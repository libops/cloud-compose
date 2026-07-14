variable "name" {
  type        = string
  description = "Unique disposable deployment name."

  validation {
    condition     = can(regex("^cc-g-wp-[a-z0-9-]+$", var.name)) && length(var.name) <= 21
    error_message = "name must use the cc-g-wp smoke prefix and contain at most 21 characters."
  }
}

variable "gcp_project_id" {
  type        = string
  description = "Google Cloud project used for disposable upgrade resources."

  validation {
    condition     = trimspace(var.gcp_project_id) != ""
    error_message = "gcp_project_id is required."
  }
}

variable "gcp_network_project_id" {
  type        = string
  description = "Google Cloud project containing the persistent CI network. It must equal gcp_project_id because the 0.10.2 baseline predates Shared VPC support."

  validation {
    condition     = can(regex("^([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]$", trimspace(var.gcp_network_project_id)))
    error_message = "gcp_network_project_id must be a valid lowercase GCP project ID."
  }
}

variable "gcp_network_name" {
  type        = string
  description = "Existing persistent CI VPC network name or self link. The upgrade state never owns or deletes this network."

  validation {
    condition = (
      trimspace(var.gcp_network_name) != "" &&
      !startswith(basename(trimsuffix(trimspace(var.gcp_network_name), "/")), "cc-g-wp-")
    )
    error_message = "gcp_network_name is required and must not use the disposable cc-g-wp- prefix."
  }
}

variable "gcp_subnetwork_name" {
  type        = string
  description = "Existing persistent /26-or-larger regional CI subnet name or self link. Cloud Run Direct VPC allocations may outlive the disposable stack."

  validation {
    condition = (
      trimspace(var.gcp_subnetwork_name) != "" &&
      !startswith(basename(trimsuffix(trimspace(var.gcp_subnetwork_name), "/")), "cc-g-wp-")
    )
    error_message = "gcp_subnetwork_name is required and must not use the disposable cc-g-wp- prefix."
  }
}

variable "gcp_power_start_role" {
  type        = string
  description = "Full project- or organization-custom-role name used for the upgraded instance-scoped PPB start binding."

  validation {
    condition = can(regex(
      "^(projects/([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]|organizations/[0-9]+)/roles/[A-Za-z0-9_.]+$",
      trimspace(var.gcp_power_start_role),
    ))
    error_message = "gcp_power_start_role must be a full projects/.../roles/... or organizations/.../roles/... custom-role name."
  }
}

variable "gcp_power_suspend_role" {
  type        = string
  description = "Full project- or organization-custom-role name used for the upgraded instance-scoped suspend binding."

  validation {
    condition = can(regex(
      "^(projects/([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]|organizations/[0-9]+)/roles/[A-Za-z0-9_.]+$",
      trimspace(var.gcp_power_suspend_role),
    ))
    error_message = "gcp_power_suspend_role must be a full projects/.../roles/... or organizations/.../roles/... custom-role name."
  }
}

variable "gcp_region" {
  type        = string
  default     = "us-east5"
  description = "Google Cloud region for disposable upgrade resources."
}

variable "gcp_zone" {
  type        = string
  default     = "us-east5-b"
  description = "Google Cloud zone for disposable upgrade resources."
}

variable "ssh_public_key" {
  type        = string
  description = "Ephemeral CI SSH public key authorized on the disposable VM."

  validation {
    condition     = can(regex("^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key must be a supported OpenSSH public key."
  }
}

variable "runner_ipv4_cidr" {
  type        = string
  description = "Ephemeral GitHub runner public IPv4 address as a single-host /32 CIDR."

  validation {
    condition     = can(cidrnetmask(var.runner_ipv4_cidr)) && endswith(var.runner_ipv4_cidr, "/32")
    error_message = "runner_ipv4_cidr must be a valid IPv4 /32 CIDR."
  }
}

variable "legacy_baseline" {
  type        = bool
  default     = false
  description = "Use the supported legacy single-project inputs while provisioning the pinned 0.10.2 baseline. The current phase uses the explicit project map."
}

variable "wordpress_compose_ref" {
  type        = string
  default     = "5058610fddc7267ace92d65a5c49713dce570ac3"
  description = "Exact libops/wp commit shared by the baseline and current upgrade phases."

  validation {
    condition     = var.wordpress_compose_ref == "5058610fddc7267ace92d65a5c49713dce570ac3"
    error_message = "wordpress_compose_ref is intentionally pinned for a reproducible cross-version upgrade test."
  }
}
