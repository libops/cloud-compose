terraform {
  required_version = ">= 1.3.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
  }
}
