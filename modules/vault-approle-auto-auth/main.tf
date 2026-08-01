terraform {
  required_version = ">= 1.5"
}

locals {
  config = <<-EOT
auto_auth {
  method "approle" {
    mount_path = ${jsonencode(var.mount_path)}
    config = {
      role_id_file_path                   = ${jsonencode(var.role_id_file_path)}
      secret_id_file_path                 = ${jsonencode(var.secret_id_file_path)}
      remove_secret_id_file_after_reading = true
    }
  }

  sink "file" {
    config = {
      path = ${jsonencode(var.token_sink_path)}
      mode = 0640
    }
  }
}
EOT
}
