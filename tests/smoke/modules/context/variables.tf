variable "cloud_provider" {
  type        = string
  description = "Cloud provider smoke target."

  validation {
    condition     = contains(["digitalocean", "gcp", "linode"], lower(trimspace(var.cloud_provider)))
    error_message = "cloud_provider must be digitalocean, gcp, or linode."
  }
}

variable "template" {
  type        = string
  description = "Compose template smoke target."

  validation {
    condition     = contains(["archivesspace", "ojs", "isle", "drupal", "wp", "omeka-s", "omeka-classic"], lower(trimspace(var.template)))
    error_message = "template must be archivesspace, ojs, isle, drupal, wp, omeka-s, or omeka-classic."
  }
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
  type        = list(string)
  default     = []
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

variable "rootfs_archive_url" {
  type        = string
  default     = ""
  description = "Optional cloud-compose rootfs archive URL for providers with metadata size limits."
}

variable "tags" {
  type        = list(string)
  default     = ["cloud-compose"]
  description = "Extra provider tags applied to smoke-test resources."
}
