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
the calling stack.

```hcl
module "wp" {
  source = "./modules/digitalocean"

  name                   = "cc-wp"
  region                 = "tor1"
  ssh_keys               = var.digitalocean_ssh_keys
  cloud_compose_ssh_keys = var.operator_ssh_keys
  docker_compose_repo    = "https://github.com/libops/wp.git"
  sitectl_packages       = ["sitectl", "sitectl-wp"]
  sitectl_plugin         = "wp"
}
```

## Linode

Use `LINODE_TOKEN` or an explicit Linode provider configuration in the calling
stack.

```hcl
module "drupal" {
  source = "./modules/linode"

  name                   = "cc-drupal"
  region                 = "us-east"
  authorized_keys        = var.operator_ssh_keys
  cloud_compose_ssh_keys = var.operator_ssh_keys
  docker_compose_repo    = "https://github.com/libops/drupal.git"
  sitectl_packages       = ["sitectl", "sitectl-drupal"]
  sitectl_plugin         = "drupal"
}
```
