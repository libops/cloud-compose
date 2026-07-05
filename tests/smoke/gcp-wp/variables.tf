variable "name_prefix" {
  type        = string
  default     = "cc-gwp"
  description = "Prefix for disposable smoke-test resources."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,8}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter, contain only lowercase letters, numbers, and hyphens, and leave room for service account prefixes."
  }
}

variable "gcp_project_id" {
  type        = string
  description = "Google Cloud project used for disposable smoke-test resources."

  validation {
    condition     = trimspace(var.gcp_project_id) != ""
    error_message = "gcp_project_id is required."
  }
}

variable "gcp_region" {
  type        = string
  default     = "us-east5"
  description = "Google Cloud region for smoke-test resources."
}

variable "gcp_zone" {
  type        = string
  default     = "us-east5-b"
  description = "Google Cloud zone for smoke-test resources."
}

variable "machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Google Compute Engine machine type."
}

variable "disk_type" {
  type        = string
  default     = "pd-standard"
  description = "Google Compute Engine disk type."
}

variable "os" {
  type        = string
  default     = "cos-125-19216-220-185"
  description = "Compute-optimized OS image name."
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key authorized for the cloud-compose user."

  validation {
    condition     = trimspace(var.ssh_public_key) != ""
    error_message = "ssh_public_key is required."
  }
}

variable "operator_ssh_public_keys" {
  type = list(string)
  default = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOuUgUvvcJyWVZkgLrBGGI9RfcNmQsw32QNftNS5/Iiv jcorall@MacBookPro"
  ]
  description = "Additional SSH public keys authorized for operator access during smoke tests."
}

variable "ssh_source_ranges" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR IPv4 ranges allowed to SSH into the disposable smoke-test VM."
}

variable "smoke_run_id" {
  type        = string
  default     = ""
  description = "Optional GitHub Actions run id used to tag and name disposable smoke-test resources."
}

variable "docker_compose_repo" {
  type        = string
  default     = "https://github.com/libops/wp.git"
  description = "WordPress compose template repository."
}

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "WordPress compose template branch."
}

variable "ingress_port" {
  type        = number
  default     = 80
  description = "Host port exposed by Traefik."
}

variable "docker_volumes_volume_size_gb" {
  type        = number
  default     = 50
  description = "Persistent Docker volumes disk size."
}

variable "healthcheck_timeout" {
  type        = string
  default     = "20m"
  description = "Timeout passed to sitectl healthcheck on the VM and from the runner."
}

variable "healthcheck_interval" {
  type        = string
  default     = "20s"
  description = "Interval passed to sitectl healthcheck on the VM and from the runner."
}
