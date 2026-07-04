# cloud-compose

Deploy a docker compose project to a Google Cloud Compute Instance.

Optional VM APIs:

- [Rollout API](docs/rollout.md) exposes authenticated deployment rollout triggers for the compose project.
- [Managed Runtime](docs/managed-runtime.md) keeps `sitectl`, sitectl plugins, and LibOps-side support services up to date on the VM.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.2.4 |
| <a name="requirement_cloudinit"></a> [cloudinit](#requirement\_cloudinit) | ~> 2.3 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 7.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.14 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cloudinit"></a> [cloudinit](#provider\_cloudinit) | 2.4.0 |
| <a name="provider_google"></a> [google](#provider\_google) | 7.34.0 |
| <a name="provider_time"></a> [time](#provider\_time) | 0.14.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_ppb"></a> [ppb](#module\_ppb) | git::https://github.com/libops/terraform-cloudrun-v2 | 0.5.3 |

## Resources

| Name | Type |
|------|------|
| [google_artifact_registry_repository_iam_member.private-policy-cloud-compose](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_compute_disk.boot](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_disk) | resource |
| [google_compute_disk.data](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_disk) | resource |
| [google_compute_disk.docker-volumes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_disk) | resource |
| [google_compute_disk.overlay_disk](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_disk) | resource |
| [google_compute_disk_resource_policy_attachment.daily_snapshot](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_disk_resource_policy_attachment) | resource |
| [google_compute_disk_resource_policy_attachment.weekly_snapshot](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_disk_resource_policy_attachment) | resource |
| [google_compute_firewall.allow_rollout_ipv4](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.allow_ssh_ipv4](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.allow_ssh_ipv6](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_instance.cloud-compose](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance) | resource |
| [google_compute_reservation.production](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_reservation) | resource |
| [google_compute_resource_policy.daily_snapshot](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_resource_policy) | resource |
| [google_compute_resource_policy.weekly_snapshot](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_resource_policy) | resource |
| [google_project_iam_member.gce-start](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.gce-suspend](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.log](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.stackdriver](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_service_account.app](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.cloud-compose](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.internal-services](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.ppb](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.app-keys](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.gsa-user](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.internal-services-keys](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.self_jwt_signer_policy](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.token-creator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [time_static.snapshot_time_static](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/static) | resource |
| [cloudinit_config.ci](https://registry.terraform.io/providers/hashicorp/cloudinit/latest/docs/data-sources/config) | data source |
| [google_compute_snapshot.latest_prod](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_snapshot) | data source |
| [google_project_iam_custom_role.gce-start](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project_iam_custom_role) | data source |
| [google_project_iam_custom_role.gce-suspend](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project_iam_custom_role) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_docker_compose_repo"></a> [docker\_compose\_repo](#input\_docker\_compose\_repo) | git repo to checkout that contains a docker compose project | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | The site name (will be the name of the GCP instance) | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | The GCP project ID | `string` | n/a | yes |
| <a name="input_project_number"></a> [project\_number](#input\_project\_number) | The GCP project number | `string` | n/a | yes |
| <a name="input_allowed_ips"></a> [allowed\_ips](#input\_allowed\_ips) | CIDR IP Addresses allowed to turn on this site's GCP instance | `list(string)` | `[]` | no |
| <a name="input_allowed_ssh_ipv4"></a> [allowed\_ssh\_ipv4](#input\_allowed\_ssh\_ipv4) | CIDR IPv4 Addresses allowed to to SSH into this site's GCP instance | `list(string)` | `[]` | no |
| <a name="input_allowed_ssh_ipv6"></a> [allowed\_ssh\_ipv6](#input\_allowed\_ssh\_ipv6) | CIDR IPv6 Addresses allowed to SSH into this site's GCP instance | `list(string)` | `[]` | no |
| <a name="input_artifact_registry_location"></a> [artifact\_registry\_location](#input\_artifact\_registry\_location) | Artifact Registry location for var.artifact\_registry\_repository. | `string` | `"us"` | no |
| <a name="input_artifact_registry_repository"></a> [artifact\_registry\_repository](#input\_artifact\_registry\_repository) | Optional Artifact Registry repository name to grant the VM service account reader access to. Leave empty to skip creating the IAM binding. | `string` | `""` | no |
| <a name="input_disk_size_gb"></a> [disk\_size\_gb](#input\_disk\_size\_gb) | Data disk size in GB | `number` | `50` | no |
| <a name="input_disk_type"></a> [disk\_type](#input\_disk\_type) | The disk type for disks attached to the machine | `string` | `"hyperdisk-balanced"` | no |
| <a name="input_docker_compose_branch"></a> [docker\_compose\_branch](#input\_docker\_compose\_branch) | git branch to checkout for var.docker\_compose\_repo | `string` | `"main"` | no |
| <a name="input_docker_compose_down"></a> [docker\_compose\_down](#input\_docker\_compose\_down) | Command to stop the docker compose project | `list(string)` | <pre>[<br/>  "sitectl compose --context \"${SITECTL_CONTEXT_NAME}\" down"<br/>]</pre> | no |
| <a name="input_docker_compose_init"></a> [docker\_compose\_init](#input\_docker\_compose\_init) | After cloning the docker compose git repo, any initialization that needs to happen before the docker compose project can start. One command per list value | `list(string)` | <pre>[<br/>  "sitectl config set-context \"${SITECTL_CONTEXT_NAME}\" --type local --project-dir \"${DOCKER_COMPOSE_DIR}\" --site \"${GCP_INSTANCE_NAME}\" --plugin \"${SITECTL_PLUGIN}\" --environment \"${SITECTL_ENVIRONMENT}\" --project-name \"${GCP_INSTANCE_NAME}\" --compose-project-name \"${COMPOSE_PROJECT_NAME}\" --docker-socket /var/run/docker.sock --env-file .env --default"<br/>]</pre> | no |
| <a name="input_docker_compose_rollout"></a> [docker\_compose\_rollout](#input\_docker\_compose\_rollout) | Command to roll out a new git ref for the docker compose project. The optional rollout service sets GIT\_REF/GIT\_BRANCH from the trigger request. | `list(string)` | <pre>[<br/>  "TARGET_REF=\"${GIT_REF:-${GIT_BRANCH:-${DOCKER_COMPOSE_BRANCH:-main}}}\"",<br/>  "if [ -x ./scripts/rollout.sh ]; then ./scripts/rollout.sh; else sitectl deploy --context \"${SITECTL_CONTEXT_NAME}\" --branch \"$TARGET_REF\"; fi",<br/>  "sitectl healthcheck --context \"${SITECTL_CONTEXT_NAME}\" --persist --timeout \"${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"${SITECTL_HEALTHCHECK_INTERVAL}\"",<br/>  "if [ \"${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"${SITECTL_CONTEXT_NAME}\" ${SITECTL_VERIFY_ARGS:-}; fi"<br/>]</pre> | no |
| <a name="input_docker_compose_up"></a> [docker\_compose\_up](#input\_docker\_compose\_up) | Command to start the docker compose project | `list(string)` | <pre>[<br/>  "sitectl deploy --context \"${SITECTL_CONTEXT_NAME}\" --skip-git",<br/>  "sitectl healthcheck --context \"${SITECTL_CONTEXT_NAME}\" --persist --timeout \"${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"${SITECTL_HEALTHCHECK_INTERVAL}\"",<br/>  "if [ \"${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"${SITECTL_CONTEXT_NAME}\" ${SITECTL_VERIFY_ARGS:-}; fi",<br/>  "sitectl compose --context \"${SITECTL_CONTEXT_NAME}\" logs -f"<br/>]</pre> | no |
| <a name="input_frontend"></a> [frontend](#input\_frontend) | Optional frontend container to deploy as a sidecar next to ppb. When set,<br/>ppb continues to power on and ping the VM referenced by machineMetadata,<br/>but proxies incoming requests to this container on localhost instead of<br/>to the VM. Use this to serve a frontend from Cloud Run while keeping<br/>backend services on the VM. | <pre>object({<br/>    image  = string<br/>    port   = optional(number, 8080)<br/>    cpu    = optional(string, "1000m")<br/>    memory = optional(string, "1Gi")<br/>  })</pre> | `null` | no |
| <a name="input_ingress_port"></a> [ingress\_port](#input\_ingress\_port) | TCP port on the VM that the Cloud Run ingress should connect to. | `number` | `80` | no |
| <a name="input_initcmd"></a> [initcmd](#input\_initcmd) | Commands to run before /home/cloud-compose/run.sh | `list(string)` | `[]` | no |
| <a name="input_libops_cadvisor_image"></a> [libops\_cadvisor\_image](#input\_libops\_cadvisor\_image) | Container image used for the internal cAdvisor service. | `string` | `"ghcr.io/google/cadvisor:v0.57.0@sha256:e75bdb03b74b0b6995f208f166fead2e6e555dde73e44200113bb26f41b1981d"` | no |
| <a name="input_libops_cap_image"></a> [libops\_cap\_image](#input\_libops\_cap\_image) | Container image used for the internal CAP metrics service. | `string` | `"ghcr.io/libops/cap:main"` | no |
| <a name="input_libops_internal_services_auto_update"></a> [libops\_internal\_services\_auto\_update](#input\_libops\_internal\_services\_auto\_update) | Whether the managed runtime updater should pull and restart the internal LibOps compose project. | `bool` | `true` | no |
| <a name="input_libops_lightsout_image"></a> [libops\_lightsout\_image](#input\_libops\_lightsout\_image) | Container image used for the internal lightsout service. | `string` | `"ghcr.io/libops/lightsout:main"` | no |
| <a name="input_libops_managed_artifacts"></a> [libops\_managed\_artifacts](#input\_libops\_managed\_artifacts) | Additional LibOps-managed files or binaries to download, verify, install, and optionally restart with the managed runtime updater. | <pre>list(object({<br/>    name    = string<br/>    url     = string<br/>    sha256  = string<br/>    path    = string<br/>    mode    = optional(string, "0755")<br/>    owner   = optional(string, "root")<br/>    group   = optional(string, "root")<br/>    restart = optional(string, "")<br/>  }))</pre> | `[]` | no |
| <a name="input_libops_managed_runtime_enabled"></a> [libops\_managed\_runtime\_enabled](#input\_libops\_managed\_runtime\_enabled) | Install and periodically update LibOps-managed host tools and internal VM services. | `bool` | `true` | no |
| <a name="input_machine_type"></a> [machine\_type](#input\_machine\_type) | VM machine type (General-purpose series that support Hyperdisk Balanced | `string` | `"n4-standard-2"` | no |
| <a name="input_os"></a> [os](#input\_os) | The host OS to install on the GCP instance | `string` | `"cos-125-19216-220-185"` | no |
| <a name="input_overlay_source_instance"></a> [overlay\_source\_instance](#input\_overlay\_source\_instance) | Name of production instance to get latest snapshot from (e.g., 'ojs-production'). Terraform will automatically use the most recent snapshot from this instance's data disk. Leave empty for production environments. | `string` | `""` | no |
| <a name="input_production"></a> [production](#input\_production) | Whether this VM is the production environment. Production VMs reserve one matching machine so stop/start and recreate operations keep capacity. | `bool` | `false` | no |
| <a name="input_region"></a> [region](#input\_region) | GCP region for resources | `string` | `"us-east5"` | no |
| <a name="input_rollout_allowed_ipv4"></a> [rollout\_allowed\_ipv4](#input\_rollout\_allowed\_ipv4) | CIDR IPv4 ranges allowed to reach the rollout service port. | `list(string)` | <pre>[<br/>  "10.0.0.0/8"<br/>]</pre> | no |
| <a name="input_rollout_custom_claims"></a> [rollout\_custom\_claims](#input\_rollout\_custom\_claims) | Optional JSON object of additional JWT claims required by the rollout service. | `string` | `""` | no |
| <a name="input_rollout_enabled"></a> [rollout\_enabled](#input\_rollout\_enabled) | Install and run the optional generic rollout HTTP service on the VM. | `bool` | `false` | no |
| <a name="input_rollout_jwks_uri"></a> [rollout\_jwks\_uri](#input\_rollout\_jwks\_uri) | JWKS URI used by the rollout service to validate bearer JWTs. | `string` | `""` | no |
| <a name="input_rollout_jwt_audience"></a> [rollout\_jwt\_audience](#input\_rollout\_jwt\_audience) | JWT audience required by the rollout service. | `string` | `""` | no |
| <a name="input_rollout_port"></a> [rollout\_port](#input\_rollout\_port) | TCP port exposed by the optional rollout service. | `number` | `8081` | no |
| <a name="input_rollout_release_sha256"></a> [rollout\_release\_sha256](#input\_rollout\_release\_sha256) | Lowercase SHA256 checksum for var.rollout\_release\_url. | `string` | `""` | no |
| <a name="input_rollout_release_url"></a> [rollout\_release\_url](#input\_rollout\_release\_url) | HTTPS URL for the pinned rollout Linux binary. | `string` | `""` | no |
| <a name="input_rootfs"></a> [rootfs](#input\_rootfs) | Path to additional rootfs files to copy into the VM. Files will be merged with the base rootfs. Example: '/path/to/custom/rootfs' | `string` | `""` | no |
| <a name="input_run_snapshots"></a> [run\_snapshots](#input\_run\_snapshots) | Enable daily snapshots of the data disk (recommended for production). Last seven days of snapshots are available. Also weekly snapshots for past year. | `bool` | `false` | no |
| <a name="input_runcmd"></a> [runcmd](#input\_runcmd) | Additional commands to run during cloud-init. Commands are executed after the main initialization. | `list(string)` | `[]` | no |
| <a name="input_service_account_email"></a> [service\_account\_email](#input\_service\_account\_email) | Existing service account email for the VM. When empty, this module creates one. | `string` | `""` | no |
| <a name="input_sitectl_context_name"></a> [sitectl\_context\_name](#input\_sitectl\_context\_name) | Sitectl context name to create on the VM. Defaults to var.name. | `string` | `""` | no |
| <a name="input_sitectl_environment"></a> [sitectl\_environment](#input\_sitectl\_environment) | Sitectl environment label. Production runs healthcheck only by default; non-production also runs sitectl verify. | `string` | `"production"` | no |
| <a name="input_sitectl_healthcheck_interval"></a> [sitectl\_healthcheck\_interval](#input\_sitectl\_healthcheck\_interval) | Interval passed to sitectl healthcheck --interval in default lifecycle commands. | `string` | `"15s"` | no |
| <a name="input_sitectl_healthcheck_timeout"></a> [sitectl\_healthcheck\_timeout](#input\_sitectl\_healthcheck\_timeout) | Timeout passed to sitectl healthcheck --timeout in default lifecycle commands. | `string` | `"10m"` | no |
| <a name="input_sitectl_packages"></a> [sitectl\_packages](#input\_sitectl\_packages) | LibOps GitHub release package names to install and keep updated on the VM. Include plugin packages such as sitectl-isle or sitectl-wp as needed. | `list(string)` | <pre>[<br/>  "sitectl"<br/>]</pre> | no |
| <a name="input_sitectl_plugin"></a> [sitectl\_plugin](#input\_sitectl\_plugin) | Sitectl plugin id to associate with the VM context. | `string` | `"core"` | no |
| <a name="input_sitectl_verify_args"></a> [sitectl\_verify\_args](#input\_sitectl\_verify\_args) | Additional arguments appended to sitectl verify by the default non-production lifecycle commands. | `list(string)` | `[]` | no |
| <a name="input_sitectl_version"></a> [sitectl\_version](#input\_sitectl\_version) | Sitectl release tag to install for sitectl packages, or latest to follow https://github.com/libops/sitectl/releases/latest. | `string` | `"latest"` | no |
| <a name="input_users"></a> [users](#input\_users) | Map of usernames to lists of SSH public keys. Users will be created with docker group membership. Example: { "alice" = ["ssh-rsa AAAA..."], "bob" = ["ssh-ed25519 AAAA...", "ssh-rsa BBBB..."] } | `map(list(string))` | `{}` | no |
| <a name="input_volume_names"></a> [volume\_names](#input\_volume\_names) | List of docker volumes to overlay from production snapshot (e.g., ['compose\_ojs-public']). Production data is mounted read-only as lower layer, staging writes go to upper layer. | `list(string)` | `[]` | no |
| <a name="input_zone"></a> [zone](#input\_zone) | GCP zone for resources | `string` | `"us-east5-b"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_appGsa"></a> [appGsa](#output\_appGsa) | The Google Service Account the app can leverage to auth to other Google services |
| <a name="output_backend"></a> [backend](#output\_backend) | Backend service ID for attaching the Cloud Run ingress to an external HTTPS load balancer. |
| <a name="output_external_ip"></a> [external\_ip](#output\_external\_ip) | The Google Compute instance external IPv4 address. |
| <a name="output_instance"></a> [instance](#output\_instance) | The Google Compute instance ID, name, zone, data disk, GSA for the instance. |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | The Google Compute instance ID. |
| <a name="output_internal_ip"></a> [internal\_ip](#output\_internal\_ip) | The Google Compute instance internal IPv4 address. |
| <a name="output_rollout"></a> [rollout](#output\_rollout) | Optional rollout API endpoint details. The URL is the VPC-internal endpoint. |
| <a name="output_serviceGsa"></a> [serviceGsa](#output\_serviceGsa) | The Google Service Account internal services that manage the VM runs as |
| <a name="output_urls"></a> [urls](#output\_urls) | Cloud Run ingress URLs by region. |
<!-- END_TF_DOCS -->
