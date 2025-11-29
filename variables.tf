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
  default     = "us-east5"
}

variable "zone" {
  description = "GCP zone for resources"
  type        = string
  default     = "us-east5-b"
}

variable "name" {
  type        = string
  description = "The site name (will be the name of the GCP instance)"
}

variable "machine_type" {
  type        = string
  default     = "n4-standard-2"
  description = "VM machine type (General-purpose series that support Hyperdisk Balanced"

  validation {
    condition = contains([
      "n4-standard-2",
      "n4-standard-4",
      "n4-standard-8",
      "n4-standard-16",
      "n4-standard-32",
      "n4-standard-48",
      "n4-standard-64",
      "n4-standard-80",
      "c4-standard-2",
      "c4-standard-4",
      "c4-standard-8",
      "c4-standard-16",
      "c4-standard-32",
      "c4-standard-48",
      "c4-standard-96",
    ], var.machine_type)
    error_message = "The 'machine_type' must be from a General-Purpose family that supports Hyperdisk Balanced (C4, or N4 series)"
  }
}

variable "disk_size_gb" {
  type        = number
  default     = 50
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

variable "run_snapshots" {
  type        = bool
  default     = false
  description = "Enable daily snapshots of the data disk (recommended for production). Last seven days of snapshots are available. Also weekly snapshots for past year."
}

variable "overlay_source_instance" {
  type        = string
  default     = ""
  description = "Name of production instance to get latest snapshot from (e.g., 'ojs-production'). Terraform will automatically use the most recent snapshot from this instance's data disk. Leave empty for production environments."
}

variable "volume_names" {
  type        = list(string)
  default     = []
  description = "List of docker volumes to overlay from production snapshot (e.g., ['compose_ojs-public']). Production data is mounted read-only as lower layer, staging writes go to upper layer."
}
