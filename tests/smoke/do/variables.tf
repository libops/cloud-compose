variable "template" {
  type        = string
  default     = "wp"
  description = "Compose template smoke target."

  validation {
    condition     = contains(["archivesspace", "ojs", "isle", "drupal", "wp", "omeka-s", "omeka-classic"], lower(trimspace(var.template)))
    error_message = "template must be archivesspace, ojs, isle, drupal, wp, omeka-s, or omeka-classic."
  }
}

variable "digitalocean_region" {
  type        = string
  default     = "tor1"
  description = "DigitalOcean region slug."
}

variable "digitalocean_size" {
  type        = string
  default     = "s-4vcpu-8gb"
  description = "DigitalOcean Droplet size slug."
}

variable "digitalocean_image" {
  type        = string
  default     = "ubuntu-24-04-x64"
  description = "DigitalOcean Droplet image slug."
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
  default     = "main"
  description = "cloud-compose Git ref whose rootfs is fetched to keep DigitalOcean user_data below 64 KiB."
}

variable "cloud_compose_source_sha256" {
  type        = string
  description = "SHA-256 of the cloud-compose source archive selected by cloud_compose_source_ref."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", trimspace(var.cloud_compose_source_sha256)))
    error_message = "cloud_compose_source_sha256 must be a 64-character SHA-256 digest."
  }
}
