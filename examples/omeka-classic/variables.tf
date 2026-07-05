variable "name" {
  type        = string
  default     = "omeka-classic-example"
  description = "Deployment name."
}

variable "cloud_provider" {
  type        = string
  default     = "digitalocean"
  description = "Cloud provider to deploy to: gcp, digitalocean, or linode."
}

variable "gcp" {
  type        = any
  default     = {}
  description = "GCP provider settings passed to the app example."
}

variable "digitalocean" {
  type        = any
  default     = {}
  description = "DigitalOcean provider settings passed to the app example."
}

variable "linode" {
  type        = any
  default     = {}
  description = "Linode provider settings passed to the app example."
}

variable "runtime" {
  type        = any
  default     = {}
  description = "Provider-neutral runtime settings passed to the app example."
}
