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

variable "docker_compose_repo" {
  type        = string
  description = "git repo to checkout that contains a docker compose project"
}

variable "docker_compose_init" {
  type        = string
  default     = ""
  description = "After cloning the docker compose git repo, any initialization that needs to happen before the docker compose project can start"
}

variable "allowed_ips" {
  type        = list(string)
  default     = []
  description = "CIDR IP Addresses allowed to turn on this site's GCP instance"
}
