terraform {
  required_version = ">= 1.2.4"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
  }
}
