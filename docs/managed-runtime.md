# Managed Runtime

`cloud-compose` installs a small LibOps-managed runtime on each VM. The runtime
keeps host tools and LibOps-side support services current without changing the
customer application repository.

Managed by default:

- `sitectl` from `https://github.com/libops/sitectl/releases/latest`
- additional sitectl plugin packages listed in `sitectl_packages`
- optional verified artifacts listed in `runtime.managed_runtime.artifacts`

The privileged internal LibOps compose project is opt-in. Set
`runtime.managed_runtime.internal_services_enabled = true` only after accepting
the documented Docker-socket, host-filesystem, and observability access used by
CAP and cAdvisor. On GCP, enabling power management also enables this runtime
because lightsout depends on it. Disabled internal services create no dedicated
internal service account or IAM bindings, and the `serviceGsa` output is null.

The updater runs once during boot before the application initializes, then on a
daily systemd timer. Each package follows its own GitHub release stream. The
Terraform template presets select an exact, reviewed core/plugin release set
from `templates/apps.json`. Use `runtime.sitectl.package_versions` to override
core and plugins independently. The provider-neutral
`runtime.sitectl.version` value defaults to `latest` and remains the
backward-compatible fallback only for an installed package with neither a
template selector nor an explicit per-package selector.

All presets pin sitectl v1.9.1 with reviewed application plugins:
sitectl-archivesspace v2.1.1, sitectl-drupal v1.5.0, sitectl-isle v1.6.0,
sitectl-ojs v1.4.0, sitectl-omeka-classic v1.4.0, sitectl-omeka-s v1.4.0,
and sitectl-wp v2.1.0. ISLE includes both the Drupal and ISLE plugins. The
Compose template branches remain independently pinned: ISLE uses v1.3.1,
ArchivesSpace uses v1.0.1, WordPress uses v1.1.1, and Drupal, OJS, Omeka
Classic, and Omeka S use v1.2.1. Override template or package selectors only
as one reviewed, compatible release set.

Omitting `runtime.sitectl.packages` selects the template's package set. An
explicit list replaces that set; `packages = []` or `packages = ["sitectl"]`
selects the core CLI only. A per-project `sitectl_packages` value follows the
same omission rule in the project manifest. The updater installs the union of
the global and all per-project package lists because its binary directory is
host-global; a project list can add packages but cannot remove a package needed
elsewhere on the host.

Application-specific plugins should be passed as package names:

```hcl
runtime = {
  sitectl = {
    packages = [
      "sitectl",
      "sitectl-drupal",
      "sitectl-isle",
    ]
    package_versions = {
      sitectl          = "v1.9.1"
      sitectl-drupal   = "v1.5.0"
      sitectl-isle     = "v1.6.0"
    }
    plugin = "isle"
  }
}
```

An explicit override wins for its named package while the other packages retain
their template selectors. When callers replace a template's package list,
Terraform filters the template selectors to that effective installed set; a
removed plugin cannot leave behind an unknown-package selector. Packages absent
from the template registry use `version` as their fallback. Package names and
tags are validated before any download. When `latest` is selected, the updater
resolves the current release tag first and downloads both the archive and
checksum through that immutable tag URL. Tool, plugin, and managed-artifact
downloads and redirects are restricted to HTTPS with TLS 1.2 or newer.

Package versions are host-global because the binaries are installed into one
shared host path. Do not bin-pack applications that need incompatible versions
of the same sitectl plugin; deploy them to separate hosts instead. Pin a
compatible core/plugin set, and advance core before a plugin that raises its
minimum core requirement.

The updater resolves and verifies the complete requested package set in a
staging generation before replacing any live executable. It takes the shared
application lifecycle lock during the short promotion, records a SHA-256 beside
each installed version, and repairs local binary drift. If a later plugin cannot
download or verify, the old set remains active; if promotion itself fails, the
runtime restores every previous binary and state file instead of leaving a
mixed core/plugin generation.

Additional LibOps-owned binaries or scripts can use the artifact manifest:

```hcl
runtime = {
  managed_runtime = {
    artifacts = [
      {
        name    = "libops-controller"
        url     = "https://example.com/libops-controller-linux-amd64"
        sha256  = "..."
        path    = "/usr/local/bin/libops-controller"
        restart = "libops-controller.service"
      }
    ]
  }
}
```

Artifacts are downloaded, SHA-256 verified, installed atomically, verified
again at the final path, and then optionally restart a systemd unit. Terraform,
Ansible, Salt, and the host updater enforce the same manifest contract: names
are safe basenames of at most 128 characters, URLs use HTTPS, checksums are
lowercase SHA-256, target paths are non-root absolute paths without dot, empty,
or control-character segments, modes match `0?[0-7]{3}`, owners and groups are
safe local account names, and an optional restart target is a safe `.service`
unit. Names and target paths must be unique. A failed restart restores the
previous artifact and records the failed update instead of leaving an
unverified replacement active. The updater validates and de-duplicates the
entire manifest before the first download, so a bad later row cannot partially
apply earlier rows. Valid rows are independent transactions: a later download
or restart failure does not roll back an earlier artifact that was already
installed and restarted successfully. Package tightly coupled files as one
verified artifact, or use a separately versioned installer that owns their
cross-file transaction. The installed fast path rechecks checksum, mode, owner,
and group; permission drift is reconciled instead of being hidden by stale
state.

Artifact target directories must already exist through a canonical directory
chain controlled by the root-run installer. Symlinked ancestors and
group/other-writable non-sticky directories are rejected before download. Put
mutable application data in Compose volumes instead of using the privileged
artifact installer to write into an application-owned checkout.

Internal-service auto-update pulls images only when both internal services and
auto-update are enabled. It restarts the systemd unit only when that unit is
already active; an intentionally stopped internal stack remains stopped.
