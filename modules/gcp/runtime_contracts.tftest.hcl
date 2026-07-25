mock_provider "cloudinit" {}
mock_provider "google" {
  mock_resource "google_compute_disk" {
    override_during = plan
    defaults = {
      disk_id = "987654321012345678"
    }
  }
  mock_resource "google_service_account" {
    override_during = plan
    defaults = {
      email = "mock-service-account@test-project.iam.gserviceaccount.com"
      id    = "projects/test-project/serviceAccounts/mock-service-account@test-project.iam.gserviceaccount.com"
      name  = "projects/test-project/serviceAccounts/mock-service-account@test-project.iam.gserviceaccount.com"
    }
  }
  mock_data "google_compute_network" {
    defaults = {
      name      = "existing-network"
      self_link = "https://www.googleapis.com/compute/v1/projects/network-project/global/networks/existing-network"
    }
  }
  mock_data "google_compute_subnetwork" {
    defaults = {
      name          = "existing-network"
      self_link     = "https://www.googleapis.com/compute/v1/projects/network-project/regions/us-east5/subnetworks/existing-network"
      network       = "https://www.googleapis.com/compute/v1/projects/network-project/global/networks/existing-network"
      ip_cidr_range = "10.50.0.0/24"
    }
  }
  mock_data "google_project" {
    defaults = {
      number = "123456789"
    }
  }
  mock_data "google_service_account" {
    defaults = {
      email = "existing@test-project.iam.gserviceaccount.com"
      name  = "projects/test-project/serviceAccounts/existing@test-project.iam.gserviceaccount.com"
    }
  }
}
mock_provider "time" {}

run "disables_privileged_services_by_default" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    project_number      = "123456789"
    docker_compose_repo = "https://github.com/libops/wp.git"
  }

  assert {
    condition     = length(google_service_account.internal-services) == 0
    error_message = "The internal-services identity must not exist by default."
  }

  assert {
    condition     = length(module.ppb) == 0
    error_message = "The power-button module must not exist by default."
  }

  assert {
    condition     = output.serviceGsa == null
    error_message = "serviceGsa must be null while privileged services are disabled."
  }

  assert {
    condition     = length(google_service_account_iam_member.vault_agent_jwt_signer_policy) == 0
    error_message = "An inactive Vault Agent must not grant the app identity token-signing permission."
  }

  assert {
    condition = (
      length(google_service_account_iam_member.app-keys) == 0 &&
      local.host_env.GCP_APP_CREDENTIALS_ENABLED == "false"
    )
    error_message = "User-managed app credentials must be disabled by default."
  }

  assert {
    condition     = local.host_env.GCP_PROJECT_NUMBER == "123456789"
    error_message = "The runtime project number must come from project_id discovery, not the deprecated caller assertion."
  }

  assert {
    condition = (
      local.host_env.CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY == "v1:gcp-disk-id:987654321012345678" &&
      strcontains(
        local.cloud_init_yaml,
        "--publish-fresh-marker \"v1:gcp-disk-id:987654321012345678\"",
      )
    )
    error_message = "GCP cloud-init and the root runtime environment must carry the same immutable data-disk identity."
  }

  assert {
    condition = (
      google_project_iam_member.log.member == "serviceAccount:${local.vm_service_account_email}" &&
      google_project_iam_member.monitoring.member == "serviceAccount:${local.vm_service_account_email}"
    )
    error_message = "The VM identity must receive both host logging and monitoring writer roles."
  }
}

run "sizes_application_data_independently" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    data_disk_size_gb   = 170
    disk_size_gb        = 50
  }

  assert {
    condition = (
      google_compute_disk.data.size == 170 &&
      google_compute_disk.docker-volumes.size == 50 &&
      output.volumes.data.size_gb == 170 &&
      output.volumes.docker_volumes.size_gb == 50
    )
    error_message = "Application data and Docker volumes must retain independent configured capacities."
  }
}

run "rejects_fractional_application_data_size" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    data_disk_size_gb   = 20.5
  }

  expect_failures = [var.data_disk_size_gb]
}

run "creates_app_key_management_only_when_explicitly_enabled" {
  command = plan

  variables {
    name                    = "gcp-contract"
    project_id              = "test-project"
    docker_compose_repo     = "https://github.com/libops/wp.git"
    app_credentials_enabled = true
  }

  assert {
    condition = (
      length(google_service_account_iam_member.app-keys) == 1 &&
      google_service_account_iam_member.app-keys[0].role == "roles/iam.serviceAccountKeyAdmin" &&
      google_service_account_iam_member.app-keys[0].member == "serviceAccount:${local.vm_service_account_email}" &&
      local.host_env.GCP_APP_SERVICE_ACCOUNT_MANAGED == "true" &&
      output.appGsa.managed == true &&
      local.host_env.GCP_APP_CREDENTIALS_ENABLED == "true"
    )
    error_message = "Explicit app file credentials must scope Key Admin to the module-owned app identity and enable runtime rotation."
  }
}

run "marks_caller_supplied_app_identity_unmanaged" {
  command = plan

  variables {
    name                      = "gcp-contract"
    project_id                = "test-project"
    docker_compose_repo       = "https://github.com/libops/wp.git"
    app_service_account_email = "existing@test-project.iam.gserviceaccount.com"
    app_credentials_enabled   = true
  }

  assert {
    condition = (
      local.host_env.GCP_APP_SERVICE_ACCOUNT_MANAGED == "false" &&
      output.appGsa.managed == false
    )
    error_message = "A caller-supplied app identity must never authorize managed orphan-key reconciliation."
  }
}

run "scopes_token_signing_to_managed_gcp_iam_vault_auth" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    vault_agent_enabled = true
    vault_auth_method   = "gcp-iam"
    vault_addr          = "https://vault.example"
    vault_role          = "wordpress"
  }

  assert {
    condition = (
      length(google_service_account_iam_member.vault_agent_jwt_signer_policy) == 1 &&
      google_service_account_iam_member.vault_agent_jwt_signer_policy[0].role == "roles/iam.serviceAccountTokenCreator" &&
      google_service_account_iam_member.vault_agent_jwt_signer_policy[0].member == "serviceAccount:${local.vm_service_account_email}" &&
      length(google_service_account_iam_member.app-keys) == 0 &&
      length(regexall("GOOGLE_APPLICATION_CREDENTIALS", local.vault_agent_env_content)) == 0
    )
    error_message = "Managed GCP IAM Vault auto-auth must let only the VM identity sign as the app identity."
  }
}

run "omits_token_signing_for_consumer_managed_vault_auth" {
  command = plan

  variables {
    name                          = "gcp-contract"
    project_id                    = "test-project"
    docker_compose_repo           = "https://github.com/libops/wp.git"
    vault_agent_enabled           = true
    vault_auth_method             = "consumer-managed"
    vault_addr                    = "https://vault.example"
    vault_agent_additional_config = "auto_auth { method \"approle\" { config = {} } }"
  }

  assert {
    condition     = length(google_service_account_iam_member.vault_agent_jwt_signer_policy) == 0
    error_message = "Consumer-managed Vault auth must not add GCP token-signing permission."
  }
}

run "normalizes_minimal_compose_project" {
  command = plan

  variables {
    name           = "gcp-contract"
    project_id     = "test-project"
    project_number = "123456789"
    compose_projects = {
      wordpress = {
        docker_compose_repo   = "https://github.com/libops/wp.git"
        docker_compose_branch = "v1.0.0"
      }
    }
    sitectl_verify_args = ["--route", "/"]
  }

  assert {
    condition = (
      local.compose_projects.wordpress.name == "wordpress" &&
      local.compose_projects.wordpress.docker_compose_repo == "https://github.com/libops/wp.git" &&
      local.compose_projects.wordpress.docker_compose_branch == "v1.0.0" &&
      local.compose_projects.wordpress.repo_path == "libops/wp.git" &&
      local.compose_projects.wordpress.project_dir == "/mnt/disks/data/libops/wp.git/wordpress" &&
      local.compose_projects.wordpress.compose_project_name == "libops-wp-v1-0-0" &&
      local.compose_projects.wordpress.ingress_port == 80 &&
      local.compose_projects.wordpress.ingress.letsencrypt == var.sitectl_ingress.letsencrypt &&
      local.compose_projects.wordpress.sitectl_context_name == "wordpress" &&
      local.compose_projects.wordpress.sitectl_plugin == "core" &&
      local.compose_projects.wordpress.sitectl_environment == "production" &&
      local.compose_projects.wordpress.sitectl_packages == tolist(["sitectl"]) &&
      local.compose_projects.wordpress.sitectl_verify_args == tolist(["--route", "/"]) &&
      local.compose_projects.wordpress.init_commands == var.docker_compose_init &&
      local.compose_projects.wordpress.up_commands == var.docker_compose_up &&
      local.compose_projects.wordpress.down_commands == var.docker_compose_down &&
      local.compose_projects.wordpress.rollout_commands == var.docker_compose_rollout
    )
    error_message = "A compose project containing only docker_compose_repo must inherit and derive every optional field."
  }
}

run "preserves_explicit_project_directory_during_default_migration" {
  command = plan

  variables {
    name           = "gcp-contract"
    project_id     = "test-project"
    project_number = "123456789"
    compose_projects = {
      wordpress = {
        docker_compose_repo   = "https://github.com/libops/wp.git"
        docker_compose_branch = "v1.0.0"
        project_dir           = "/mnt/disks/data/libops/wp.git/v1.0.0"
      }
    }
  }

  assert {
    condition     = local.compose_projects.wordpress.project_dir == "/mnt/disks/data/libops/wp.git/v1.0.0"
    error_message = "An explicit legacy project_dir must remain unchanged while callers migrate to the stable default."
  }
}

run "distinguishes_inherited_and_explicit_core_only_project_packages" {
  command = plan

  variables {
    name       = "gcp-contract"
    project_id = "test-project"
    sitectl_packages = [
      "sitectl-drupal",
      "sitectl-isle",
    ]
    compose_projects = {
      inherited = {
        docker_compose_repo = "https://github.com/libops/isle.git"
      }
      core-only = {
        docker_compose_repo = "https://github.com/libops/wp.git"
        sitectl_packages    = []
      }
    }
  }

  assert {
    condition = (
      local.compose_projects.inherited.sitectl_packages == tolist(["sitectl", "sitectl-drupal", "sitectl-isle"]) &&
      local.compose_projects["core-only"].sitectl_packages == tolist(["sitectl"]) &&
      module.sitectl_runtime.packages == tolist(["sitectl", "sitectl-drupal", "sitectl-isle"])
    )
    error_message = "Project manifests must distinguish inherited packages from an explicit list while the host package set remains their union."
  }
}

run "power_management_enables_required_identity_and_ingress" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  assert {
    condition     = length(google_service_account.internal-services) == 1
    error_message = "Power management must create its internal-services identity."
  }

  assert {
    condition     = length(google_compute_instance_iam_member.gce-suspend) == 1
    error_message = "Power management must grant the internal-services identity permission to suspend the VM."
  }

  assert {
    condition     = length(module.ppb) == 1
    error_message = "Power management must create the pinned power-button ingress module."
  }

  assert {
    condition     = output.serviceGsa != null
    error_message = "serviceGsa must expose the enabled internal-services identity."
  }

  assert {
    condition = (
      length(google_compute_instance_iam_member.gce-start) == 1 &&
      length(google_compute_firewall.allow-cloud-run-ingress) == 1 &&
      length(google_compute_firewall.allow-cloud-run-ingress[0].source_ranges) == 1 &&
      contains(google_compute_firewall.allow-cloud-run-ingress[0].source_ranges, "10.42.0.0/24") &&
      length(one(google_compute_firewall.allow-cloud-run-ingress[0].allow).ports) == 1 &&
      contains(one(google_compute_firewall.allow-cloud-run-ingress[0].allow).ports, "80") &&
      local.base_config.powerOnTimeout == 240 &&
      local.base_config.ipDepth == 0 &&
      local.dynamic_properties.allowedIps == tolist(["198.51.100.25/32"]) &&
      local.ppb_container.startup_probe == "/healthcheck" &&
      local.base_config.proxyTimeouts.dialTimeout == 300 &&
      local.base_config.proxyTimeouts.dialAttemptTimeout == 5 &&
      local.base_config.proxyTimeouts.dialRetryInterval == 1
    )
    error_message = "Power management must bind least-privilege roles to the VM, allow only the selected subnet to reach the app port, use a process-only startup probe, and bound VM/network readiness."
  }
}

run "rejects_power_management_without_explicit_client_cidrs" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ip_forwarded_depth = 0
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_power_management_without_explicit_proxy_depth" {
  command = plan

  variables {
    name                     = "gcp-contract"
    project_id               = "test-project"
    project_number           = "123456789"
    docker_compose_repo      = "https://github.com/libops/wp.git"
    power_management_enabled = true
    power_start_role         = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role       = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips              = ["198.51.100.25/32"]
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_negative_proxy_depth" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    allowed_ip_forwarded_depth = -1
  }

  expect_failures = [var.allowed_ip_forwarded_depth]
}

run "supports_explicit_additional_trusted_proxy_depth" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    allowed_ip_forwarded_depth = 2
  }

  assert {
    condition     = local.base_config.ipDepth == 2
    error_message = "An explicitly reviewed additional trusted proxy must increase PPB's right-edge X-Forwarded-For depth."
  }
}

run "rejects_wrong_family_firewall_cidrs" {
  command = plan

  variables {
    name                 = "gcp-contract"
    project_id           = "test-project"
    docker_compose_repo  = "https://github.com/libops/wp.git"
    allowed_ssh_ipv4     = ["2001:db8::/64"]
    allowed_ssh_ipv6     = ["10.0.0.0/8"]
    rollout_allowed_ipv4 = ["2001:db8::/64"]
  }

  expect_failures = [
    var.allowed_ssh_ipv4,
    var.allowed_ssh_ipv6,
    var.rollout_allowed_ipv4,
  ]
}

run "rejects_invalid_ingress_and_frontend_ports" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    ingress_port        = 65536
    frontend = {
      image = "example.invalid/frontend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      port  = 0
    }
  }

  expect_failures = [
    var.ingress_port,
    var.frontend,
  ]
}

run "rejects_fractional_compose_project_port" {
  command = plan

  variables {
    name       = "gcp-contract"
    project_id = "test-project"
    compose_projects = {
      wordpress = {
        docker_compose_repo = "https://github.com/libops/wp.git"
        ingress_port        = 80.5
      }
    }
  }

  expect_failures = [var.compose_projects]
}

run "renders_verified_archive_before_downstream_overlay" {
  command = plan

  variables {
    name                  = "gcp-contract"
    project_id            = "test-project"
    project_number        = "123456789"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs                = "testdata/rootfs"
    rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz?literal=$(id)"
    rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    extra_env = {
      NGINX_CLIENT_MAX_BODY_SIZE = "512m"
      PHP_UPLOAD_MAX_FILESIZE    = "512M"
      BASH_ENV                   = "/tmp/application-only-bash-env"
      LD_PRELOAD                 = "/tmp/application-only-preload.so"
    }
  }

  assert {
    condition = (
      strcontains(local.cloud_init_yaml, "sha256sum -c -") &&
      strcontains(local.cloud_init_yaml, base64encode(var.rootfs_archive_url)) &&
      !strcontains(local.cloud_init_yaml, var.rootfs_archive_url)
    )
    error_message = "The GCP archive URL must be transported as literal base64 data and verified before extraction."
  }

  assert {
    condition = can(regex(
      "(?s)cp -a \\\"\\$rootfs_dir\\\"/\\. /.*cp -a \\\"\\$overlay_dir\\\"/\\. /",
      local.cloud_init_yaml,
    ))
    error_message = "The consumer rootfs overlay must be applied after the verified base archive."
  }

  assert {
    condition = (
      strcontains(local.cloud_init_yaml, "/var/lib/cloud-compose/rootfs-overlay/etc/cloud-compose-overlay-marker") &&
      !strcontains(module.runtime_env.content, "NGINX_CLIENT_MAX_BODY_SIZE") &&
      !strcontains(module.runtime_env.content, "PHP_UPLOAD_MAX_FILESIZE") &&
      !contains(keys(local.host_env), "BASH_ENV") &&
      !contains(keys(local.host_env), "LD_PRELOAD") &&
      strcontains(
        local.application_env_file_content,
        jsonencode(base64gzip(jsonencode(var.extra_env))),
      )
    )
    error_message = "The downstream overlay and isolated application environment data must be present in cloud-init."
  }
}

run "namespaces_rollout_auth_away_from_application_environment" {
  command = plan

  variables {
    name                   = "gcp-rollout-contract"
    project_id             = "test-project"
    project_number         = "123456789"
    docker_compose_repo    = "https://github.com/libops/wp.git"
    rollout_enabled        = true
    rollout_release_url    = "https://example.invalid/cloud-compose-rollout"
    rollout_release_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rollout_jwks_uri       = "https://trusted.example/.well-known/jwks.json"
    rollout_jwt_audience   = "trusted-controller"
    rollout_custom_claims  = "{\"role\":\"deployer\"}"
    extra_env = {
      PORT          = "9999"
      JWKS_URI      = "https://attacker.invalid/jwks.json"
      JWT_AUD       = "attacker"
      CUSTOM_CLAIMS = "{\"admin\":true}"
    }
  }

  assert {
    condition = (
      local.host_env.ROLLOUT_PORT == "8081" &&
      local.host_env.ROLLOUT_JWKS_URI == "https://trusted.example/.well-known/jwks.json" &&
      local.host_env.ROLLOUT_JWT_AUD == "trusted-controller" &&
      local.host_env.ROLLOUT_CUSTOM_CLAIMS == "{\"role\":\"deployer\"}" &&
      !contains(keys(local.host_env), "PORT") &&
      !contains(keys(local.host_env), "JWKS_URI") &&
      !contains(keys(local.host_env), "JWT_AUD") &&
      !contains(keys(local.host_env), "CUSTOM_CLAIMS") &&
      strcontains(
        local.application_env_file_content,
        jsonencode(base64gzip(jsonencode(var.extra_env))),
      )
    )
    error_message = "Rollout listener and auth settings must be sourced only from the namespaced host-control contract."
  }
}

run "rejects_insecure_rollout_trust_inputs" {
  command = plan

  variables {
    name                  = "gcp-contract"
    project_id            = "test-project"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rollout_release_url   = "http://downloads.example/rollout"
    rollout_jwks_uri      = "http://identity.example/jwks"
    rollout_custom_claims = "[]"
  }

  expect_failures = [
    var.rollout_release_url,
    var.rollout_jwks_uri,
    var.rollout_custom_claims,
  ]
}

run "rejects_archive_without_checksum" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    project_number      = "123456789"
    docker_compose_repo = "https://github.com/libops/wp.git"
    rootfs_archive_url  = "https://example.invalid/cloud-compose.tar.gz"
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_non_https_rootfs_archive" {
  command = plan

  variables {
    name                  = "gcp-contract"
    project_id            = "test-project"
    project_number        = "123456789"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs_archive_url    = "http://example.invalid/cloud-compose.tar.gz"
    rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.rootfs_archive_url]
}

run "supports_network_only_direct_vpc" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    create_network             = false
    network_project_id         = "network-project"
    network_name               = "existing-network"
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  assert {
    condition = (
      local.network_name == "https://www.googleapis.com/compute/v1/projects/network-project/global/networks/existing-network" &&
      local.subnetwork_name == "https://www.googleapis.com/compute/v1/projects/network-project/regions/us-east5/subnetworks/existing-network" &&
      local.cloud_run_network_resource_name == "projects/network-project/global/networks/existing-network" &&
      local.cloud_run_subnetwork_resource_name == "projects/network-project/regions/us-east5/subnetworks/existing-network" &&
      local.cloud_run_subnetwork_cidr == "10.50.0.0/24" &&
      local.dynamic_properties.allowedIps == tolist(["198.51.100.25/32"]) &&
      google_compute_firewall.allow-cloud-run-ingress[0].project == "network-project" &&
      local.network_namespace == "gcp-contract-${substr(sha256("test-project"), 0, 8)}" &&
      google_compute_firewall.allow-cloud-run-ingress[0].name == "allow-cloud-run-${local.network_namespace}" &&
      google_compute_instance.cloud-compose.tags == toset(["cloud-compose", local.network_namespace]) &&
      length(google_compute_firewall.allow-cloud-run-ingress[0].source_ranges) == 1 &&
      contains(google_compute_firewall.allow-cloud-run-ingress[0].source_ranges, "10.50.0.0/24")
    )
    error_message = "Network-only Direct VPC input must select the same-named subnet, use canonical Cloud Run resource names, and use its full CIDR for VM ingress."
  }
}

run "rejects_mismatched_project_number_assertion" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    project_number      = "987654321"
    docker_compose_repo = "https://github.com/libops/wp.git"
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_power_role_from_another_project" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    power_management_enabled   = true
    power_start_role           = "projects/other-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_cross_project_supplied_service_accounts" {
  command = plan

  variables {
    name                      = "gcp-contract"
    project_id                = "test-project"
    docker_compose_repo       = "https://github.com/libops/wp.git"
    service_account_email     = "vm@other-project.iam.gserviceaccount.com"
    app_service_account_email = "app@other-project.iam.gserviceaccount.com"
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "resolves_a_supplied_same_project_service_account" {
  command = plan

  variables {
    name                  = "gcp-contract"
    project_id            = "test-project"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    service_account_email = "existing@test-project.iam.gserviceaccount.com"
  }

  assert {
    condition = (
      local.vm_service_account_email == "existing@test-project.iam.gserviceaccount.com" &&
      local.vm_service_account_id == "projects/test-project/serviceAccounts/existing@test-project.iam.gserviceaccount.com"
    )
    error_message = "A supplied service account must resolve through its authoritative same-project data source."
  }
}

run "supports_power_roles_in_a_legacy_domain_scoped_project" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "example.com:test-project"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    power_management_enabled   = true
    power_start_role           = "projects/example.com:test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/example.com:test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  assert {
    condition = (
      google_compute_instance_iam_member.gce-start[0].role == "projects/example.com:test-project/roles/cloudComposeStart" &&
      google_compute_instance_iam_member.gce-suspend[0].role == "projects/example.com:test-project/roles/cloudComposeSuspend"
    )
    error_message = "Legacy domain-scoped project custom roles must remain valid for instance-scoped bindings."
  }
}

run "rejects_network_project_id_that_conflicts_with_self_link" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    create_network      = false
    network_project_id  = "different-network-project"
    network_name        = "projects/network-project/global/networks/existing-network"
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_network_and_subnetwork_from_different_projects" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    create_network      = false
    network_name        = "projects/network-project/global/networks/existing-network"
    subnetwork_name     = "projects/other-network-project/regions/us-east5/subnetworks/existing-network"
  }

  override_data {
    target = data.google_compute_subnetwork.selected
    values = {
      name          = "existing-network"
      self_link     = "https://www.googleapis.com/compute/v1/projects/other-network-project/regions/us-east5/subnetworks/existing-network"
      network       = "https://www.googleapis.com/compute/v1/projects/other-network-project/global/networks/existing-network"
      ip_cidr_range = "10.50.0.0/24"
    }
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_subnetwork_from_another_region" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    create_network      = false
    subnetwork_name     = "projects/network-project/regions/us-central1/subnetworks/existing-network"
  }

  override_data {
    target = data.google_compute_subnetwork.selected
    values = {
      name          = "existing-network"
      self_link     = "https://www.googleapis.com/compute/v1/projects/network-project/regions/us-central1/subnetworks/existing-network"
      network       = "https://www.googleapis.com/compute/v1/projects/network-project/global/networks/existing-network"
      ip_cidr_range = "10.50.0.0/24"
    }
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "supports_subnetwork_only_direct_vpc" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    create_network             = false
    network_project_id         = "network-project"
    subnetwork_name            = "existing-subnetwork"
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  assert {
    condition = (
      local.network_name == data.google_compute_subnetwork.selected[0].network &&
      local.subnetwork_name == data.google_compute_subnetwork.selected[0].self_link &&
      local.cloud_run_subnetwork_cidr == data.google_compute_subnetwork.selected[0].ip_cidr_range
    )
    error_message = "Subnetwork-only Direct VPC input must derive and share the subnet's parent network."
  }
}

run "derives_a_simple_network_project_from_subnetwork_self_link" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    docker_compose_repo = "https://github.com/libops/wp.git"
    create_network      = false
    network_name        = "existing-network"
    subnetwork_name     = "projects/network-project/regions/us-east5/subnetworks/existing-network"
  }

  assert {
    condition = (
      local.selected_network_lookup_project == "network-project" &&
      local.network_project_id == "network-project" &&
      local.subnetwork_project_id == "network-project"
    )
    error_message = "A fully qualified subnet must supply the project for a simple parent-network name."
  }
}

run "rejects_undersized_direct_vpc_subnet" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    network_ip_cidr_range      = "10.42.0.0/28"
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_unsupported_direct_vpc_subnet_range" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    network_ip_cidr_range      = "203.0.113.0/24"
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "supports_rfc6598_direct_vpc_subnet_range" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    network_ip_cidr_range      = "100.64.0.0/26"
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  assert {
    condition     = local.cloud_run_subnetwork_range_supported
    error_message = "RFC6598 subnets must be accepted for Direct VPC egress."
  }
}

run "rejects_custom_direct_vpc_network_mtu" {
  command = plan

  variables {
    name                       = "gcp-contract"
    project_id                 = "test-project"
    project_number             = "123456789"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    network_mtu                = 1500
    power_management_enabled   = true
    power_start_role           = "projects/test-project/roles/cloudComposeStart"
    power_suspend_role         = "projects/test-project/roles/cloudComposeSuspend"
    allowed_ips                = ["198.51.100.25/32"]
    allowed_ip_forwarded_depth = 0
  }

  expect_failures = [google_compute_instance.cloud-compose]
}

run "rejects_reserved_extra_environment" {
  command = plan

  variables {
    name                = "gcp-contract"
    project_id          = "test-project"
    project_number      = "123456789"
    docker_compose_repo = "https://github.com/libops/wp.git"
    extra_env = {
      GCP_PROJECT = "different-project"
    }
  }

  expect_failures = [var.extra_env]
}
