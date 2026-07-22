mock_provider "cloudinit" {}

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "mock-service-account@test-project.iam.gserviceaccount.com"
      id    = "projects/test-project/serviceAccounts/mock-service-account@test-project.iam.gserviceaccount.com"
      name  = "projects/test-project/serviceAccounts/mock-service-account@test-project.iam.gserviceaccount.com"
    }
  }

  mock_data "google_project" {
    defaults = {
      number = "123456789"
    }
  }
}

mock_provider "time" {}

variables {
  name                       = "gcp-cycle-contract"
  project_id                 = "test-project"
  project_number             = "123456789"
  docker_compose_repo        = "https://github.com/libops/wp.git"
  power_management_enabled   = true
  power_start_role           = "projects/test-project/roles/cloudComposeStart"
  power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
  allowed_ips                = ["198.51.100.25/32"]
  allowed_ip_forwarded_depth = 0
  vault_agent_enabled        = true
  vault_auth_method          = "gcp-iam"
  vault_addr                 = "https://vault.example"
  vault_role                 = "wordpress"
  disk_attachments = {
    mariadb-backups = {
      source = "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-east5-b/disks/mariadb-backups"
    }
  }
}

run "apply_power_managed_vault_baseline" {
  command = apply
}

run "plan_vm_replacement_while_retiring_vault_signer" {
  command = plan

  variables {
    vault_agent_enabled = false
  }

  plan_options {
    replace = [google_compute_instance.cloud-compose]
  }

  assert {
    condition = (
      length(google_compute_instance_iam_member.gce-start) == 1 &&
      length(google_compute_instance_iam_member.gce-suspend) == 1 &&
      google_compute_instance_iam_member.gce-start[0].instance_name == google_compute_instance.cloud-compose.name &&
      google_compute_instance_iam_member.gce-suspend[0].instance_name == google_compute_instance.cloud-compose.name &&
      one([
        for disk in google_compute_instance.cloud-compose.attached_disk : disk
        if disk.device_name == "mariadb-backups"
      ]).source == "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-east5-b/disks/mariadb-backups" &&
      one([
        for disk in google_compute_instance.cloud-compose.attached_disk : disk
        if disk.device_name == "mariadb-backups"
      ]).mode == "READ_WRITE"
    )
    error_message = "A VM replacement must retain instance-scoped power bindings and caller-owned disks without introducing an upgrade dependency cycle."
  }
}
