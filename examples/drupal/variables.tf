variable "name" {
  type        = string
  default     = "drupal-example"
  description = "Deployment name."
}

variable "digitalocean" {
  type        = any
  default     = {}
  description = "DigitalOcean provider settings passed to the app example provider module."
}

variable "runtime" {
  type        = any
  default     = {}
  description = "Provider-neutral runtime settings passed to the app example."
}
