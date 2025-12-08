# cloud-compose

Deploy a docker compose project to a Google Cloud Compute Instance.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.2.4 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 7.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cloudinit"></a> [cloudinit](#provider\_cloudinit) | 2.3.7 |
| <a name="provider_google"></a> [google](#provider\_google) | 7.12.0 |
| <a name="provider_time"></a> [time](#provider\_time) | n/a |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_ppb"></a> [ppb](#module\_ppb) | git::https://github.com/libops/terraform-cloudrun-v2 | 0.5.0 |

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
| [google_compute_instance.cloud-compose](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance) | resource |
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
| <a name="input_disk_size_gb"></a> [disk\_size\_gb](#input\_disk\_size\_gb) | Data disk size in GB | `number` | `50` | no |
| <a name="input_docker_compose_branch"></a> [docker\_compose\_branch](#input\_docker\_compose\_branch) | git branch to checkout for var.docker\_compose\_repo | `string` | `"main"` | no |
| <a name="input_docker_compose_down"></a> [docker\_compose\_down](#input\_docker\_compose\_down) | Command to stop the docker compose project | `string` | `"docker compose down"` | no |
| <a name="input_docker_compose_init"></a> [docker\_compose\_init](#input\_docker\_compose\_init) | After cloning the docker compose git repo, any initialization that needs to happen before the docker compose project can start | `string` | `""` | no |
| <a name="input_docker_compose_up"></a> [docker\_compose\_up](#input\_docker\_compose\_up) | Command to start the docker compose project | `string` | `"docker compose up --remove-orphans"` | no |
| <a name="input_machine_type"></a> [machine\_type](#input\_machine\_type) | VM machine type (General-purpose series that support Hyperdisk Balanced | `string` | `"n4-standard-2"` | no |
| <a name="input_os"></a> [os](#input\_os) | The host OS to install on the GCP instance | `string` | `"cos-125-19216-104-25"` | no |
| <a name="input_overlay_source_instance"></a> [overlay\_source\_instance](#input\_overlay\_source\_instance) | Name of production instance to get latest snapshot from (e.g., 'ojs-production'). Terraform will automatically use the most recent snapshot from this instance's data disk. Leave empty for production environments. | `string` | `""` | no |
| <a name="input_region"></a> [region](#input\_region) | GCP region for resources | `string` | `"us-east5"` | no |
| <a name="input_run_snapshots"></a> [run\_snapshots](#input\_run\_snapshots) | Enable daily snapshots of the data disk (recommended for production). Last seven days of snapshots are available. Also weekly snapshots for past year. | `bool` | `false` | no |
| <a name="input_users"></a> [users](#input\_users) | Map of usernames to lists of SSH public keys. Users will be created with docker group membership. Example: { "alice" = ["ssh-rsa AAAA..."], "bob" = ["ssh-ed25519 AAAA...", "ssh-rsa BBBB..."] } | `map(list(string))` | `{}` | no |
| <a name="input_volume_names"></a> [volume\_names](#input\_volume\_names) | List of docker volumes to overlay from production snapshot (e.g., ['compose\_ojs-public']). Production data is mounted read-only as lower layer, staging writes go to upper layer. | `list(string)` | `[]` | no |
| <a name="input_zone"></a> [zone](#input\_zone) | GCP zone for resources | `string` | `"us-east5-b"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_appGsa"></a> [appGsa](#output\_appGsa) | The Google Service Account the app can leverage to auth to other Google services |
| <a name="output_instance"></a> [instance](#output\_instance) | The Google Compute instance ID, name, zone, data disk, GSA for the instance. |
| <a name="output_serviceGsa"></a> [serviceGsa](#output\_serviceGsa) | The Google Service Account internal services that manage the VM runs as |
<!-- END_TF_DOCS -->
