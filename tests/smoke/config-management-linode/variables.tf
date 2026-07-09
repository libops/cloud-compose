variable "method" {
  type        = string
  description = "Config management method under test."

  validation {
    condition     = contains(["ansible", "salt"], lower(trimspace(var.method)))
    error_message = "method must be ansible or salt."
  }
}

variable "template" {
  type        = string
  default     = "drupal"
  description = "Compose template smoke target."

  validation {
    condition     = lower(trimspace(var.template)) == "drupal"
    error_message = "The raw Linode config-management smoke currently supports the drupal template."
  }
}

variable "linode_region" {
  type        = string
  default     = "us-east"
  description = "Linode region slug."
}

variable "linode_type" {
  type        = string
  default     = "g6-standard-2"
  description = "Linode instance type."
}

variable "linode_image" {
  type        = string
  default     = "linode/ubuntu22.04"
  description = "Linode image slug."
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
  type        = list(string)
  default     = []
  description = "Additional SSH public keys authorized for operator access during smoke tests."
}

variable "smoke_run_id" {
  type        = string
  default     = ""
  description = "Optional GitHub Actions run id used to tag and name disposable smoke-test resources."
}

variable "tags" {
  type        = list(string)
  default     = ["cloud-compose"]
  description = "Extra provider tags applied to smoke-test resources."
}

variable "ssh_source_ipv4" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "IPv4 CIDRs allowed to SSH to the smoke host."
}

variable "ssh_source_ipv6" {
  type        = list(string)
  default     = ["::/0"]
  description = "IPv6 CIDRs allowed to SSH to the smoke host."
}

variable "web_source_ipv4" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "IPv4 CIDRs allowed to reach app HTTP/HTTPS ports."
}

variable "web_source_ipv6" {
  type        = list(string)
  default     = ["::/0"]
  description = "IPv6 CIDRs allowed to reach app HTTP/HTTPS ports."
}
