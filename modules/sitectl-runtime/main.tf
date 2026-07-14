terraform {
  required_version = ">= 1.3.0"
}

locals {
  packages = distinct(concat(["sitectl"], var.packages))
  package_versions = {
    for package in local.packages :
    package => lookup(var.package_versions, package, var.fallback_version)
  }
  unknown_package_versions = setsubtract(
    toset(keys(var.package_versions)),
    toset(local.packages),
  )
}
