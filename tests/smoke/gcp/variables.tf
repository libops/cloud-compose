variable "template" {
  type        = string
  default     = "wp"
  description = "Compose template smoke target."

  validation {
    condition     = contains(["archivesspace", "ojs", "isle", "drupal", "wp", "omeka-s", "omeka-classic"], lower(trimspace(var.template)))
    error_message = "template must be archivesspace, ojs, isle, drupal, wp, omeka-s, or omeka-classic."
  }
}

variable "gcp_project_id" {
  type        = string
  default     = ""
  description = "Google Cloud project used for disposable smoke-test resources."
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

variable "gcp_machine_type" {
  type        = string
  default     = "e2-medium"
  description = "Google Compute Engine machine type."
}

variable "gcp_disk_type" {
  type        = string
  default     = "pd-standard"
  description = "Google Compute Engine disk type."
}

variable "gcp_os" {
  type        = string
  default     = "cos-125-19216-220-185"
  description = "Compute-optimized OS image name."
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key authorized for smoke-test access."

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

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "Compose template branch."
}

variable "ingress_port" {
  type        = number
  default     = 80
  description = "Host port exposed by Traefik."
}

variable "docker_volumes_volume_size_gb" {
  type        = number
  default     = 30
  description = "Disposable smoke-test Docker volumes volume size."
}

variable "healthcheck_timeout" {
  type        = string
  default     = ""
  description = "Timeout passed to sitectl healthcheck. Empty chooses a template-specific default."
}

variable "healthcheck_interval" {
  type        = string
  default     = "20s"
  description = "Interval passed to sitectl healthcheck on the VM and from the runner."
}
