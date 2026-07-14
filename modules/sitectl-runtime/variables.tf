variable "packages" {
  type        = list(string)
  default     = ["sitectl"]
  description = "sitectl release package names installed on the host."

  validation {
    condition = alltrue([
      for package in var.packages :
      can(regex("^sitectl(-[a-z0-9]+)*$", package))
    ])
    error_message = "packages entries must be release package names such as sitectl, sitectl-isle, or sitectl-wp."
  }
}

variable "fallback_version" {
  type        = string
  default     = "latest"
  description = "Legacy fallback release tag for packages without a package_versions override."

  validation {
    condition = (
      var.fallback_version == "latest" ||
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", var.fallback_version))
    )
    error_message = "fallback_version must be latest or an exact semantic-version release tag such as v0.38.0 or v0.39.0-rc.1."
  }
}

variable "package_versions" {
  type        = map(string)
  default     = {}
  description = "Per-package release tags. Entries override version for the named package."

  validation {
    condition = alltrue([
      for package, version in var.package_versions :
      can(regex("^sitectl(-[a-z0-9]+)*$", package)) && (
        version == "latest" ||
        can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", version))
      )
    ])
    error_message = "package_versions keys must be sitectl package names and values must be latest or exact semantic-version release tags."
  }
}
