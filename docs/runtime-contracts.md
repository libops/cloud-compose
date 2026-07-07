# Runtime Contracts

`cloud-compose` treats Git as the desired application state and `sitectl` as the
runtime reconciler. Terraform provisions durable infrastructure and writes the
VM contract; boot and rollout then use `sitectl` to move each compose project to
the desired state.

## Compose Apps

The default shape is one compose app per VM or existing host. Use
`compose_projects` to run more than one compose app on the same machine. Each
map entry gets:

- a git checkout
- a `sitectl` local context
- a compose project name
- an ingress port
- init/up/down/rollout commands

`primary_compose_project` selects the app used by Cloud Run power-management
ingress and the default rollout endpoint. Bin-packing policy is intentionally
not implemented yet; callers decide which apps share a VM.

Every app should expose a distinct host port through its compose/Traefik config.
The generated app env file exports `COMPOSE_BIND_PORT` for that purpose.

## Sitectl

During init, the VM creates a `sitectl` context for every app. The default up and
rollout commands use `sitectl deploy`, which now reuses the compose reconcile
path before `docker compose up`. This means plugin-declared init artifacts,
volumes, and buildable images are repaired during normal deployment.

## Vault

`cloud-compose` defines the Vault contract and leaves product-specific Vault
roles, policies, mounts, and secret paths to consumers.

GCP defaults to Vault GCP IAM auth with the app GSA identity, not the VM GSA. The
VM still uses its broader GSA for host work such as logs and key rotation. The
app GSA key is rotated into:

- `/mnt/disks/data/cloud-compose/app/GOOGLE_APPLICATION_CREDENTIALS`
- each app's `secrets/GOOGLE_APPLICATION_CREDENTIALS`

Vault Agent can use that credential to authenticate as the app identity and
render files for compose projects. DigitalOcean and Linode do not currently
provide a matching GCP-style workload identity contract here; use
`vault_auth_method = "consumer-managed"` and provide auth config through
`vault_agent_additional_config` or consumer rootfs overlays.

## OS Families

Dependency installation dispatches by OS family:

- COS: installs Docker Compose, Buildx, and `make` into writable paths.
- Fedora CoreOS: configures the LibOps RPM repo, installs host packages with
  `rpm-ostree install --apply-live`, and installs Docker CLI plugins.
- Debian/Ubuntu: installs Docker, Git, jq, make, and CA/curl packages with apt,
  then installs Docker CLI plugins.

Provider modules should mount persistent data and Docker-volume disks before the
runtime starts. Destroying/recreating the VM must not destroy these volumes.

The Ansible role and Salt formula skip cloud infrastructure creation. They
assume Debian/Ubuntu hosts already have suitable network, DNS, firewall, and
storage policy, then install the same rootfs and write the same runtime files
Terraform would have written through cloud-init.

## Backups

`cloud-compose-mariadb-backup.timer` runs nightly between 9pm and 7am EST. It
uses a fixed randomized delay so deployments spread out across that window while
keeping a stable schedule on each VM. The timer executes:

```bash
sitectl mariadb backup --context "$SITECTL_CONTEXT_NAME" --gzip --output "$path"
```

for every app context. Backups are written under
`/mnt/disks/data/backups/mariadb/<app>/` by default.

## Power Management

`power_management_enabled` gates GCP-specific cost-saving behavior:

- Cloud Run proxy-power-button ingress
- the `lightsout` internal-service profile

DigitalOcean and Linode deployments should leave power management disabled
because stopped VMs do not provide the same cost profile.
