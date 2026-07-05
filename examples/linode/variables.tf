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
  default     = "main"
  description = "cloud-compose Git ref whose rootfs is fetched by Linode cloud-init."
}

variable "docker_compose_repo" {
  type        = string
  default     = "https://github.com/libops/drupal.git"
  description = "Compose project repository."
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
