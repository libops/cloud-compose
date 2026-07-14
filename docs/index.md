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
- Nightly MariaDB backups through systemd timers

## Start here

- [Runtime contracts](runtime-contracts.md) explains the VM/app contract.
- [GCP foundation and application states](runtime-contracts.md#gcp-foundation-and-application-states) explains singleton API/IAM ownership, Shared VPC, and Direct VPC egress.
- [Managed runtime](managed-runtime.md) covers host tools and internal services.
- [Rollout API](rollout.md) covers authenticated deploy triggers.
- [Provider entrypoints and on-prem](non-gcp-providers.md) covers non-GCP and existing-host boundaries.
- [Examples](examples.md) covers the example modules.
