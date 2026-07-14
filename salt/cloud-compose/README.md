# cloud-compose Salt Formula

This formula deploys the cloud-compose runtime onto an existing Debian or
Ubuntu host. Use it when Salt already manages the OS, network, storage, DNS, and
firewall, and cloud-compose should only manage the application runtime.

The formula reads `templates/apps.json`, so template defaults stay shared with
the Terraform provider modules and the Ansible role.

The packaged runtime currently uses fixed host paths: `/home/cloud-compose`,
`/mnt/disks/data`, and `/mnt/disks/volumes`.

Every resolved Compose `project_dir` must be a normalized, non-root descendant
of `/mnt/disks/data`. Before installing packages, creating accounts, or changing
files, the formula resolves existing symlinks on the minion and rejects `/`,
`/etc`, traversal, repeated/empty segments, control characters, and any symlink
escape outside that boundary. The production boundary is intentionally not
configurable.

The same preflight validates `runtime.managed_runtime.artifacts` before writing
the host manifest. Artifact names are safe basenames of at most 128 characters;
URLs are HTTPS; checksums are 64 lowercase hex characters; target paths are
non-root, normalized absolute paths; modes match `0?[0-7]{3}`; owners/groups are
safe local account names; and an optional restart target is a safe `.service`
unit. Names and target paths must be unique.

At install time, every artifact target directory must already exist through a
canonical installer-controlled directory chain. Symlinked ancestors and
group/other-writable non-sticky directories are rejected before download.

This formula is intentionally limited to a dedicated, empty application host.
It installs cloud-compose files over host Docker, Fluent Bit, Vault Agent, and
systemd locations and restarts Docker during bootstrap. Confirm durable storage
is mounted at the fixed paths and that no unrelated workloads use those host
services before setting the required acknowledgement:

```yaml
cloud_compose:
  dedicated_host_acknowledged: true
```

The formula rejects `runtime.vault.agent_enabled: true`; generated Vault Agent
configuration is currently Terraform-only. It also rejects
`runtime.extra_env` entries
named `HOME` or `PATH`, or beginning with `CLOUD_COMPOSE_`, `COMPOSE_`,
`DOCKER_`, `SITECTL_`, `LIBOPS_`, `GCP_`, `VAULT_`, `ROLLOUT_`, or
`POWER_MANAGEMENT_`. Those names belong to the host control plane; use
unreserved application-specific names for tuning. The formula writes those
settings as JSON data at `/home/cloud-compose/application-env.json`, and app
init reconciles them into each Compose project without exporting them into host
processes.
Top-level `extra_env` remains a compatibility fallback when the nested map is
omitted.

The on-prem formula rejects
`cloud_compose.runtime.managed_runtime.internal_services_enabled: true`
because the current CAP/lightsout stack and its credentials are GCP-specific.
Compose ingress ports must be whole numbers from 1 through 65535. Lifecycle
values (`runtime.compose.init`, `up`, `down`, and `rollout`, plus their
per-project `docker_compose_*` overrides) must be lists of strings. An explicit
empty list disables that phase and is preserved instead of restoring a default.
Runtime feature switches must be YAML booleans, not quoted strings; ambiguous
values are rejected before host mutation.

The formula installs lifecycle dispatchers as `root:cloud-compose` mode `0750`
and the root-consumed `.env`, project/application JSON, and managed-artifact
manifest as `root:cloud-compose` mode `0640`. Reapplying the state restores that
ownership boundary while leaving application checkout directories writable by
the `cloud-compose` account.

The normal on-prem shape is one app per machine. Use pillar targeting to give
each minion its own `cloud_compose` values, then apply the same
`cloud-compose` state to every app host.

Your Salt `file_roots` must expose both the formula and repository root so the
formula and packaged rootfs resolve. Your `pillar_roots` should point at your
environment-specific pillar tree:

```yaml
file_roots:
  base:
    - /srv/cloud-compose/salt
    - /srv/cloud-compose
pillar_roots:
  base:
    - /srv/cloud-compose/salt/pillar.example
```

Example pillar top:

```yaml
base:
  'isle-prod.example.edu':
    - cloud-compose.isle-prod
  'wp-prod.example.edu':
    - cloud-compose.wp-prod
```

Example per-host pillar:

```yaml
cloud_compose:
  name: isle-prod
  template: isle
  dedicated_host_acknowledged: true
  runtime:
    compose:
      ingress:
        domain: isle.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
      package_versions:
        sitectl-isle: v0.18.0
```

Apply:

```bash
salt 'isle-prod.example.edu' state.apply cloud-compose
salt 'wp-prod.example.edu' state.apply cloud-compose
```

`cloud_compose.runtime.sitectl.package_versions` pins individual release
packages. The selected template supplies an exact compatible default set; an
explicit entry overrides the matching template selector. Template selectors
are filtered to the effective installed package list, so replacing `packages`
does not retain selectors for removed plugins. An installed package with no
template or explicit selector uses the legacy
`cloud_compose.runtime.sitectl.version` fallback, which defaults to `latest`.
The top-level `cloud_compose.sitectl_version` and
`cloud_compose.sitectl_package_versions` values remain supported as fallbacks
for existing pillars.

Omit `cloud_compose.runtime.sitectl.packages` to use the selected template's
package set. An explicit empty list selects only the core `sitectl` package.
For a multi-project host, an omitted project `sitectl_packages` value inherits
the global set. The host installs the union of global and project package
lists, so a project can add a package but cannot remove one selected globally
or by another project.
