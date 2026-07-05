# DigitalOcean And Linode

DigitalOcean and Linode use provider-specific Terraform modules that share the
same Linux runtime contract as the GCP module:

- `modules/digitalocean`
- `modules/linode`

Both modules:

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

## DigitalOcean

Use `DIGITALOCEAN_TOKEN` or an explicit DigitalOcean provider configuration in
the calling stack. Prefer the root module contract so the app template selects
the compose repo, `sitectl` plugin, and plugin package defaults:

```hcl
module "wp" {
  source = "../.."

  name           = "cc-wp"
  cloud_provider = "digitalocean"
  template       = "wp"
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
  source = "../.."

  name           = "cc-drupal"
  cloud_provider = "linode"
  template       = "drupal"
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
