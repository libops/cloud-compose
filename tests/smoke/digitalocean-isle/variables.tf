variable "name_prefix" {
  type        = string
  default     = "cc-do-isle"
  description = "Prefix for disposable smoke-test resources."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,35}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "region" {
  type        = string
  default     = "tor1"
  description = "DigitalOcean region slug."
}

variable "size" {
  type        = string
  default     = "s-4vcpu-8gb"
  description = "DigitalOcean Droplet size slug."
}

variable "image" {
  type        = string
  default     = "ubuntu-24-04-x64"
  description = "DigitalOcean Droplet image slug."
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
  description = "Additional SSH public keys authorized for the cloud-compose user during smoke tests."
}

variable "smoke_run_id" {
  type        = string
  default     = ""
  description = "Optional GitHub Actions run id used to tag and name disposable smoke-test resources."
}

variable "docker_compose_repo" {
  type        = string
  default     = "https://github.com/libops/isle"
  description = "ISLE compose template repository."
}

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "ISLE compose template branch."
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
  default     = "30m"
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
  description = "Extra DigitalOcean tags applied to smoke-test resources."
}
