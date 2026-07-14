variable "env" {
  type        = map(string)
  description = "Trusted host-control values rendered as non-executable dotenv data for the strict profile.sh loader."

  validation {
    condition = alltrue([
      for name in keys(var.env) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name))
    ])
    error_message = "Environment variable names must match ^[A-Za-z_][A-Za-z0-9_]*$."
  }
}
