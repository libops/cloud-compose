# cloud-compose Ansible Adapter

This role deploys the cloud-compose runtime onto an existing Debian or Ubuntu
host. Use it when Terraform should not create the VM, disks, firewall, or DNS.

The role consumes the same `templates/apps.json` template defaults used by the
Terraform provider modules.

The packaged runtime currently uses fixed host paths: `/home/cloud-compose`,
`/mnt/disks/data`, and `/mnt/disks/volumes`.

Every resolved Compose `project_dir` must be a normalized, non-root descendant
of `/mnt/disks/data`. Before installing packages, creating accounts, or changing
files, the role resolves existing symlinks on the target and rejects `/`,
`/etc`, traversal, repeated/empty segments, control characters, and any symlink
escape outside that boundary. The production boundary is intentionally not
configurable. By default, the role derives
`/mnt/disks/data/<repository path>/<application key>`; changing a branch, tag,
or commit therefore reuses the same checkout. Keep an explicit `project_dir`
only when an established deployment path must remain unchanged.

The same preflight validates `runtime.managed_runtime.artifacts` before writing
the host manifest. Artifact names are safe basenames of at most 128 characters;
URLs are HTTPS; checksums are 64 lowercase hex characters; target paths are
non-root, normalized absolute paths; modes match `0?[0-7]{3}`; owners/groups are
safe local account names; and an optional restart target is a safe `.service`
unit. Names and target paths must be unique.

At install time, every artifact target directory must already exist through a
canonical installer-controlled directory chain. Symlinked ancestors and
group/other-writable non-sticky directories are rejected before download.

This role is intentionally limited to a dedicated, empty application host. It
installs cloud-compose files over host Docker, Fluent Bit, Vault Agent, and
systemd locations and restarts Docker during bootstrap. Confirm durable storage
is mounted at the fixed paths and that no unrelated workloads use those host
services before setting the required acknowledgement:

```yaml
cloud_compose_dedicated_host_acknowledged: true
```

The role rejects `cloud_compose_runtime.vault.agent_enabled: true`; generated
Vault Agent configuration is currently Terraform-only. It also rejects
`cloud_compose_runtime.extra_env` entries named `HOME` or `PATH`, or beginning with
`CLOUD_COMPOSE_`, `COMPOSE_`, `DOCKER_`, `SITECTL_`, `LIBOPS_`, `GCP_`,
`VAULT_`, `ROLLOUT_`, or `POWER_MANAGEMENT_`. Those names belong to the host
control plane; use unreserved application-specific names for tuning. The role
writes those settings as JSON data at
`/home/cloud-compose/application-env.json`, and app init reconciles them into
each Compose project without exporting them into host processes.
`cloud_compose_extra_env` remains a compatibility fallback when the nested map
is omitted.

The on-prem adapter rejects
`cloud_compose_runtime.managed_runtime.internal_services_enabled: true` because
the current CAP/lightsout stack and its credentials are GCP-specific. Compose
ingress ports must be whole numbers from 1 through 65535. Lifecycle values
(`compose.init`, `up`, `down`, and `rollout`, plus their per-project
`docker_compose_*` overrides) must be lists of strings. An explicit empty list
is meaningful: it disables that phase and is not replaced by the default.
Runtime feature switches must be YAML booleans, not quoted strings; ambiguous
values are rejected before host mutation.

Set `cloud_compose_runtime.rollout` to enable the same authenticated rollout
listener used by Terraform. Supply a pinned HTTPS `release_url`, its lowercase
`release_sha256`, an HTTPS `jwks_uri`, `jwt_audience`, and optional JSON-object
`custom_claims`. The role installs and starts the service, but deliberately does
not own the host or upstream firewall: restrict the configured port (8081 by
default) to the trusted signal source before enabling it.

The role installs lifecycle dispatchers as `root:cloud-compose` mode `0750` and
the root-consumed `.env`, project/application JSON, and managed-artifact
manifest as `root:cloud-compose` mode `0640`. Reapplying the role restores that
ownership boundary while leaving app checkout directories writable by the
`cloud-compose` account.

The normal on-prem shape is one app per machine. Put each machine in the
`cloud_compose` inventory group and set that host's template/runtime variables.
For multiple apps on one host, pass the same
`cloud_compose_runtime.compose.projects` shape used by Terraform.

Example inventory:

```yaml
all:
  children:
    cloud_compose:
      hosts:
        isle-prod.example.edu:
          ansible_user: debian
          cloud_compose_name: isle-prod
          cloud_compose_template: isle
          cloud_compose_dedicated_host_acknowledged: true
          cloud_compose_runtime:
            compose:
              ingress:
                domain: isle.example.edu
                acme_email: admin@example.edu
            sitectl:
              environment: production
              package_versions:
                sitectl-isle: v1.0.0
        wp-prod.example.edu:
          ansible_user: debian
          cloud_compose_name: wp-prod
          cloud_compose_template: wp
          cloud_compose_dedicated_host_acknowledged: true
          cloud_compose_runtime:
            compose:
              ingress:
                domain: wp.example.edu
                acme_email: admin@example.edu
```

Run:

```bash
ansible-playbook ansible/playbooks/site.yml
```

`cloud_compose_runtime.sitectl.package_versions` pins individual release
packages. The selected template supplies an exact compatible default set; an
explicit entry overrides the matching template selector. Template selectors
are filtered to the effective installed package list, so replacing `packages`
does not retain selectors for removed plugins. An installed package with no
template or explicit selector uses the legacy
`cloud_compose_runtime.sitectl.version` fallback, which defaults to `latest`.
The older `cloud_compose_sitectl_version` and
`cloud_compose_sitectl_package_versions` role variables remain supported as
fallbacks when their nested runtime equivalents are omitted.

Omit `cloud_compose_runtime.sitectl.packages` to use the selected template's
package set. An explicit empty list selects only the core `sitectl` package.
For a multi-project host, an omitted project `sitectl_packages` value inherits
the global set. The host installs the union of global and project package
lists, so a project can add a package but cannot remove one selected globally
or by another project.
