variable "role_id_file_path" {
  type        = string
  description = "Root-owned file containing the Vault AppRole role ID."
  validation {
    condition     = startswith(var.role_id_file_path, "/") && !strcontains(var.role_id_file_path, "\n")
    error_message = "role_id_file_path must be an absolute single-line path."
  }
}

variable "secret_id_file_path" {
  type        = string
  description = "Root-owned file containing a response-wrapped or short-lived AppRole secret ID, delivered out of band."
  validation {
    condition     = startswith(var.secret_id_file_path, "/") && !strcontains(var.secret_id_file_path, "\n")
    error_message = "secret_id_file_path must be an absolute single-line path."
  }
}

variable "token_sink_path" {
  type        = string
  default     = "/mnt/disks/data/vault/token"
  description = "Vault Agent token sink path."
  validation {
    condition     = startswith(var.token_sink_path, "/") && !strcontains(var.token_sink_path, "\n")
    error_message = "token_sink_path must be an absolute single-line path."
  }
}

variable "mount_path" {
  type        = string
  default     = "auth/approle"
  description = "Vault AppRole auth mount path."
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9/_-]*$", var.mount_path))
    error_message = "mount_path must be a relative Vault API path."
  }
}
