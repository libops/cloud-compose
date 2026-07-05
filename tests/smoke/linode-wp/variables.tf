variable "name_prefix" {
  type        = string
  default     = "cc-linode-wp"
  description = "Prefix for disposable smoke-test resources."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,35}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens."
  }
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

variable "image" {
  type        = string
  default     = "linode/ubuntu22.04"
  description = "Linode image slug."
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key authorized for the root and cloud-compose users."

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

variable "data_volume_size_gb" {
  type        = number
  default     = 10
  description = "Disposable smoke-test data volume size."
}

variable "docker_volumes_volume_size_gb" {
  type        = number
  default     = 20
  description = "Disposable smoke-test Docker volumes volume size."
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

variable "tags" {
  type        = list(string)
  default     = ["cloud-compose"]
  description = "Extra Linode tags applied to smoke-test resources."
}

variable "cloud_compose_source_ref" {
  type        = string
  default     = "main"
  description = "cloud-compose Git ref whose rootfs is fetched by Linode cloud-init."
}
