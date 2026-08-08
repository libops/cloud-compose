# Runtime Contracts

`cloud-compose` treats Git as the desired application state and `sitectl` as the
runtime reconciler. Terraform provisions durable infrastructure and writes the
VM contract; boot and rollout then use `sitectl` to move each compose project to
the desired state.

## Trust Boundary

Terraform module sources, rootfs overlays and archives, Compose repositories,
lifecycle command lists, managed artifacts, Vault Agent templates, and
configuration-management pillars/inventory are privileged deployment inputs.
An operator who can change them can execute as root on the dedicated host. Pin
and review these inputs with the same controls used for infrastructure code;
checksums provide integrity but do not make an untrusted artifact safe.

Terraform state, cloud-init/user-data, plans, and CI logs can expose rendered
configuration. Do not place application secrets in `runtime.extra_env`, Vault
template contents, lifecycle commands, or ordinary Terraform variables. Pass
secret references through the deployment contract and let the runtime secret
manager materialize values on the host. Restrict access to state and CI
artifacts even when the intended inputs are non-secret.

GCP deployment names are 6–21 lowercase letters, numbers, or hyphens, starting
with a letter and ending with a letter or number. That bound ensures the same
name remains valid after the `vm-`, `internal-`, and `ppb-` prefixes used for
generated service accounts. DigitalOcean and Linode retain their documented
provider-specific name limits.

## GCP foundation and application states

GCP prerequisites that are shared by many sites belong in one small,
long-lived Terraform state. Apply `modules/gcp-foundation` once per Cloud Run
service project before applying any application state. By default, the
foundation owns:

- the Cloud Resource Manager, Compute Engine, IAM, IAM Service Account
  Credentials, Logging, Monitoring, and Cloud Run APIs;
- explicit creation of the Google-managed Cloud Run service identity and its
  documented `roles/run.serviceAgent` service-project binding;
- the reusable `cloudComposeStart` and `cloudComposeSuspend` custom-role
  definitions; and
- for Shared VPC, the service-project attachment when requested plus the Cloud
  Run service agent's host-project Network Viewer and per-subnet Network User
  grants.

The foundation queries the service project itself. Application callers do not
need to pass a numeric project number. The identity running the foundation must
be able to enable services, manage project custom roles, and, for Shared VPC,
manage the host-project attachment and IAM grants. The Service Usage API must
already be enabled so Terraform can enable the workload APIs.

Each application state owns its VM, disks, application service accounts,
firewall rules, optional Cloud Run proxy, and IAM membership for that one VM.
If callers supply existing VM or app service accounts, each account must still
be dedicated to exactly one cloud-compose application state. The state owns
project telemetry memberships and optional target-service-account IAM members;
reusing an identity across states would let either state's destroy revoke
access required by the other. Leave the email inputs empty to get the safer
per-state identities by default.
When power management is enabled, pass the foundation's full
`cloud_compose_start_role_name` and `cloud_compose_suspend_role_name` outputs as
`gcp.power_management.start_role` and `gcp.power_management.suspend_role`.
Cloud-compose binds the proxy identity to the start/resume role and the
internal-services identity to the suspend role on the selected Compute Engine
instance only. The custom-role definitions live at project or organization
scope because Google custom roles do, but application principals do not receive
those permissions across the project. It also does not let the project's
default Compute Engine workload service account impersonate the VM service
account; Google attaches that identity through the Compute Engine service agent.
The principal applying the application state must already have
`iam.serviceAccounts.actAs` (normally `roles/iam.serviceAccountUser`) on the VM
service account; cloud-compose does not grant its deployer permissions to
itself.

Keep these states independent. Publish the two role names through a reviewed
remote-state or deployment-variable boundary, apply the foundation first, and
do not make a site destroy own foundation resources. The foundation protects
custom roles from ordinary destroy and abandons API and optional Shared VPC
attachment ownership rather than disabling or detaching infrastructure used by
surviving sites. Decommission it only after every Cloud Run revision is
disconnected, all application states are retired, and remaining consumers have
been inventoried.

For a same-project VPC, leave the foundation's `host_project_id` empty. The
foundation creates no extra Network Viewer or Network User membership; the
foundation owns the Cloud Run service agent's standard
`roles/run.serviceAgent` membership in the service project, which remains the
authority for Direct VPC use.

For Shared VPC, set the foundation's `host_project_id`, enumerate every regional
subnet Cloud Run may use in `shared_vpc_subnetworks`, and set
`attach_shared_vpc = true` only when this foundation state should own the
service-project association. The foundation grants the derived Cloud Run
service agent `roles/compute.networkViewer` on the host project and
`roles/compute.networkUser` on each listed subnet. It deliberately does not
grant Network User across the host project. The application deployment identity
still needs its separately reviewed host-project permissions to read the
network, use the subnet, and manage that application's firewall rules. External
IPv6 subnets additionally require the Google-documented Compute Public IP Admin
grant, which is outside the foundation module's default IPv4/internal-IPv6
contract.

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

`docker_compose_branch` (the `runtime.compose.branch` input at the public
module boundary) accepts either a branch/tag name or a full 40-character Git
commit. When the public input is omitted or empty, the selected template
preset supplies its reviewed branch; the no-preset registry default remains
`main`. The source-preparation and `init` phases follow a configured moving ref.
An ordinary `up` or service restart instead validates and preserves the commit
selected by the last successful init or rollout. This keeps a detached feature
or pull-request deployment operable until an explicit rollout selects another
ref. A later source-preparation or `init` phase can restore the configured
baseline only when the current clean `HEAD` exactly matches the recorded
successful deployment; unrecorded local-ahead or divergent work is rejected.
A full configured commit is treated as an immutable source pin:
cloud-compose fetches that object, checks it out with a detached HEAD, verifies
that `HEAD` exactly matches the configured value, and does not advance when the
remote branch moves. The deployed commit for every app is recorded at
`/home/cloud-compose/state/<app>.deployed-head`, including branch/tag
deployments, so operators can compare desired and observed source state.

Use a full commit for reproducible production rollouts. A commit pin fixes the
repository contents but does not prove who authored them; protect the selected
repository and review/sign commits according to your downstream governance.

First boot runs through `cloud-compose-bootstrap.service`. Both that bootstrap
and `cloud-compose.service` retry failures after 30 seconds, so a transient
registry, Vault, or Compose failure converges without an operator restarting
cloud-init. Application initialization is serialized by the normal lifecycle
lock and recorded for the current boot before the app starts; a bootstrap retry
reuses that successful initialization instead of repeating it. Durable
readiness is published only after the Compose `up` unit reaches its successful
oneshot state. The cloud-init caller waits for that result, so configured
post-initialization commands retain their ordering. Inspect the bounded system
journal with `sudo journalctl -u cloud-compose-bootstrap` and the unit states
with `systemctl status cloud-compose-bootstrap cloud-compose`. Bootstrap output
uses a fixed `info` priority and has no unit-specific Fluent Bit input, so raw
bootstrap output is not forwarded to Cloud Logging; systemd's own service
failures remain available to the existing warning-level collector.
Root systemd jobs enter through `/usr/local/libexec/cloud-compose`, validate
the root-owned home scripts and control inputs, and only then execute their
allowlisted `/home/cloud-compose` program. Application services retain their
unprivileged execution model.

## Sitectl

During init, the VM creates a `sitectl` context for every app. The default `up`
commands use `sitectl compose up`, followed by a healthcheck. The default
rollout command uses `sitectl deploy`, whose compose reconcile path repairs
plugin-declared init artifacts, volumes, and buildable images before starting
services. A plain service start does not promise that repair; run a rollout or
an explicit `sitectl deploy` when reconciliation is required.

The host installs one shared `sitectl` core and plugin package set. Pin releases
with `runtime.sitectl.package_versions`; its keys are package names such as
`sitectl` and `sitectl-isle`. A package-specific value overrides the legacy
`runtime.sitectl.version` fallback. Named Terraform templates start from the
exact compatible package set recorded in `templates/apps.json`; explicit
per-package values win, and template values are filtered to the installed
package list before validation. Terraform, Ansible, and Salt serialize their
resolved map as `SITECTL_PACKAGE_VERSIONS` JSON and the privileged installer
validates it again before downloading anything. Per-project package versions
are not supported because projects on one host share the same binaries.
`/home/cloud-compose/bin` is reserved for generated `sitectl` symlinks. During
an upgrade from the former application-owned directory, the installer closes
the directory to root and rejects any other inherited command or target rather
than carrying an untrusted PATH entry forward.

`sitectl_verify_args` remains a real argument list. The host stores it as JSON
and appends each value through an argv-aware wrapper when a lifecycle command
invokes `sitectl verify`; spaces in one value never become additional arguments.
Newlines, carriage returns, and NUL bytes are rejected instead of being flattened
into an ambiguous shell scalar.

## Vault

`cloud-compose` defines the Vault contract and leaves product-specific Vault
roles, policies, mounts, and secret paths to consumers.

Each provider-specific entrypoint defaults `runtime.vault.auth_method` to
`auto`. The GCP entrypoint and GCP-only compatibility root resolve it to GCP
IAM; DigitalOcean and Linode resolve it to consumer-managed auth. GCP IAM uses
the app GSA identity, not the VM GSA. Vault Agent uses the VM's attached identity
through Application Default Credentials to call the IAM Credentials `signJwt`
API for that app identity. Terraform grants the VM GSA Token Creator on that
one app GSA only while managed GCP IAM auto-auth is enabled; it does not create
or download a JSON key for Vault. The foundation therefore enables
`iamcredentials.googleapis.com`.

Terraform providers render the Vault Agent configuration. The Ansible role and
Salt formula deliberately reject
`vault.agent_enabled = true` until they can render and own the same files; leave
it disabled and manage a separate Vault Agent through the host configuration
system if an existing host needs one.

When the managed agent is enabled, its token must be one regular file directly
inside `/mnt/disks/data/vault`; symbolic-link and broad-parent paths fail
closed. Bootstrap prepares Compose sources without running application
lifecycle commands, authenticates the Vault Agent without a file credential,
waits for a freshly written Vault token readiness marker, and only then runs
app/plugin initialization and starts the app service. A missing config, Vault
binary, fresh token, or active agent service stops bootstrap rather than
silently starting an app without an authenticated agent. Token readiness does
not prove that every optional template destination has rendered; an app whose
initialization consumes a rendered file must include its own bounded file/content
check in the configured init lifecycle.

DigitalOcean and Linode do not currently provide a matching GCP-style workload
identity contract. Their Terraform entrypoints use `consumer-managed` auth and
require `vault.agent_additional_config` when the Terraform-managed agent is
enabled.

## OS Families

Dependency installation dispatches by OS family:

- COS: installs Docker Compose, Buildx, and `make` into writable paths and
  fails bootstrap if the host-provided OpenSSL prerequisite is unavailable.
  The verified Make artifact lives in a dedicated directory on the executable
  persistent disk under `/mnt/disks/data`, not the stateful `/home` or `/var`
  filesystems that COS mounts `noexec`. On
  GCP, the metadata policy permits only DNS to the Compute Engine resolver and
  denies all other container traffic to the metadata address before the pinned
  Alpine build runs. The build uses Docker's bridge and never `--network host`.
- Fedora CoreOS: installs `git`, `jq`, `make`, and OpenSSL with
  `rpm-ostree install --apply-live`, then installs Docker CLI plugins.
- Debian/Ubuntu: installs Docker, Git, jq, make, OpenSSL, and CA/curl packages
  with apt, then installs Docker CLI plugins.

Provider modules should mount persistent data and Docker-volume disks before the
runtime starts. Destroying/recreating the VM must not destroy these volumes.
On GCP, `gcp.disks.data_size_gb` independently sizes the application-data disk;
`gcp.disks.docker_volumes_size_gb` sizes the Docker-volume disk. Callers that
store logical backups or other bounded data under `/mnt/disks/data` must size
the application-data disk for both runtime overhead and the complete retention
and staging budget. Increasing the Terraform input grows the GCP block device
in place; it does not by itself resize an already mounted filesystem. Schedule
a controlled reboot after the apply so cloud-init reruns filesystem preparation
and `resize2fs`, then verify the mounted ext4 capacity. Never reduce the input
after the disk exists.

The reviewed `n2d-standard-2` profile is available for workloads that need a
non-E2 capacity pool. N2D deployments must select `pd-standard` or `pd-ssd`;
the module rejects `hyperdisk-balanced` because N2D supports Persistent Disk
and Hyperdisk Throughput, not Hyperdisk Balanced. See Google's
[N2D disk compatibility](https://cloud.google.com/compute/docs/general-purpose-machines#n2d_series).

Every Compose `project_dir` must be a normalized descendant of the fixed
`/mnt/disks/data` ownership boundary. Terraform rejects paths such as `/`,
`/etc`, repeated separators, and dot-segment traversal during planning. The
Ansible and Salt adapters apply the same validation before any filesystem
mutation, and the host runtime resolves existing symlinks again before cloning
or changing ownership. This boundary is intentionally not configurable on a
production host. When `project_dir` is omitted, every adapter derives the
stable path `/mnt/disks/data/<repository path>/<application key>`. The Git
branch, tag, or commit is deliberately not part of that path, so a ref update
or reconstructed VM reconciles the persistent checkout in place. Set
`project_dir` explicitly only when preserving an established deployment path
or separating checkouts beyond the repository/application identity is
required.

Before dropping privileges during bootstrap, Cloud Compose also converges only
the exact manifest project directory and its existing `.env`: the directory is
`cloud-compose:cloud-compose` mode `0775`, and `.env` is mode `0640` with the
same owner. This repairs metadata retained from an older VM without recursively
changing checkout contents. A symbolic-link project path or a symbolic-link,
non-regular, or multiply linked `.env` fails closed. The file contents and
inode are preserved. The root bootstrap temporarily makes the verified project
directory read-only and root-owned while it performs the no-follow `.env`
validation, so an unprivileged process cannot substitute a link between the
check and metadata update. In particular, this heals a checkout initialized by
releases through 0.8.1, whose root-run application init could leave a mode
`0600` `.env` owned by root before later releases moved app lifecycle work to
the unprivileged account.

Releases through 1.6 derived an omitted `project_dir` from the Git ref. Before
upgrading an existing deployment that relied on that default, set
`project_dir` explicitly to its current ref-scoped checkout if it must remain
at the same path. Cloud Compose does not guess whether an old checkout can be
moved safely. New deployments and callers that intentionally accept one fresh
checkout should omit the override and use the stable default.

GCP snapshot overlays accept Docker volume basenames only. The overlay helper
verifies that an existing mount uses the configured lower, upper, and work
directories before treating it as idempotent. Its destructive reset accepts
only an explicit `true`, unmounts the verified overlay, clears both upper and
work state (including dotfiles), and remounts it. Values such as `maybe` are
errors; the literal value `false` never resets data.

Fedora CoreOS bootstrap installs only the OS dependencies `git`, `jq`, and
`make` through `rpm-ostree`; it does not configure the LibOps RPM repository.
After OS setup, the same managed-runtime path used by Debian and COS downloads
each requested sitectl release archive and its release checksum manifest,
verifies the selected archive, and installs it under the persistent managed
runtime directory. Keeping a single sitectl ownership path avoids an RPM copy
being immediately replaced by a separately downloaded release binary.

The Ansible role and Salt formula skip cloud infrastructure creation. They
assume Debian/Ubuntu hosts already have suitable network, DNS, firewall, and
storage policy, then install the same rootfs and write the same runtime files
Terraform would have written through cloud-init.

### Bootstrap artifact trust

Hosts that install Docker Compose and Buildx outside an OS package repository
download the binary and `checksums.txt` from the same exact upstream release
tag. The installer requires one checksum entry for the selected architecture,
verifies the temporary binary, and then renames it into place atomically. Every
run also hashes an existing plugin against that release manifest, so changing a
configured version upgrades the binary and a modified local binary is repaired.
A failed or mismatched download leaves the last verified executable in place.

On Container-Optimized OS, the Alpine environment used to compile GNU Make is
pinned by image-index digest. The Make source archive has its own fixed SHA-256
digest and is verified before extraction. Renovate updates both the Docker
release versions and the Alpine tag/digest pair; review those changes as
supply-chain updates rather than accepting an unpinned replacement. The image
and its network-fetched package build scripts execute only after the metadata
firewall is installed and use the bridge network, so they cannot inherit the
host network's root exemption.

The GCP COS VM image name is a reviewed manual pin. Renovate has no built-in
GCP Compute image-family datasource, and the shared LibOps preset does not add
one, so the repository intentionally carries no non-functional Renovate marker
for this value. Review the COS release notes and update all three GCP defaults
together when promoting the host OS.

The GCP power-button Terraform dependency is sourced from a full Git commit,
not a mutable branch or tag archive. Advance that commit deliberately with a
reviewed plan; provider lockfiles do not checksum remote Terraform modules.

## Host and application environment boundaries

Terraform, Ansible, and Salt render two deliberately separate data files:

- `/home/cloud-compose/.env` contains trusted cloud-compose host controls only.
- `/home/cloud-compose/application-env.json` contains `runtime.extra_env`
  application tuning as a JSON object and is never sourced or exported by the
  host runtime.

The host file uses a narrow dotenv encoding. Runtime commands source
`/home/cloud-compose/profile.sh`, whose strict parser decodes that format
without `eval` or sourcing `.env`. Systemd units invoke the same loader instead
of `EnvironmentFile`. Terraform centralizes host encoding in
`modules/runtime-env`; the Ansible and Salt renderers implement the same
contract.

During init, cloud-compose parses the application JSON with `jq` and reconciles
every entry into every configured Compose project's own `.env`. It writes
double-quoted Compose values with backslash, double quote, dollar, newline,
carriage return, and tab encoded as `\\`, `\"`, `$$`, `\n`, `\r`, and `\t`.
Pass raw strings through `extra_env`; do not pre-escape quotes, dollars, or
multiline values. Marked application entries are idempotent, and entries removed
from desired state are removed on the next init. Existing downstream dotenv
syntax remains opaque and is preserved.

Application values are written before cloud-compose's final managed
`COMPOSE_PROJECT_NAME`, `SITE_NAME`, and `COMPOSE_BIND_PORT` overrides. Reserved
control-plane names and prefixes are rejected. Security-sensitive but
application-valid names such as `BASH_ENV`, `LD_PRELOAD`, `PORT`, or `JWKS_URI`
remain Compose data and never enter privileged host shells. The rollout service
stores listener and authentication controls as `ROLLOUT_PORT`,
`ROLLOUT_JWKS_URI`, `ROLLOUT_JWT_AUD`, and `ROLLOUT_CUSTOM_CLAIMS`, then maps
them to the rollout binary's generic names immediately before `exec`.
Application settings therefore cannot replace rollout authentication.

The JSON and project `.env` files are mode `0640`, but `extra_env` is not a
secret store: its values also exist in Terraform state or configuration-
management input. Use the template's secret-file or Vault contract for
credentials.

`make runtime-config-contract` tests the strict host encoding with Docker
Compose. `make application-env-contract` tests the host/application boundary,
multi-app reconciliation, literal special characters, and rollout namespacing
without starting containers. `make config-management-smoke` renders and
validates the Ansible and Salt forms.

SSH user names are restricted to safe Linux account names, and public-key
entries must be non-empty single lines. Rejecting multiline values before
cloud-init rendering prevents user or key data from changing the generated
YAML structure.

## Host metadata and GCP key rotation

On GCP, metadata isolation has a pre-Docker and post-Docker layer. The
`cloud-compose-metadata-firewall-pre.service` unit is required before
`docker.service` on hosts with a persistent systemd unit directory. It installs
an idempotent `mangle/PREROUTING` guard plus the unprivileged-host HTTP and HTTPS
denies before managed containers can start. After Docker starts,
`cloud-compose-metadata-firewall.service` installs equivalent defense-in-depth
rules in Docker's `DOCKER-USER` hook and the host `FORWARD` chain. The rules
match the metadata destination rather than a bridge name, so existing and
future Compose networks are covered.

[Compute Engine DNS](https://cloud.google.com/compute/docs/internal-dns) also
serves VPC, private, forwarding, and peering answers from `169.254.169.254`, so
container TCP and UDP port 53 are explicitly accepted ahead of each catch-all
drop. Metadata HTTP and HTTPS remain unavailable to containers, and both
endpoints are blocked for unprivileged host processes; root retains access for
the GCP-only key-rotation service. Bootstrap installs the policy before the COS
dependency builder, restarts Docker, and immediately verifies the policy again
before application containers proceed. Other providers neither enable these
units nor receive GCP-specific firewall rules.

COS reconstructs `/etc` after networking on each boot, so a unit shipped there
cannot claim pre-network enforcement. This follows the documented
[COS filesystem and cloud-init model](https://cloud.google.com/container-optimized-os/docs/concepts/disks-and-filesystem).
The COS base image, Google guest agents, cloud-init, and verified cloud-compose
rootfs download are therefore privileged bootstrap dependencies. The initial
Docker data root does not contain the managed persistent Compose workload;
bootstrap installs the full policy before the first third-party build container
and before restarting Docker with its managed data root. The post-restart
service then gates application startup. On stateful `/etc` hosts, the
pre-Docker unit also closes the ordinary reboot and daemon-restart window. This
boundary is deliberate: deployments requiring metadata isolation before
cloud-init must bake the guard into their boot image.

Before any lifecycle command runs on GCP, cloud-compose renders the effective
Compose model and rejects service `network_mode: host`, build `network: host`,
and BuildKit `network.host` or `security.insecure` entitlements. Those modes put
container/build code in a path that bypasses the forwarding deny rules. This is
defense in depth, not a sandbox for an untrusted Compose repository: lifecycle
commands, privileged containers, host mounts, and Docker socket access are
root-equivalent inputs under the trust contract above.

GCP power-management ingress uses [Cloud Run Direct VPC
egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc), without
a Serverless VPC Access connector. Cloud Run services do not support Direct VPC
ingress: the public request terminates at the proxy service, and that service
sends its backend connection through Direct VPC egress to the VM's private
address. The VM and Cloud Run revision must therefore resolve to the same VPC
network and regional subnet.

Callers may provide a network, a subnet, or both. A network-only input selects
the same-named subnet in `gcp.region`; a subnet-only input derives its parent
network. Leave both empty to create a per-application managed network, or set
`gcp.network.create = false` to resolve the regional `default` subnet. For an
existing network, simple names are resolved in `gcp.network.project_id`. Shared
VPC callers should prefer the unambiguous full resource forms:

```text
projects/HOST_PROJECT/global/networks/NETWORK
projects/HOST_PROJECT/regions/REGION/subnetworks/SUBNET
```

Cloud-compose rejects a configured network project that disagrees with either
resource, a subnet from a different project or parent network, and a subnet
whose region differs from `gcp.region`. Apply the singleton foundation's Shared
VPC service-agent grants first; the application stack does not own those
long-lived IAM members.

[Direct VPC address allocation](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc#ip-address-allocation)
is ephemeral. When power management is enabled, cloud-compose therefore
requires an IPv4 `/26` or larger subnet in RFC1918, RFC6598
(`100.64.0.0/10`), or Class E (`240.0.0.0/4`) space. It permits the subnet
CIDR—not individual revision IPs or a Cloud Run identity—to reach only the
selected application port on the VM.

The Google network data source used here does not expose MTU. An
existing/Shared VPC caller must review the actual network and set
`gcp.network.mtu` as an explicit attestation; cloud-compose rejects power
management unless that value is Cloud Run's default `1460`. Managed networks
set `1460` directly. Changing the input without changing the real network does
not fix an MTU mismatch.

The firewall source is a network trust zone: every workload allocated an
address from the subnet can reach the selected VM port. Prefer a dedicated
subnet, especially in Shared VPC, or share it only with workloads in the same
trust boundary. Keep free capacity for Cloud Run's `/28` allocation blocks,
steady-state use of twice as many addresses as service instances, overlapping
revisions, and the post-scale-down retention window. A nominal `/26` that is
already occupied is not sufficient.

The proxy uses a 240-second power-on budget and a separate bounded 300-second
connection retry window, while Cloud Run allows the request 600 seconds. This
leaves a 60-second response margin while accommodating Direct VPC connection
establishment and application startup after Compute reports `RUNNING`. TCP
connection establishment is retried before request bytes are sent; PPB adds no
application-level request or response-status retry. Go's standard transport can
retry requests it defines as replayable when a pooled connection is found
stale. Connection resets after establishment remain retryable events for
clients.

Cloud Run caps PPB at one active instance so concurrent requests share its
in-process power-transition coordinator. During a revision overlap, the old and
new instances can still race; PPB treats a failed start/resume as joinable when
the VM is then observed transitioning or running.

Power management also requires an explicit `gcp.network.power_button_allowed_ips`
list. Cloud-compose does not prepend private or Direct VPC ranges: those are
backend network identities, not original web clients. PPB selects the client
from the right edge of `X-Forwarded-For`, fails closed when the header is
missing or too shallow, and uses `power_button_ip_depth` for any trusted proxy
hops appended after the client. Power management requires this value
explicitly: use `0` for the direct public Cloud Run URL, where the hosted
contract proves Cloud Run appends the original client at the right edge. An
external Application Load Balancer adds a different trusted suffix; set a
larger depth only after that exact topology is verified. [Google's load
balancer appends the client and forwarding-rule
addresses](https://cloud.google.com/load-balancing/docs/https#x-forwarded-for_header)
and does not validate caller-supplied values that precede them, so a
direct-path depth must never be silently reused behind another proxy. The
hosted direct-Cloud-Run smoke sends an attacker-controlled prefix and must
prove depth zero still selects the real runner before this filter is treated
as operational. This is a wake-up filter, not a replacement for application
authentication or Cloud Armor.

Cloud Run recommends a startup probe that verifies an egress destination for
ordinary Direct VPC workloads. The power-button proxy is an intentional
exception: its `/healthcheck` startup probe verifies only that the PPB process
is ready. It cannot gate startup on the application VM because that VM is
allowed to be stopped, and the proxy must accept the first request in order to
start it. PPB's bounded backend dial loop is therefore the connectivity retry
boundary. A healthy startup probe does not prove that the Direct VPC path or
the stopped VM is reachable.

When destroying or moving the Cloud Run revision, Google can retain its subnet
addresses for one to two hours. A same-apply destroy of a module-managed subnet
can therefore fail after the service is gone; wait for address release and
apply destroy again rather than manually deleting serverless reservations.
For a shared or persistent subnet, destroy only the application resources and
leave the network foundation in place. Disconnect all Cloud Run revisions and
wait for address release before a separately reviewed subnet or Shared VPC
decommission.

User-managed app JSON keys are disabled by default. Set
`gcp.identity.app_credentials_enabled = true` only when an application
explicitly requires a file credential. That opt-in grants the VM GSA Key Admin
on the app GSA, rotates the key into
`/mnt/disks/data/cloud-compose/app/GOOGLE_APPLICATION_CREDENTIALS`, and
distributes it to each app's `secrets/GOOGLE_APPLICATION_CREDENTIALS`. Managed
Vault GCP IAM auth does not imply this option.

GCP service-account key rotation has its own
`cloud-compose-key-rotation.timer`. Bootstrap runs its fail-closed check once,
but enables the recurring timer only when app file credentials or privileged
internal-service credentials are enabled. Rotation requires an explicit
`CLOUD_COMPOSE_PROVIDER=gcp`, a reachable metadata token endpoint, successful
IAM responses, and an organization policy that permits user-managed service
account key creation. Organizations commonly enforce
`constraints/iam.disableServiceAccountKeyCreation`; prefer the keyless defaults
instead of weakening that policy. Power management and explicitly enabled
internal services still use an internal-service JSON key and therefore require
a reviewed exception until that runtime is migrated to attached identity.
DigitalOcean, Linode, and on-premises hosts do not enable or invoke this path.

Rotation preserves the prior credential, proves the replacement key through a
bounded OAuth JWT exchange, distributes it, and reloads only consumers that
were already active. It then disables—rather than immediately deletes—the old
key. `ROTATION_DISABLE_GRACE_SECONDS` controls the rollback window (24 hours by
default); a later timer pass deletes the disabled key, treating an IAM 404 as
the already-complete state. During grace, an operator can safely restore the
previous app credential with:

```bash
sudo /home/cloud-compose/rotate-keys-app.sh rollback
```

If the central credential for a module-created app identity is missing but
distributed app copies remain, bootstrap first restores it only when every
existing copy is a valid credential for the exact project and service account
and all copies are byte-identical. The restored file retains the source
modification time so recovery cannot reset the rotation interval. An invalid
or conflicting copy fails before any IAM mutation. Distributed copies for a
caller-supplied identity are not sufficient revocation authority and require
operator-reviewed recovery.

Formatting a new GCP data disk publishes a root-owned, single-use
fresh-filesystem marker whose exact payload is
`v1:gcp-disk-id:<google_compute_disk.data.disk_id>`. Terraform renders the same
server-assigned disk incarnation into cloud-init and the root runtime
environment. A marker restored from a snapshot onto a new disk therefore
cannot authorize deletion of that new host's current IAM keys. GCP never
accepts the generic marker used by non-GCP hosts.

A supported GCP data-disk snapshot restore must run through Terraform and VM
replacement so the replacement boot configuration receives the new disk's
`disk_id`. Out-of-band attachment or hot-swapping a restored data disk while
retaining an older boot configuration is unsupported and does not satisfy the
fresh-authority invariant; converge the VM through Terraform before bootstrap.

A reserved pending ext4 label carries fresh-format intent across a crash
between formatting, mounting, and marker publication. The label can recreate a
missing marker only while the mounted ext4 root is exactly root-owned, mode
`0755`, and empty except for an empty, root-owned `lost+found`; a populated disk
fails closed. An existing marker must have the exact expected disk payload,
root ownership, private modes, and single link before the label can be cleared.
Global durability barriers order marker publication and label clearing.

While the marker exists, a module-created app identity or the
always-module-created internal identity may reconcile leaked keys from an
interrupted first bootstrap, but only while its exact consumer unit is loaded
and inactive. Reconciliation durably flushes the complete validated
user-managed-key baseline before deletion, retries deletion idempotently, and
creates one replacement only after the empty-baseline state is also durable. A
key that appears after the snapshot is never adopted into the deletion set and
blocks progress for review. Host convergence keeps the data mount root owned by
`root:cloud-compose` with mode `1775`, leaving the marker directory
root-private while application paths remain group-creatable. Bootstrap
consumes and flushes the marker immediately after the one-shot daily rotation
converges every enabled identity. Consumption precedes the persistent rotation
timer, Vault, application initialization, and application startup, closing the
window in which a scheduled snapshot could retain destructive authority.

Caller-supplied app identities never receive that destructive recovery path.
An already-formatted disk has no fresh-filesystem attestation either: audit and
revoke its exact orphan keys through an operator-reviewed procedure instead of
creating the marker retroactively. Outside fresh reconciliation, reaching
IAM's ten-user-key limit fails before a create request or pending state is
written.

To disable an existing app file credential, first leave
`app_credentials_enabled = true`, apply the 1.0 runtime, and retire the remote
key plus every distributed local copy:

```bash
sudo /home/cloud-compose/rotate-keys-app.sh retire
```

Then set the input to false and apply again. The disabled runtime fails closed
if it finds a stale credential artifact; removing Key Admin without retiring
the already-issued key does not revoke that key.

If the central JSON file was deleted before retirement, the runtime cannot
safely infer which remote private key it owned. It lists the remaining
user-managed key IDs and fails closed without deleting any of them. Audit and
explicitly revoke those IDs before disabling Key Admin. A missing local file is
reported as complete only when the service account has no user-managed key.

A definite IAM rejection that proves no key was created clears the pre-create
state. A timeout, transport failure, or otherwise ambiguous key-creation
response never triggers an automatic second create. `rotate-keys.sh audit ...`
reports only the baseline delta/key IDs. Recovery requires the single audited
orphan key ID as explicit confirmation to `rotate-keys.sh recover ... KEY_ID`;
if no key was created, recovery clears the pending state without deleting
anything. Recovery also waits `ROTATION_RECOVERY_SETTLE_SECONDS` (60 seconds by
default) before trusting an empty IAM delta, avoiding a false “no key created”
result during propagation.

All Terraform entrypoints, including GCP, DigitalOcean, and Linode, support the
same verified rootfs archive contract. When `runtime.rootfs_archive_url` is
used, it must be an HTTPS URL without whitespace and
`runtime.rootfs_archive_sha256` is mandatory with a 64-character SHA-256
digest. Boot restricts curl and redirects to HTTPS with TLS 1.2 or newer,
downloads to a temporary path, and verifies the complete file before extracting
its `rootfs` directory. The GCP path stages
the caller's packaged rootfs overlay and reapplies it after the archive, so
consumer overrides still win. Use an immutable archive URL; a moving branch and
a pinned checksum intentionally fail as soon as the branch content changes.

## Backups

`cloud-compose-mariadb-backup.timer` runs the local-backup and off-host handoff
flow nightly between 9pm and 7am EST. It uses a fixed randomized delay so
deployments spread out across that window while keeping a stable schedule on
each VM. The unprivileged local phase executes:

```bash
sitectl mariadb backup --context "$SITECTL_CONTEXT_NAME" --gzip --output "$path"
```

for every app context. Backups are written under
`/mnt/disks/data/backups/mariadb/<app>/` by default.

The backup and Compose lifecycle paths share one host lock, so a rollout,
service restart, key-rotation reload, and database dump cannot overlap. The
timer skips an intentionally inactive `cloud-compose.service`; it does not pull
that unit in as a dependency. Each dump is written under a private staging
directory, checked for non-zero size and valid gzip structure, and renamed into
the daily final path only after validation. An invalid pre-existing daily file
fails closed for operator review instead of being treated as a completed backup.
One app failure is recorded without skipping the remaining bin-packed apps; the
service exits non-zero after attempting all of them. Dumps older than
`MARIADB_BACKUP_RETENTION_DAYS` (14 by default) are pruned from each validated
app directory so they cannot fill the shared data disk indefinitely.

Local dumps remain on the same failure-domain disk as application data and are
never disaster recovery. Set `runtime.disaster_recovery.required = true` only
after installing the operator-owned root driver. The root handoff runs after
the local service, including when the daily dump already exists, and requires a
strict atomic receipt proving encrypted off-host coverage of each app's logical
database, checkout/bind files, named volumes, and resolved service-mount
topology. A weekly timer requires a challenge-bound proof that the driver
restored all three coverage classes into a disposable recovery environment,
verified integrity, and destroyed that environment. Storage-vendor settings
and credentials stay behind the driver and never enter Terraform, cloud-init,
the host environment, or logs. The complete interface and receipt schemas are
in [Disaster recovery](disaster-recovery.md).

GCP production enables crash-consistent scheduled disk snapshots by default;
`guest_flush = false` is deliberate because the logical dump supplies the
application-consistent database artifact. DigitalOcean and Linode boot-disk
backup toggles do not include attached volumes. None of those provider-local
copies replace the independent driver receipt and restore proof.

Terraform owns the attached data and Docker-volume disks. A normal
`terraform destroy` deletes them; GCP production snapshots are retained, but
non-production or explicitly snapshot-disabled stacks may have no recovery
copy. Review every disk delete in the saved plan and create an independent
snapshot/export before intentional teardown. The module does not use an
unconditional `prevent_destroy` because that would also block explicit,
operator-approved retirement.

## Power Management

On GCP, application ports are not public VM ingress. With power management
enabled, the VM firewall admits every distinct manifest app port only from the
Cloud Run Direct VPC subnet; each app is reached through its Cloud Run/LB
frontend. With power management disabled, cloud-compose opens no application
port. Therefore HTTP-01/Let's Encrypt presets require a separately managed
frontend/firewall path on GCP and must not be assumed to work against the VM's
public IP. DigitalOcean and Linode provider firewalls directly admit each
distinct app port from their configured web source ranges.

`gcp.power_management.enabled` is disabled by default and gates GCP-specific
cost-saving behavior:

- Cloud Run proxy-power-button ingress
- the `lightsout` internal-service profile

Enabling power management is an explicit opt-in to the privileged internal
services required by lightsout. Enabling internal services without power
management runs CAP/cAdvisor without the lightsout profile. When both are
disabled, Terraform does not create the internal-services Google service
account, KeyAdmin grant, monitoring writer grant, or suspend-role binding.
Any optional power-management frontend used for a production VM must use an
OCI image reference ending in an immutable `@sha256` digest.

Apply `modules/gcp-foundation` first and pass its full start and suspend role
names into `gcp.power_management`. The application stack grants each service
account that role on its own VM instance only; it never grants either principal
power permissions across the project. Organization custom roles with the same
reviewed permission sets are also accepted when an organization foundation owns
them.

DigitalOcean and Linode deployments should leave power management disabled
because stopped VMs do not provide the same cost profile.

### Upgrading to 1.0.0

Release `1.0.0` changes power management, privileged internal services, and
their automatic updates from implicit opt-out behavior to explicit opt-in.
Before upgrading, decide which behavior the deployment should retain:

- To preserve the earlier GCP power-management stack, set
  `gcp.power_management.enabled = true`,
  set `gcp.power_management.start_role` and `suspend_role` from an already
  applied foundation state,
  set `gcp.network.power_button_allowed_ips` to reviewed original-client CIDRs,
  set `gcp.network.power_button_ip_depth = 0` for direct public Cloud Run (or a
  separately verified larger trusted-proxy suffix),
  `runtime.managed_runtime.internal_services_enabled = true`, and
  `runtime.managed_runtime.internal_services_auto_update = true` before
  changing the module source ref.
- To preserve the legacy app service-account JSON key during the first 1.0
  apply, set `gcp.identity.app_credentials_enabled = true`. File credentials
  are now an explicit compatibility mode, not the default.
- To adopt the safer defaults, leave power management and
  `runtime.managed_runtime.internal_services_enabled` false.

Cloud-init and identity changes can cause Terraform to replace a VM and remove
the internal-services service account and IAM bindings. Take and verify an
application backup, confirm the persistent data and Docker-volume disks remain
in the plan, and apply during a maintenance window. Never approve a plan that
destroys those disks unless data removal is intentional.

Apply the singleton GCP foundation before the application upgrade. The new
application plan intentionally removes the legacy project-level start and
suspend IAM memberships and creates instance-level memberships for the same
application identities. It does not create the reusable custom-role definitions
inside each application state. Review those IAM deletions and replacements
explicitly; do not preserve the broader legacy memberships as a compatibility
shortcut.

The upgrade also intentionally removes the legacy `roles/iam.serviceAccountUser`
membership that let the project's default Compute Engine workload service
account act as the VM service account. The Google-managed Compute Engine service
agent, not the default workload identity, performs service-account attachment.
Expect that legacy member to be deleted and do not re-add it to make the plan
smaller.

Keep the caller's module source path and module block address unchanged during
this upgrade. The in-module `moved` blocks cover five legacy GCP addresses:
the internal-services identity, its Key Admin member, its monitoring member,
the app Key Admin member, and the legacy app self-signing member. The first four
preserve identity when their corresponding compatibility features remain
enabled. The fifth gives Terraform explicit deletion provenance when the new,
more narrowly scoped managed Vault signer grant is disabled. These moves cannot
migrate state between the GCP compatibility root and `providers/gcp`
entrypoints, or between differently named caller module blocks. Treat either
refactor as a separate reviewed state migration using caller-owned `moved`
blocks or explicit `terraform state mv` commands. If old state records a
legacy provider source address, run a separately reviewed `terraform state
replace-provider` migration before planning; never edit state by hand.

To move an existing deployment from file credentials to the keyless default,
use two reviewed applies. First upgrade with
`gcp.identity.app_credentials_enabled = true`, run
`/home/cloud-compose/rotate-keys-app.sh retire` on the VM, and verify that both
the remote user-managed key and distributed credential files are gone. Then
set the option to false and apply again. A host that is configured keyless but
still contains an app key fails closed instead of silently retaining it.

The VM uses an ephemeral public address, so replacement can change it even when
both persistent disks survive. Inventory DNS records, TLS issuance/routing, and
external allowlists before applying; update and verify them against the new
address before ending the maintenance window. The hosted upgrade smoke proves
the module's state moves, update-only application-data growth from 20 to 30 GB,
mounted ext4 growth after the controlled cloud-init boot, and disk/sentinel
preservation on its fixture, not the DNS, TLS, backups, or application-specific
migrations of a downstream stack.

The `GCP WordPress` pull-request check runs this upgrade path only for
pull-request titles beginning with `[major]`; other pull requests retain the
fresh-current GCP smoke. The gate provisions the exact `0.10.2` commit
`f33117cdbbf4a9c7d59006a4db986baef118e6bb` in one detached worktree and the
tested merge commit in another, with both configurations using one absolute
local-backend state path. The fixture deliberately uses the GCP-only
compatibility root in both phases and asserts the historical
`module.app.module.gcp[0]` address, so removing non-GCP providers from root
cannot silently move an existing GCP deployment. New deployments should use
the explicit `providers/gcp` entrypoint. Both phases use a pre-provisioned, same-project CI
network and regional subnet that are outside the disposable application state.
The `0.10.2` baseline predates Shared VPC support, and a persistent subnet also
prevents Direct VPC's one-to-two-hour address-retention window from turning an
otherwise successful destroy into a false upgrade failure. CI verifies that the
network uses MTU `1460`, that the subnet belongs to it in the configured region,
and that its supported IPv4 range is `/26` or larger. The subnet and network do
not use the disposable smoke prefix, so neither the application destroy nor the
fallback sweeper owns them.

The fixture explicitly preserves power management, internal services,
internal-service automatic updates, and app file credentials. That keeps the
four identity-preserving moved resources in state while also exercising
deletion provenance for the obsolete app self-signing member, both legacy
project-level power memberships, the unused VM self-TokenCreator member, and
the legacy default Compute service-account impersonation member. Both phases
deploy the same
`libops/wp` Compose revision,
`5058610fddc7267ace92d65a5c49713dce570ac3`; an early exact checkout bridges
the legacy runtime's branch-only clone behavior without following a moving
branch. Its `gcp.cloud_init.initcmd` disables both generations of the
internal-service timer after cloud-init writes the units but before the
root-owned `/usr/local/libexec/cloud-compose/run-bootstrap.sh` entrypoint
starts the potentially long bootstrap, so the disposable VM cannot suspend
itself. The runner checks the units again after each boot.
Only the ephemeral runner key is authorized, and SSH is limited to that
runner's public IPv4 `/32`.

Before applying the current source, the gate requires Terraform plan JSON to
report all five `previous_address` transitions, requires the four preserved
resources and Docker-volume disk to be no-ops, requires the application-data
disk to be an update-only 20-to-30-GB growth, requires removal
of the two legacy project-level power memberships, the legacy default Compute
service-account impersonation member, the unused VM self-TokenCreator member,
and the obsolete app self-signing member, and requires creation of the two
instance-level power memberships. It permits no other managed-resource
deletion beyond the expected VM and boot-disk replacements. It healthchecks
WordPress before and after the upgrade,
compares provider resource IDs, rejects disk replacement and legacy addresses
in upgraded state, checks sentinels on both persistent disks, and verifies that
the mounted application-data ext4 capacity exceeds its pre-upgrade capacity
after the controlled reboot reruns cloud-init. An exit trap performs Terraform
destroy followed by the name- and run-scoped provider sweep; the same GCP job
also has an `always()` cleanup step, and the trusted default-branch cleanup
workflow remains the final fallback. In GitHub Actions the cleanup scope must
match `GITHUB_RUN_ID`; a manual invocation must provide an explicit
`CLOUD_COMPOSE_SMOKE_RUN_ID`, preventing an implicit ref fragment from owning
an unrelated prior run's resources. Because `0.10.2` predates independent
sitectl package-version selectors, its baseline bootstrap still resolves the
then-current compatible package releases; the test freezes module source and
state shape, not that legacy package repository response.

## Private repository credentials

Keep every `docker_compose_repo` URL credential-free. For a private HTTPS
repository, render a short-lived forge token from Vault to a root-controlled
staging file, then use the template command hook to install it as
`/home/cloud-compose/.config/git/credentials` owned by `cloud-compose` with
mode `0600`. Configure the `cloud-compose` user's global Git credential helper
once as:

```sh
git config --global credential.helper \
  'store --file=/home/cloud-compose/.config/git/credentials'
```

The credential file uses Git's normal credential-store format, for example
`https://x-access-token:TOKEN@github.com`. Scope the token to read only the
single repository, rotate it through Vault Agent, and never put it in the repo
URL, Terraform, cloud-init, `.env`, logs, or state. SSH deploy keys are also
valid when installed out of band with a pinned `known_hosts`, but cloud-compose
does not create or store private keys. Public repositories need no credential
configuration.

## Hosted smoke-test credentials

The pull-request workflow and the emergency cleanup workflow use separate
GitHub Environments. This is a security boundary, not only an organizational
convention:

| Purpose | GitHub Environment | Credential or configuration |
| --- | --- | --- |
| DigitalOcean create/test/destroy | `cloud-smoke-digitalocean` | `DIGITALOCEAN_TOKEN` |
| Linode create/test/destroy | `cloud-smoke-linode` | `LINODE_TOKEN` |
| GCP create/test/destroy | `cloud-smoke-gcp` | `GCLOUD_OIDC_POOL`, `GSA`, `GCLOUD_PROJECT`, optional `GCLOUD_REGION` |
| GCP major-version upgrade | `cloud-smoke-gcp` | the GCP values above plus `GCLOUD_NETWORK_PROJECT_ID`, `GCLOUD_NETWORK_NAME`, `GCLOUD_SUBNETWORK_NAME`, `GCLOUD_POWER_START_ROLE`, and `GCLOUD_POWER_SUSPEND_ROLE` |
| DigitalOcean fallback deletion | `cloud-smoke-cleanup-digitalocean` | a distinct cleanup-only `DIGITALOCEAN_TOKEN` |
| Linode fallback deletion | `cloud-smoke-cleanup-linode` | a distinct cleanup-only `LINODE_TOKEN` |
| GCP fallback deletion | `cloud-smoke-cleanup-gcp` | cleanup-specific `GCLOUD_OIDC_POOL`, `GSA`, `GCLOUD_PROJECT`, optional `GCLOUD_REGION` |

Configure required reviewers and prevent self-review on the three
`cloud-smoke-*` environments. Permit only the same-repository feature branches
that the team intends to test; jobs for forks are skipped. A reviewer is
approving execution of code from that pull request with a credential that can
create cloud resources. Each running smoke job performs its Terraform destroy
in an `always()` step, so normal cleanup uses the already-approved environment
and does not create another deployment approval.

Configure each `cloud-smoke-cleanup-*` environment with **no required
reviewers**, and set its deployment branch policy to the selected branch
`main` only. Those environments are consumed solely by the `workflow_run`
workflow loaded from the default branch. It checks out `github.sha` (the trusted
default-branch revision for that event), rejects fork-originated runs, and uses
the originating workflow run ID to constrain the sweep. Every cleanup job
builds `.bin/cloud-compose-ci` once from that trusted checkout. The compiled
runner owns GCP, DigitalOcean, and Linode discovery, retries, ordered deletion,
and residual verification for both app and config-management smoke resources.
It calls DigitalOcean and Linode through `net/http`; provider tokens are added
only to the credentialed smoke, `always()` destroy, or trusted sweep step and
sent only as authorization headers, never as process arguments or error text.
Checkout, setup, and runner-build steps do not receive provider tokens, and
trusted and provider-job checkouts set `persist-credentials: false`.
Pull-request smoke jobs also build one binary before apply and reuse that exact
workspace binary from their `always()` cleanup step. Shell remains responsible
for Terraform, SSH, cloud-init, diagnostics, and host-runtime black-box checks.
No privileged fallback executes a pull-request binary or downloads one as an
artifact. The fallback runs
automatically after a failed, cancelled, or timed-out smoke workflow, including
cases where cancellation prevented the in-job destroy from finishing. Never
allow pull-request branches in a cleanup environment's deployment policy.

GCP smoke writers encode the complete canonical numeric GitHub Actions run ID as
a fixed-width, nine-character lowercase base36 namespace. The fresh and upgrade
drivers obtain that value from the compiled `cloud-compose-ci gcp namespace`
command before Terraform can create resources. A manual fresh GCP smoke apply
must set `CLOUD_COMPOSE_SMOKE_RUN_ID`; an empty, malformed, noncanonical, or
greater-than-44-bit value fails before apply. DigitalOcean, Linode, and raw-host
config-management smoke writers validate that same canonical run ID through
`cloud-compose-ci run validate` before apply. This ensures every created
resource has an exact cleanup tag; manual smoke applies on every cloud must now
set `CLOUD_COMPOSE_SMOKE_RUN_ID`. The namespace width preserves both
separators and at least one random suffix character for every supported GCP
template within the 21-character resource-name limit. The original decimal run
ID remains the cleanup input and the source of compatibility tags; existing
DigitalOcean and Linode resource names and tags are unchanged. The GCP smoke
context additionally validates that the supplied namespace decodes to that same
canonical, at-most-44-bit run ID.

The privileged fallback always executes the default branch, so its compiled
runner remains a dual reader: it queries both the legacy first-eight-character
namespace and the exact namespace for a run. Retain the legacy reader until all
branches and resources created by the old writer have expired. A malformed,
noncanonical, or greater-than-44-bit run ID fails before apply rather than
creating a namespace that the trusted fallback cannot discover.

Use separate provider identities for smoke and fallback cleanup:

- The DigitalOcean cleanup token needs list/delete access only for firewalls,
  droplets, and volumes. It does not need create access.
- The Linode cleanup token needs read/write access for firewalls, instances, and
  volumes because Linode's token scopes combine mutation operations. It should
  be issued in a dedicated smoke account with no production resources.
- The GCP cleanup service account needs
  `run.services.get/list/delete/getIamPolicy/setIamPolicy`,
  `compute.instances.list/delete`, `compute.firewalls.list/delete`,
  `compute.disks.list/delete`, `compute.subnetworks.list/delete`,
  `compute.networks.list/delete`, `iam.serviceAccounts.list/delete`, and
  `resourcemanager.projects.getIamPolicy/setIamPolicy`. Bind the cleanup
  workload-identity principal only to the `cloud-smoke-cleanup-gcp` environment
  subject. No service-account key is stored in GitHub.

For the `libops/cloud-compose` repository, the two accepted GitHub OIDC `sub`
claims are `repo:libops/cloud-compose:environment:cloud-smoke-gcp` for the smoke
identity and
`repo:libops/cloud-compose:environment:cloud-smoke-cleanup-gcp` for the cleanup
identity. Use separate workload-identity providers or exact attribute
conditions; do not authorize a repository-wide subject wildcard.

The create/test identities need the broader permissions exercised by the
Terraform smoke modules. Put every provider's tests in an isolated smoke
project or account with quotas and billing alerts, never in a production
project. Store values as environment-level secrets or variables, and remove
all matching repository-level and organization-level secrets inherited by this
repository; otherwise pull-request code can bypass the intended environment
boundary. Only the two GCP jobs receive GitHub `id-token: write` permission.

The GCP fallback removes the public Cloud Run invoker and Cloud Run service
first, then compute instances, firewall rules, and disks. It removes per-run
logging and monitoring members and any legacy pre-1.0 project-level power
members before deleting matching VM, internal, power-button, and app service
accounts. It deletes only smoke-prefixed regional subnetworks and their parent
VPC networks; it must not own the singleton foundation or the deliberately
persistent upgrade network. Every mutation is retried, failures are accumulated
so one stuck resource does not prevent unrelated resources from being examined,
and a final query requires zero matching disposable resources and IAM members.
Discovery reads are retried independently. Subnetwork and parent-network
deletion share a bounded two-hour-ten-minute exponential-backoff window because
Direct VPC addresses can remain allocated for one to two hours after Cloud Run
disconnects; exhausting that window still fails the job and reports the leak.
The workflow fails if a mutation exhausts its retry budget or residual resources
remain, making leaks visible to operators. DigitalOcean and Linode cleanup use
the same fail-closed contract: app resources must contain the provider target
and exact `gha-run-*` tags, config-management resources must contain both of
their scope tags, and tagless DigitalOcean firewalls must match the complete
generated run-specific name. Provider `404` and `410` delete responses are
successful idempotent cleanup. Every list is fully materialized before any
resource from that list can be deleted. DigitalOcean pagination follows only an
absolute, sequential `links.pages.next` URL on the configured API origin and
exact list path with its filters intact. Linode requires present, sequential,
and stable `page`/`pages` metadata. Repeated resources, malformed metadata,
cycles, origin or path changes, and listings beyond the 100-page safety bound
fail both deletion and residual verification closed; partial listings are never
treated as success.

Provider status, timeout, retry/backoff, ordered deletion, idempotency,
pagination, and residual-consistency behavior is tested against the real Go
`net/http` client with `httptest`. The `hosted-cleanup-retry-contract` target
also retains a small, network-disabled shell lifecycle check whose
`CLOUD_COMPOSE_CI_BIN` is an explicit fake; it does not build or discover
`.bin/cloud-compose-ci` and does not emulate provider HTTP with curl. The
compiled runner requires a run ID by default;
an operator can sweep every run for one disposable target only by supplying the
explicit `--all-runs` flag. That explicit flag overrides a run ID inherited from
`CLOUD_COMPOSE_SMOKE_RUN_ID`; supplying both `--run-id` and `--all-runs`
explicitly is an error. The compatibility shell exposes the broad operation
only when `CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS=true`; a missing run ID otherwise
fails closed.
