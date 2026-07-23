# Provider Entrypoints And On-Prem

Provider-specific Terraform entrypoint modules keep downstream consumers from
loading unused cloud providers. New callers should always select one of these
paths:

- `providers/gcp`
- `providers/do`
- `providers/linode`

The repository root remains a GCP-only compatibility entrypoint for existing
GCP state. It intentionally has no DigitalOcean or Linode provider dependency.
DigitalOcean and Linode callers that previously selected `cloud_provider` on
the root module must move to their provider-specific source path as a separately
reviewed state migration. Terraform cannot conditionally load a statically
declared child module's provider, even when that module has `count = 0`.

## Migrating A 1.x Root Deployment

GCP callers can keep the root source path and module block name unchanged. The
root retains its historical `module.gcp[0]` address and now loads only GCP-
related providers. A GCP caller can move to `providers/gcp` later, but that is a
separate state refactor and is not required to remove DigitalOcean or Linode.

DigitalOcean and Linode callers must change the module source at 1.3.0 while
keeping the caller's module block name unchanged. For example:

```hcl
module "site" {
  source = "github.com/libops/cloud-compose//providers/do?ref=1.3.0"

  # Keep the existing name, template, digitalocean, and runtime values.
}

moved {
  from = module.site.module.digitalocean[0]
  to   = module.site.module.digitalocean
}
```

The Linode equivalent is:

```hcl
module "site" {
  source = "github.com/libops/cloud-compose//providers/linode?ref=1.3.0"

  # Keep the existing name, template, linode, and runtime values.
}

moved {
  from = module.site.module.linode[0]
  to   = module.site.module.linode
}
```

Place the `moved` block in the caller's root module, not inside a downstream
fork of cloud-compose. Back up remote state, initialize the new exact source,
and review the plan before applying. The plan must show the existing VM,
firewall, and both durable volumes moving addresses without replacement or
deletion. If the caller's block is not named `site`, substitute its actual name
in both addresses. Keep the `moved` block in version control for at least one
complete rollout across every workspace that shares the configuration.

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

Cloud-init records both stable provider `/dev/disk/by-id` devices and the
Docker bind mount in `/etc/fstab`. A Docker systemd drop-in and every service
that reads durable state use `RequiresMountsFor`, so a reboot fails the service
closed instead of writing app or Docker data into an unmounted root-disk
directory. The filesystem helper verifies ext4, repairs only safe fsck statuses,
and runs `resize2fs` after a provider volume grows; increasing either Terraform
volume size therefore exposes the added capacity on the next boot without
reformatting the filesystem. Never shrink these volume inputs.

Provider VM backup toggles do **not** protect application state:
DigitalOcean's `droplet.backups` covers the Droplet disk but excludes attached
Volumes, and Linode's `instance.backups_enabled` excludes Block Storage. The
nightly MariaDB dumps under `/mnt/disks/data/backups` are useful for logical
recovery, but they live on the same data volume and are not disaster recovery.
Also, `terraform destroy` intentionally deletes both managed volumes.

Before production, establish an independently owned offsite policy for both
volumes (provider volume snapshots where available, or encrypted export to
separate object storage/account), define retention separately from this
application state, and test a restore into disposable new volumes. A restore is
complete only after the Compose projects start, `sitectl healthcheck` passes,
and representative files plus database records are verified. Do not enable a
boot-disk backup toggle and record the application as protected.

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
contract equivalent to GCP IAM for Vault Agent. The GCP entrypoints resolve
`runtime.vault.auth_method = "auto"` to `gcp-iam`; the DigitalOcean and Linode
entrypoints resolve it to `consumer-managed`. When the Terraform-managed agent
is enabled with `consumer-managed`, supply the auth stanza through
`runtime.vault.agent_additional_config` or a rootfs overlay.

Provider-neutral `runtime.users` applies on every cloud. DigitalOcean and Linode
also accept users under their provider-specific `ssh.users` map; a
provider-specific entry wins when the same username appears in both maps.

## Existing Debian/Ubuntu Hosts

Use the Ansible role or Salt formula when Terraform should not create the VM,
disk, firewall, or DNS. These adapters install the packaged cloud-compose rootfs,
write `.env`, write `compose-projects.json`, reload systemd, and optionally run
the bootstrap. Like the Terraform providers, both adapters start
`cloud-compose-bootstrap.service` and wait for its durable readiness marker;
transient bootstrap and application-service failures retry after 30 seconds.
The Ansible role's four-hour async budget is intentionally longer than the
starter's bounded three-hour wait. Inspect failures in
`journalctl -u cloud-compose-bootstrap` and with
`systemctl status cloud-compose-bootstrap cloud-compose`; the systemd journal
is the canonical bootstrap log.

These adapters are for a dedicated, empty application host. They install and
restart Docker with `/mnt/disks/data/docker` as its data root, install
cloud-compose systemd services and timers, and can replace host Fluent Bit and
Vault Agent unit configuration. Applying either adapter to a shared Docker,
logging, or Vault host can interrupt unrelated workloads. The destructive
ownership boundary is enforced by an acknowledgement that defaults to false:

```yaml
# Ansible inventory
cloud_compose_dedicated_host_acknowledged: true

# Salt pillar
cloud_compose:
  dedicated_host_acknowledged: true
```

Set it only after mounting durable storage at the fixed paths below and
confirming the host has no unrelated Docker containers, logging agent, Vault
Agent, cron workload, or conflicting systemd units. A repeated configuration-
management apply updates runtime files but does not automatically rerun app
initialization. Use `cloud_compose_force_bootstrap: true` with Ansible or
`force_bootstrap: true` in Salt only in a planned maintenance window.

The first adapter upgrade from a release that used
`/mnt/disks/data/.cloud-compose-lifecycle.lock` must also happen in a planned
maintenance window. Stop the rollout service and lifecycle timers, allow any
in-flight rollout, backup, or managed-runtime service to finish, apply the
adapter, and then restore the previously enabled services and timers. This
prevents an old process holding the data-disk lock from overlapping a new
process using `/run/lock/cloud-compose/lifecycle.lock`. The adapter creates and
repairs the new root-owned lock on every apply; this one-time quiescence is not
needed for later upgrades that already use the `/run` lock.

The adapters reject `runtime.vault.agent_enabled = true`; Terraform is currently
the only supported owner of generated Vault Agent configuration. They also
reserve `HOME`, `PATH`, and the `CLOUD_COMPOSE_*`, `COMPOSE_*`, `DOCKER_*`,
`SITECTL_*`, `LIBOPS_*`, `GCP_*`, `VAULT_*`, `ROLLOUT_*`, and
`POWER_MANAGEMENT_*` host-control namespaces. Use `runtime.extra_env` only for
unreserved application settings such as `PHP_*` or `NGINX_*` tuning. The
adapter writes these values to `/home/cloud-compose/application-env.json`; init
reconciles them into every Compose project's `.env` without exporting them to
host processes.
The older Ansible `cloud_compose_extra_env` variable and Salt top-level
`extra_env` pillar remain compatibility fallbacks when the nested map is
omitted.

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

CI verifies the local adapters with `make config-management-smoke`. The cloud
smoke path provisions a raw Linode VM, prepares the fixed data boundary, then
deploys Drupal through Ansible or Salt into
`/mnt/disks/data/libops/drupal/main` without using the cloud-compose Terraform
module:

```bash
LINODE_TOKEN=... make config-management-cloud-smoke METHOD=ansible
LINODE_TOKEN=... make config-management-cloud-smoke METHOD=salt
```

## DigitalOcean

Use `DIGITALOCEAN_TOKEN` or an explicit DigitalOcean provider configuration in
the calling stack. Prefer the provider-specific entrypoint so Terraform only
loads the DigitalOcean provider while the app template still selects the compose
repo, `sitectl` plugin, and plugin package defaults:

```hcl
module "wp" {
  source = "github.com/libops/cloud-compose//providers/do?ref=1.0.0"

  name     = "cc-wp"
  template = "wp"
  digitalocean = {
    region = "tor1"
    ssh = {
      cloud_compose_keys = var.operator_ssh_keys
    }
  }
  runtime = {
    rootfs_archive_url    = "https://github.com/libops/cloud-compose/releases/download/1.0.0/cloud-compose-rootfs.tar.gz"
    rootfs_archive_sha256 = var.cloud_compose_rootfs_sha256
  }
}
```

The `1.0.0` ref is intentional. Replace it only with an exact reviewed release
or full commit. DigitalOcean limits Droplet `user_data` to 64 KiB, and the full
managed runtime no longer fits safely inline. Use the integrity-pinned archive
pair shown above; Terraform rejects an oversized inline payload before calling
the Droplet API. The default DigitalOcean SSH firewall sources include the
public internet; production callers should set
`digitalocean.firewall.ssh_source_addresses` to institutional or operator
CIDRs instead of inheriting that default.

Cloud-compose, rather than DigitalOcean's creation-time automount, owns new
volume formatting and the fixed mount paths. The module ignores the historical
`initial_filesystem_type` state so upgrading an existing deployment does not
replace either durable volume. When an older volume still has DigitalOcean's
generated `/mnt/<volume_name>` unit, bootstrap waits for udev, validates the
exact device, unit, and single mount source, moves that mount to the fixed data
boundary, and retires only the verified provider persistence entry. An
unexpected or duplicate mount fails closed before `fsck`, formatting, or mount
mutation. Do not add `initial_filesystem_type` back downstream or separately
mount the same writable device; review upgrade plans to ensure both volume IDs
remain unchanged.

## Linode

Use `LINODE_TOKEN` or an explicit Linode provider configuration in the calling
stack. Linode metadata has a 16 KiB limit, so CI and examples pass
`rootfs_archive_url` instead of embedding the managed rootfs. Archive mode is
an integrity-pinned input: set an immutable HTTPS source ref and the SHA-256 of
the exact downloaded archive together. Terraform rejects a non-HTTPS URL, a URL
without a checksum, a checksum without a URL, and malformed digests. The VM
restricts redirects to HTTPS with TLS 1.2 or newer and verifies the checksum
before extracting any archive content.

```hcl
module "drupal" {
  source = "github.com/libops/cloud-compose//providers/linode?ref=1.0.0"

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
    rootfs_archive_url    = "https://github.com/libops/cloud-compose/releases/download/1.0.0/cloud-compose-rootfs.tar.gz"
    rootfs_archive_sha256 = var.cloud_compose_rootfs_sha256
  }
}
```

Linode also defaults SSH ingress to the public internet. Set
`linode.firewall.ssh_source_ipv4` and `ssh_source_ipv6` to reviewed operator
CIDRs. Replace the `1.0.0` module ref only with an exact release or full commit
your organization has reviewed.

Use the canonical `cloud-compose-rootfs.tar.gz` and adjacent `.sha256` release
assets. They are built reproducibly from the tagged `rootfs/` tree; GitHub's
generated repository source archives are not a stable long-term checksum
boundary because GitHub may regenerate their outer compression. CI may use a
commit archive only within the same run while testing an unreleased commit.
Download the release asset through the same URL consumers will use and verify
its published checksum before planning the deployment.
