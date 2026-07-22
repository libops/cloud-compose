# cloud-compose

Deploy Docker Compose projects to VMs. The repository root is a compatibility
entrypoint for existing GCP callers. New callers should select exactly one
Terraform entrypoint under `providers/`: `providers/gcp`, `providers/do`, or
`providers/linode`. Each entrypoint loads only its target cloud provider.
Existing Debian/Ubuntu hosts can consume the same runtime contract through the
Ansible role or Salt formula.

Template defaults live in `templates/apps.json` and are shared by Terraform,
Ansible, and Salt. The default deployment shape is one app per VM or host; pass
`runtime.compose.projects` when several apps should share the same machine.
Terraform template presets include an exact, reviewed sitectl core/plugin
release set. Override individual selectors with
`runtime.sitectl.package_versions` when intentionally testing or promoting a
different compatible release set.

All presets use their coordinated sitectl v1.0.0 core/plugin release set. The
ISLE preset selects the `libops/isle` v1.1.0 template; every other application
preset remains on its v1.0.0 template contract. Keep each preset's complete
template and package set together when promoting an override.

GCP deployments have two Terraform ownership layers. Apply
[`modules/gcp-foundation`](modules/gcp-foundation/README.md) once per service
project from a small, long-lived state; it owns required APIs, the Cloud Run
service identity, the reusable least-privilege power roles, and any Shared VPC
attachment and service-agent grants. Per-application states consume the role
names and bind their service accounts only to their own Compute Engine instance.
They must not recreate or destroy the singleton foundation. The
[runtime contracts](docs/runtime-contracts.md#gcp-foundation-and-application-states)
cover the state boundary, Shared VPC setup, and Cloud Run Direct VPC egress
requirements.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_cloudinit"></a> [cloudinit](#requirement\_cloudinit) | ~> 2.3 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 7.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.14 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_gcp"></a> [gcp](#module\_gcp) | ./modules/gcp | n/a |
| <a name="module_managed_artifacts"></a> [managed\_artifacts](#module\_managed\_artifacts) | ./modules/managed-artifacts | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | Deployment name. | `string` | n/a | yes |
| <a name="input_cloud_provider"></a> [cloud\_provider](#input\_cloud\_provider) | Compatibility selector for the root GCP entrypoint. Use providers/do or providers/linode for other clouds. | `string` | `"gcp"` | no |
| <a name="input_gcp"></a> [gcp](#input\_gcp) | Google Cloud infrastructure settings. | <pre>object({<br/>    project_id     = optional(string, "")<br/>    project_number = optional(string, "")<br/>    region         = optional(string, "us-east5")<br/>    zone           = optional(string, "us-east5-b")<br/><br/>    identity = optional(object({<br/>      vm_service_account_email  = optional(string, "")<br/>      app_service_account_email = optional(string, "")<br/>      app_credentials_enabled   = optional(bool, false)<br/>    }), {})<br/><br/>    instance = optional(object({<br/>      machine_type = optional(string, "n4-standard-2")<br/>      os           = optional(string, "cos-125-19216-220-185")<br/>      production   = optional(bool, false)<br/>    }), {})<br/><br/>    disks = optional(object({<br/>      type                   = optional(string, "hyperdisk-balanced")<br/>      docker_volumes_size_gb = optional(number, 50)<br/>      attachments = optional(map(object({<br/>        source = string<br/>        mode   = optional(string, "READ_WRITE")<br/>      })), {})<br/>    }), {})<br/><br/>    network = optional(object({<br/>      create                   = optional(bool, true)<br/>      project_id               = optional(string, "")<br/>      name                     = optional(string, "")<br/>      subnetwork               = optional(string, "")<br/>      ip_cidr_range            = optional(string, "10.42.0.0/24")<br/>      mtu                      = optional(number, 1460)<br/>      power_button_allowed_ips = optional(list(string), [])<br/>      power_button_ip_depth    = optional(number)<br/>      ssh_ipv4                 = optional(list(string), [])<br/>      ssh_ipv6                 = optional(list(string), [])<br/>    }), {})<br/><br/>    snapshots = optional(object({<br/>      enabled = optional(bool, false)<br/>    }), {})<br/><br/>    overlay = optional(object({<br/>      source_instance = optional(string, "")<br/>      volume_names    = optional(list(string), [])<br/>    }), {})<br/><br/>    cloud_init = optional(object({<br/>      initcmd = optional(list(string), [])<br/>      runcmd  = optional(list(string), [])<br/>    }), {})<br/><br/>    artifact_registry = optional(object({<br/>      repository = optional(string, "")<br/>      location   = optional(string, "us")<br/>    }), {})<br/><br/>    power_management = optional(object({<br/>      enabled      = optional(bool, false)<br/>      start_role   = optional(string, "")<br/>      suspend_role = optional(string, "")<br/>      frontend = optional(object({<br/>        image  = string<br/>        port   = optional(number, 8080)<br/>        cpu    = optional(string, "1000m")<br/>        memory = optional(string, "1Gi")<br/>      }), null)<br/>    }), {})<br/><br/>    rollout = optional(object({<br/>      enabled        = optional(bool, false)<br/>      release_url    = optional(string, "")<br/>      release_sha256 = optional(string, "")<br/>      port           = optional(number, 8081)<br/>      jwks_uri       = optional(string, "")<br/>      jwt_audience   = optional(string, "")<br/>      custom_claims  = optional(string, "")<br/>      allowed_ipv4   = optional(list(string), ["10.0.0.0/8"])<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_runtime"></a> [runtime](#input\_runtime) | Provider-neutral compose/runtime settings. | <pre>object({<br/>    rootfs                = optional(string, "")<br/>    rootfs_archive_url    = optional(string, "")<br/>    rootfs_archive_sha256 = optional(string, "")<br/>    users                 = optional(map(list(string)), {})<br/><br/>    compose = optional(object({<br/>      primary      = optional(string, "")<br/>      ingress_port = optional(number, 80)<br/>      ingress = optional(object({<br/>        letsencrypt     = optional(bool, false)<br/>        bot_mitigation  = optional(bool, false)<br/>        mode            = optional(string, "")<br/>        domain          = optional(string, "")<br/>        acme_email      = optional(string, "")<br/>        trusted_ips     = optional(list(string), [])<br/>        max_upload_size = optional(string, "")<br/>        upload_timeout  = optional(string, "")<br/>      }), {})<br/>      repo   = optional(string, "")<br/>      branch = optional(string, "")<br/>      projects = optional(map(object({<br/>        docker_compose_repo   = string<br/>        docker_compose_branch = optional(string)<br/>        project_dir           = optional(string)<br/>        compose_project_name  = optional(string)<br/>        ingress_port          = optional(number)<br/>        ingress = optional(object({<br/>          letsencrypt     = optional(bool)<br/>          bot_mitigation  = optional(bool)<br/>          mode            = optional(string)<br/>          domain          = optional(string)<br/>          acme_email      = optional(string)<br/>          trusted_ips     = optional(list(string))<br/>          max_upload_size = optional(string)<br/>          upload_timeout  = optional(string)<br/>        }), {})<br/>        sitectl_context_name   = optional(string)<br/>        sitectl_plugin         = optional(string)<br/>        sitectl_environment    = optional(string)<br/>        sitectl_packages       = optional(list(string))<br/>        sitectl_verify_args    = optional(list(string))<br/>        docker_compose_init    = optional(list(string))<br/>        docker_compose_up      = optional(list(string))<br/>        docker_compose_down    = optional(list(string))<br/>        docker_compose_rollout = optional(list(string))<br/>      })), {})<br/>      init    = optional(list(string))<br/>      up      = optional(list(string))<br/>      down    = optional(list(string))<br/>      rollout = optional(list(string))<br/>    }), {})<br/><br/>    sitectl = optional(object({<br/>      packages         = optional(list(string))<br/>      version          = optional(string, "latest")<br/>      package_versions = optional(map(string), {})<br/>      context_name     = optional(string, "")<br/>      plugin           = optional(string, "core")<br/>      environment      = optional(string, "production")<br/>      verify_args      = optional(list(string), [])<br/>    }), {})<br/><br/>    docker = optional(object({<br/>      # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver<br/>      compose_version = optional(string, "v5.3.1")<br/>      # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver<br/>      buildx_version = optional(string, "v0.35.0")<br/>    }), {})<br/><br/>    managed_runtime = optional(object({<br/>      enabled                       = optional(bool, true)<br/>      internal_services_enabled     = optional(bool, false)<br/>      internal_services_auto_update = optional(bool, false)<br/>      artifacts = optional(list(object({<br/>        name    = string<br/>        url     = string<br/>        sha256  = string<br/>        path    = string<br/>        mode    = optional(string, "0755")<br/>        owner   = optional(string, "root")<br/>        group   = optional(string, "root")<br/>        restart = optional(string, "")<br/>      })), [])<br/>    }), {})<br/><br/>    vault = optional(object({<br/>      addr                    = optional(string, "")<br/>      namespace               = optional(string, "")<br/>      role                    = optional(string, "")<br/>      agent_enabled           = optional(bool, false)<br/>      auth_method             = optional(string, "auto")<br/>      gcp_auth_mount_path     = optional(string, "auth/gcp")<br/>      agent_token_path        = optional(string, "/mnt/disks/data/vault/token")<br/>      agent_additional_config = optional(string, "")<br/>      agent_templates = optional(list(object({<br/>        destination = string<br/>        contents    = string<br/>        perms       = optional(string, "0640")<br/>        command     = optional(string, "")<br/>      })), [])<br/>    }), {})<br/><br/>    extra_env = optional(map(string), {})<br/>  })</pre> | `{}` | no |
| <a name="input_template"></a> [template](#input\_template) | Optional compose template preset. Supported values are archivesspace, ojs, isle, drupal, wp, omeka-s, and omeka-classic. Explicit runtime settings override preset defaults. | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_appGsa"></a> [appGsa](#output\_appGsa) | The Google Service Account the app can use for app-scoped auth. |
| <a name="output_backend"></a> [backend](#output\_backend) | Backend service ID for attaching Cloud Run ingress to an external HTTPS load balancer. |
| <a name="output_cloud_provider"></a> [cloud\_provider](#output\_cloud\_provider) | Root entrypoint cloud provider (gcp). |
| <a name="output_compose_projects"></a> [compose\_projects](#output\_compose\_projects) | Normalized compose project manifest. |
| <a name="output_external_ip"></a> [external\_ip](#output\_external\_ip) | GCP VM public IPv4 address. |
| <a name="output_instance"></a> [instance](#output\_instance) | GCP VM instance details. |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | GCP VM instance ID. |
| <a name="output_internal_ip"></a> [internal\_ip](#output\_internal\_ip) | GCP VM private IPv4 address. |
| <a name="output_network"></a> [network](#output\_network) | Resolved GCP network and regional subnetwork. |
| <a name="output_primary_compose_project"></a> [primary\_compose\_project](#output\_primary\_compose\_project) | Normalized primary compose project. |
| <a name="output_rollout"></a> [rollout](#output\_rollout) | Optional rollout API endpoint details. |
| <a name="output_serviceGsa"></a> [serviceGsa](#output\_serviceGsa) | The Google Service Account internal services run as. |
| <a name="output_sitectl_package_versions"></a> [sitectl\_package\_versions](#output\_sitectl\_package\_versions) | Effective release selector for every installed sitectl package; values may be exact tags or latest. |
| <a name="output_template"></a> [template](#output\_template) | Selected compose template preset. |
| <a name="output_urls"></a> [urls](#output\_urls) | Cloud Run ingress URLs by region. |
| <a name="output_volumes"></a> [volumes](#output\_volumes) | GCP persistent application-data and Docker-volume details. |
<!-- END_TF_DOCS -->
