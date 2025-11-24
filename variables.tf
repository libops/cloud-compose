variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "project_number" {
  type        = string
  description = "The GCP project number"
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for resources"
  type        = string
  default     = "us-central1-f"
}

variable "name" {
  type        = string
  description = "The site name (will be the name of the GCP instance)"
}

variable "machine_type" {
  type        = string
  default     = "e2-medium"
  description = "VM machine type"
}

variable "disk_size_gb" {
  type        = number
  default     = 25
  description = "Data disk size in GB"
}

variable "os" {
  type        = string
  default     = "cos-125-19216-104-25"
  description = "The host OS to install on the GCP instance"
}

variable "docker_compose_repo" {
  type        = string
  description = "git repo to checkout that contains a docker compose project"
}

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "git branch to checkout for var.docker_compose_repo"
}

variable "docker_compose_init" {
  type        = string
  default     = ""
  description = "After cloning the docker compose git repo, any initialization that needs to happen before the docker compose project can start"
}

variable "docker_compose_up" {
  type        = string
  default     = "docker compose up --remove-orphans"
  description = "Command to start the docker compose project"
}

variable "docker_compose_down" {
  type        = string
  default     = "docker compose down"
  description = "Command to stop the docker compose project"
}

variable "allowed_ips" {
  type        = list(string)
  default     = []
  description = "CIDR IP Addresses allowed to turn on this site's GCP instance"
}

variable "allowed_ssh_ipv4" {
  type        = list(string)
  default     = []
  description = "CIDR IPv4 Addresses allowed to to SSH into this site's GCP instance"
}

variable "allowed_ssh_ipv6" {
  type        = list(string)
  default     = []
  description = "CIDR IPv6 Addresses allowed to SSH into this site's GCP instance"
}
