variable "name" {
  type        = string
  default     = "cc-drupal"
  description = "Deployment name."
}

variable "region" {
  type        = string
  default     = "us-east"
  description = "Linode region slug."
}

variable "type" {
  type        = string
  default     = "g6-standard-2"
  description = "Linode instance type."
}

variable "authorized_keys" {
  type        = list(string)
  default     = []
  description = "SSH public keys for the root account."
}

variable "authorized_users" {
  type        = list(string)
  default     = []
  description = "Linode users whose SSH keys are added to the root account."
}

variable "root_pass" {
  type        = string
  default     = null
  sensitive   = true
  description = "Optional root password. Provide this or authorized_keys/authorized_users."
}

variable "cloud_compose_ssh_keys" {
  type        = list(string)
  default     = []
  description = "SSH public keys for the cloud-compose user."
}

variable "cloud_compose_source_ref" {
  type        = string
  default     = "1.0.0"
  description = "Exact cloud-compose release tag whose canonical rootfs asset is fetched by Linode cloud-init."

  validation {
    condition     = can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+$", trimspace(var.cloud_compose_source_ref)))
    error_message = "cloud_compose_source_ref must be an exact semantic-version release tag."
  }
}

variable "cloud_compose_source_sha256" {
  type        = string
  description = "SHA-256 of the canonical rootfs asset published for cloud_compose_source_ref."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", trimspace(var.cloud_compose_source_sha256)))
    error_message = "cloud_compose_source_sha256 must be a 64-character SHA-256 digest."
  }
}

variable "docker_compose_repo" {
  type        = string
  default     = ""
  description = "Optional compose project repository override. Empty uses the selected template default."
}

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "Compose project branch."
}

variable "ingress_port" {
  type        = number
  default     = 80
  description = "Host port exposed by the compose project."
}
