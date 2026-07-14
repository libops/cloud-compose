mock_provider "google" {
  mock_data "google_project" {
    override_during = plan
    defaults = {
      number = "123456789012"
    }
  }
}

mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    override_during = plan
    defaults = {
      email  = "service-123456789012@serverless-robot-prod.iam.gserviceaccount.com"
      member = "serviceAccount:service-123456789012@serverless-robot-prod.iam.gserviceaccount.com"
    }
  }
}

run "creates_long_lived_service_and_role_foundation" {
  command = plan

  variables {
    service_project_id = "service-project"
  }

  assert {
    condition = (
      toset(keys(google_project_service.required)) == toset([
        "cloudresourcemanager.googleapis.com",
        "compute.googleapis.com",
        "iam.googleapis.com",
        "iamcredentials.googleapis.com",
        "logging.googleapis.com",
        "monitoring.googleapis.com",
        "run.googleapis.com",
      ]) &&
      alltrue([
        for name, service in google_project_service.required :
        service.project == "service-project" && service.service == name
      ])
    )
    error_message = "The default foundation must manage exactly the Cloud Resource Manager, Compute Engine, IAM, IAM Credentials, Logging, Monitoring, and Cloud Run APIs."
  }

  assert {
    condition = alltrue([
      for service in google_project_service.required :
      !service.disable_on_destroy && service.deletion_policy == "ABANDON"
    ])
    error_message = "Required APIs must remain enabled and be abandoned instead of disabled during state removal."
  }

  assert {
    condition = (
      length(google_project_iam_custom_role.cloud_compose_start) == 1 &&
      google_project_iam_custom_role.cloud_compose_start[0].project == "service-project" &&
      google_project_iam_custom_role.cloud_compose_start[0].role_id == "cloudComposeStart" &&
      google_project_iam_custom_role.cloud_compose_start[0].deletion_policy == "PREVENT" &&
      toset(google_project_iam_custom_role.cloud_compose_start[0].permissions) == toset([
        "compute.instances.get",
        "compute.instances.resume",
        "compute.instances.start",
      ])
    )
    error_message = "cloudComposeStart must be long-lived and limited to get, resume, and start."
  }

  assert {
    condition = (
      length(google_project_iam_custom_role.cloud_compose_suspend) == 1 &&
      google_project_iam_custom_role.cloud_compose_suspend[0].project == "service-project" &&
      google_project_iam_custom_role.cloud_compose_suspend[0].role_id == "cloudComposeSuspend" &&
      google_project_iam_custom_role.cloud_compose_suspend[0].deletion_policy == "PREVENT" &&
      toset(google_project_iam_custom_role.cloud_compose_suspend[0].permissions) == toset([
        "compute.instances.get",
        "compute.instances.suspend",
      ])
    )
    error_message = "cloudComposeSuspend must be long-lived and limited to get and suspend."
  }

  assert {
    condition = (
      output.cloud_run_service_agent_email == "service-123456789012@serverless-robot-prod.iam.gserviceaccount.com" &&
      output.cloud_run_service_agent_member == "serviceAccount:service-123456789012@serverless-robot-prod.iam.gserviceaccount.com" &&
      output.cloud_compose_start_role_name == "projects/service-project/roles/cloudComposeStart" &&
      output.cloud_compose_suspend_role_name == "projects/service-project/roles/cloudComposeSuspend"
    )
    error_message = "Foundation service-agent and role outputs must use canonical project-derived names."
  }


  assert {
    condition = (
      google_project_service_identity.cloud_run.project == "service-project" &&
      google_project_service_identity.cloud_run.service == "run.googleapis.com" &&
      google_project_iam_member.cloud_run_service_agent.project == "service-project" &&
      google_project_iam_member.cloud_run_service_agent.role == "roles/run.serviceAgent" &&
      google_project_iam_member.cloud_run_service_agent.member == output.cloud_run_service_agent_member
    )
    error_message = "The foundation must explicitly materialize the Cloud Run service agent and restore its documented service-project role before granting network IAM."
  }

  assert {
    condition = (
      length(google_compute_shared_vpc_service_project.attachment) == 0 &&
      length(google_project_iam_member.cloud_run_network_viewer) == 0 &&
      length(google_compute_subnetwork_iam_member.cloud_run_network_user) == 0
    )
    error_message = "Same-project networking must not create Shared VPC attachment or cross-project IAM resources."
  }
}

run "configures_explicit_shared_vpc_access" {
  command = plan

  variables {
    service_project_id = "service-project"
    host_project_id    = "network-host-project"
    shared_vpc_subnetworks = [
      {
        name   = "cloud-run-egress"
        region = "us-east5"
      },
      {
        name   = "cloud-run-egress-west"
        region = "us-west1"
      },
    ]
    attach_shared_vpc = true
  }

  assert {
    condition = (
      length(google_compute_shared_vpc_service_project.attachment) == 1 &&
      google_compute_shared_vpc_service_project.attachment[0].host_project == "network-host-project" &&
      google_compute_shared_vpc_service_project.attachment[0].service_project == "service-project" &&
      google_compute_shared_vpc_service_project.attachment[0].deletion_policy == "ABANDON"
    )
    error_message = "The optional Shared VPC attachment must be explicit and abandoned rather than detached on state removal."
  }

  assert {
    condition = (
      length(google_project_iam_member.cloud_run_network_viewer) == 1 &&
      google_project_iam_member.cloud_run_network_viewer[0].project == "network-host-project" &&
      google_project_iam_member.cloud_run_network_viewer[0].role == "roles/compute.networkViewer" &&
      google_project_iam_member.cloud_run_network_viewer[0].member == output.cloud_run_service_agent_member
    )
    error_message = "Cloud Run must receive Compute Network Viewer only at the Shared VPC host project."
  }

  assert {
    condition = (
      length(google_compute_subnetwork_iam_member.cloud_run_network_user) == 2 &&
      alltrue([
        for key, binding in google_compute_subnetwork_iam_member.cloud_run_network_user :
        binding.project == "network-host-project" &&
        binding.role == "roles/compute.networkUser" &&
        binding.member == output.cloud_run_service_agent_member &&
        key == "${binding.region}/${binding.subnetwork}"
      ])
    )
    error_message = "Cloud Run Network User must be scoped to the explicit regional Shared VPC subnet."
  }
}

run "supports_an_externally_managed_shared_vpc_attachment" {
  command = plan

  variables {
    service_project_id = "service-project"
    host_project_id    = "network-host-project"
    shared_vpc_subnetworks = [{
      name   = "cloud-run-egress"
      region = "us-east5"
    }]
    attach_shared_vpc = false
  }

  assert {
    condition = (
      length(google_compute_shared_vpc_service_project.attachment) == 0 &&
      length(google_project_iam_member.cloud_run_network_viewer) == 1 &&
      length(google_compute_subnetwork_iam_member.cloud_run_network_user) == 1
    )
    error_message = "An externally managed Shared VPC association must still receive the required Cloud Run host and subnet grants."
  }
}

run "supports_externally_managed_services_and_roles" {
  command = plan

  variables {
    service_project_id      = "service-project"
    manage_project_services = false
    manage_power_roles      = false
  }

  assert {
    condition = (
      length(google_project_service.required) == 0 &&
      length(google_project_iam_custom_role.cloud_compose_start) == 0 &&
      length(google_project_iam_custom_role.cloud_compose_suspend) == 0 &&
      output.cloud_compose_start_role_name == "projects/service-project/roles/cloudComposeStart" &&
      output.cloud_compose_suspend_role_name == "projects/service-project/roles/cloudComposeSuspend"
    )
    error_message = "External ownership must suppress singleton resources while preserving canonical role references."
  }
}

run "supports_legacy_domain_scoped_project_ids" {
  command = plan

  variables {
    service_project_id = "example.com:service-project"
  }

  assert {
    condition = (
      output.cloud_compose_start_role_name == "projects/example.com:service-project/roles/cloudComposeStart" &&
      output.cloud_compose_suspend_role_name == "projects/example.com:service-project/roles/cloudComposeSuspend"
    )
    error_message = "Legacy domain-scoped project IDs must produce valid canonical custom-role names."
  }
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    service_project_id = "INVALID_PROJECT"
  }

  expect_failures = [var.service_project_id]
}

run "requires_explicit_shared_vpc_subnet" {
  command = plan

  variables {
    service_project_id = "service-project"
    host_project_id    = "network-host-project"
  }

  expect_failures = [data.google_project.service]
}

run "rejects_same_project_attachment" {
  command = plan

  variables {
    service_project_id = "service-project"
    host_project_id    = "service-project"
    attach_shared_vpc  = true
  }

  expect_failures = [data.google_project.service]
}

run "rejects_invalid_shared_vpc_subnetwork" {
  command = plan

  variables {
    service_project_id = "service-project"
    shared_vpc_subnetworks = [{
      name   = "Invalid_Subnet"
      region = "US_EAST5"
    }]
  }

  expect_failures = [var.shared_vpc_subnetworks]
}
