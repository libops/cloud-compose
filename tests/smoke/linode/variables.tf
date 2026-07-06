variable "template" {
  type        = string
  default     = "wp"
  description = "Compose template smoke target."

  validation {
    condition     = contains(["archivesspace", "ojs", "isle", "drupal", "wp", "omeka-s", "omeka-classic"], lower(trimspace(var.template)))
    error_message = "template must be archivesspace, ojs, isle, drupal, wp, omeka-s, or omeka-classic."
  }
}

variable "linode_region" {
  type        = string
  default     = "us-east"
  description = "Linode region slug."
}

variable "linode_type" {
  type        = string
  default     = "g6-standard-2"
  description = "Linode instance type."
}

variable "linode_image" {
  type        = string
  default     = "linode/ubuntu22.04"
  description = "Linode image slug."
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

variable "data_volume_size_gb" {
  type        = number
  default     = 10
  description = "Disposable smoke-test data volume size."
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

variable "tags" {
  type        = list(string)
  default     = ["cloud-compose"]
  description = "Extra provider tags applied to smoke-test resources."
}

variable "cloud_compose_source_ref" {
  type        = string
  default     = "main"
  description = "cloud-compose Git ref whose rootfs is fetched by providers with metadata size limits."
}
