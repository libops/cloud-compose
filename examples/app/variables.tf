variable "name" {
  type        = string
  default     = "cloud-compose-app"
  description = "Deployment name."
}

variable "cloud_provider" {
  type        = string
  default     = "digitalocean"
  description = "Cloud provider to deploy to: gcp, digitalocean, or linode."
}

variable "template" {
  type        = string
  default     = "wp"
  description = "Compose template preset: archivesspace, ojs, isle, drupal, wp, omeka-s, or omeka-classic."
}

variable "gcp" {
  type        = any
  default     = {}
  description = "GCP provider settings passed to the root module."
}

variable "digitalocean" {
  type        = any
  default     = {}
  description = "DigitalOcean provider settings passed to the root module."
}

variable "linode" {
  type        = any
  default     = {}
  description = "Linode provider settings passed to the root module."
}

variable "runtime" {
  type        = any
  default     = {}
  description = "Provider-neutral runtime settings passed to the root module."
}
