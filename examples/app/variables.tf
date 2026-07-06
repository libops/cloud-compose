variable "name" {
  type        = string
  default     = "cloud-compose-app"
  description = "Deployment name."
}

variable "template" {
  type        = string
  default     = "wp"
  description = "Compose template preset: archivesspace, ojs, isle, drupal, wp, omeka-s, or omeka-classic."
}

variable "digitalocean" {
  type        = any
  default     = {}
  description = "DigitalOcean provider settings passed to the provider module."
}

variable "runtime" {
  type        = any
  default     = {}
  description = "Provider-neutral runtime settings passed to the provider module."
}
