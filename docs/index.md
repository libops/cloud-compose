# cloud-compose

`cloud-compose` runs Docker Compose projects on cloud VMs while keeping Git as
the desired application state and `sitectl` as the application reconciler.

Terraform owns durable cloud infrastructure. Existing Debian/Ubuntu hosts can
consume the same runtime through the Ansible role or Salt formula when another
system already owns the OS, network, storage, DNS, and firewall.

The VM runtime installs Docker, Docker Compose, Docker Buildx, `sitectl`,
selected sitectl plugins, and host support services. During init it checks out
each compose repository, creates a sitectl context, and starts the app through
the same lifecycle path used by later rollouts.

## What it provides

- Compose app lifecycle management through `sitectl`
- Multi-app VM support through `compose_projects`
- GCP foundation/application state and identity separation
- Optional Vault Agent contract
- Optional GCP power management through Cloud Run and lightsout
- Provider-neutral runtime contracts for DigitalOcean and Linode
- Existing-host deployment through Ansible or Salt
- Nightly local MariaDB recovery dumps plus an optional provider-neutral,
  encrypted off-host DR driver and scheduled restore proofs

## Who owns what

| Surface | Owner | Change path |
|---|---|---|
| VM identity, network/firewall, attached disks, provider snapshots | Terraform provider entrypoint | Reviewed plan/apply; changes may replace the VM but preserve provider-managed disks only where the plan says so |
| Host packages, systemd units, pinned support binaries | cloud-compose runtime | Terraform replacement/bootstrap, or Ansible/Salt for an existing host |
| App source revision on an existing VM | Authenticated rollout endpoint or operator-run `/home/cloud-compose/rollout` | `sitectl deploy` against an explicit ref and manifest app key |
| App Compose behavior and health verification | sitectl plugin/component definitions | Versioned plugin release and normal lifecycle commands |
| Secrets and private forge credentials | Vault/operator secret delivery | Short-lived files rendered outside Terraform state |
| Local logical backup and off-host disaster recovery | cloud-compose timers plus operator-owned DR driver | Local dumps are pruned after 14 days; a strict receipt proves encrypted independent coverage and a scheduled disposable restore |

Any cloud-init byte can change the GCP boot-disk identity and replace the VM;
cloud-init is bootstrap configuration, not the day-2 app update channel. Keep
routine source deployments in rollout and application behavior in sitectl.

## Start here

- [Runtime contracts](runtime-contracts.md) explains the VM/app contract.
- [Disaster recovery](disaster-recovery.md) defines the off-host driver,
  receipts, restore proofs, and operator checks.
- [GCP foundation and application states](runtime-contracts.md#gcp-foundation-and-application-states) explains singleton API/IAM ownership, Shared VPC, and Direct VPC egress.
- [Managed runtime](managed-runtime.md) covers host tools and internal services.
- [Rollout API](rollout.md) covers authenticated deploy triggers.
- [Provider entrypoints and on-prem](non-gcp-providers.md) covers non-GCP and existing-host boundaries.
- [Examples](examples.md) covers the example modules.
