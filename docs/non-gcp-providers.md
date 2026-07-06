# Provider Entrypoints And On-Prem

Provider-specific Terraform entrypoint modules keep downstream consumers from
loading unused cloud providers. Use these paths instead of the root module when
the caller already knows the target cloud:

- `providers/gcp`
- `providers/do`
- `providers/linode`

DigitalOcean and Linode share the same Linux runtime contract as the GCP module:

- mount a persistent app/data disk at `/mnt/disks/data`
- mount a persistent Docker-volume disk at `/mnt/disks/volumes`
- bind-mount `/mnt/disks/volumes` to `/mnt/disks/data/docker/volumes`
- run the cloud-compose rootfs bootstrap after mounts are ready
- set `POWER_MANAGEMENT_ENABLED=false`
- set `CLOUD_COMPOSE_PROVIDER` to `digitalocean` or `linode`
- create one firewall rule per compose app ingress port

Destroying or replacing the VM should not destroy either persistent volume
unless the whole Terraform stack is destroyed. This matches the GCP module's
data disk and Docker-volume disk behavior.

Fedora CoreOS should use the CoreOS installer path. Debian and Ubuntu should use
the apt installer path. Both paths install the same minimum runtime surface:

- Docker
- Docker Compose
- Docker Buildx
- Git
- jq
- make
- `sitectl` and selected plugins

DigitalOcean and Linode do not currently have a cloud-compose workload identity
contract equivalent to GCP IAM for Vault Agent. Their modules default
`vault_auth_method` to `consumer-managed`. When `vault_agent_enabled=true`, pass
the auth method through `vault_agent_additional_config` or a rootfs overlay.

## Existing Debian/Ubuntu Hosts

Use the Ansible role or Salt formula when Terraform should not create the VM,
disk, firewall, or DNS. These adapters install the packaged cloud-compose rootfs,
write `.env`, write `compose-projects.json`, reload systemd, and optionally run
the bootstrap.

- Ansible role: `ansible/roles/cloud_compose`
- Ansible playbook example: `ansible/playbooks/site.yml`
- Salt formula: `salt/cloud-compose`
- Shared template registry: `templates/apps.json`

The packaged runtime currently assumes fixed host paths:

- `/home/cloud-compose`
- `/mnt/disks/data`
- `/mnt/disks/volumes`

For one app per host, assign each app host its own Ansible inventory variables
or Salt pillar. For multiple apps on one host, pass the same
`runtime.compose.projects` shape used by Terraform, but that is an explicit
bin-packing choice rather than the default on-prem layout.

Ansible inventory example:

```yaml
all:
  children:
    cloud_compose:
      hosts:
        isle-prod.example.edu:
          cloud_compose_name: isle-prod
          cloud_compose_template: isle
        wp-prod.example.edu:
          cloud_compose_name: wp-prod
          cloud_compose_template: wp
```

Salt pillar top example:

```yaml
base:
  'isle-prod.example.edu':
    - cloud-compose.isle-prod
  'wp-prod.example.edu':
    - cloud-compose.wp-prod
```

## DigitalOcean

Use `DIGITALOCEAN_TOKEN` or an explicit DigitalOcean provider configuration in
the calling stack. Prefer the provider-specific entrypoint so Terraform only
loads the DigitalOcean provider while the app template still selects the compose
repo, `sitectl` plugin, and plugin package defaults:

```hcl
module "wp" {
  source = "github.com/libops/cloud-compose//providers/do"

  name     = "cc-wp"
  template = "wp"
  digitalocean = {
    region = "tor1"
    ssh = {
      cloud_compose_keys = var.operator_ssh_keys
    }
  }
}
```

## Linode

Use `LINODE_TOKEN` or an explicit Linode provider configuration in the calling
stack. Linode metadata is tighter than DigitalOcean, so CI and examples can pass
`rootfs_archive_url` when the embedded cloud-init payload would be too large:

```hcl
module "drupal" {
  source = "github.com/libops/cloud-compose//providers/linode"

  name     = "cc-drupal"
  template = "drupal"
  linode = {
    region = "us-east"
    instance = {
      authorized_keys = var.operator_ssh_keys
    }
    ssh = {
      cloud_compose_keys = var.operator_ssh_keys
    }
  }
  runtime = {
    rootfs_archive_url = "https://github.com/libops/cloud-compose/archive/main.tar.gz"
  }
}
```
