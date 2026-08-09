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

variable "tags" {
  type        = list(string)
  default     = ["cloud-compose"]
  description = "Extra provider tags applied to smoke-test resources."
}

variable "cloud_compose_source_ref" {
  type        = string
  description = "Exact lowercase cloud-compose commit whose source archive is fetched by providers with metadata size limits."

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.cloud_compose_source_ref))
    error_message = "cloud_compose_source_ref must be an exact lowercase 40-character commit SHA."
  }
}

variable "cloud_compose_source_sha256" {
  type        = string
  description = "SHA-256 of the cloud-compose source archive selected by cloud_compose_source_ref."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", trimspace(var.cloud_compose_source_sha256)))
    error_message = "cloud_compose_source_sha256 must be a 64-character SHA-256 digest."
  }
}
