# Disaster recovery driver

Cloud Compose keeps a same-disk logical MariaDB dump for each application and
can hand a complete recovery manifest to an operator-owned off-host backup
driver. The interface is provider-neutral: cloud-compose does not choose an
object store, account, encryption service, retention policy, or credential
mechanism.

Local dumps and provider boot-disk snapshots are recovery aids, not disaster
recovery. A site has DR coverage only after the nightly unit publishes a valid
receipt proving encrypted off-host coverage of every database, application-file
root, bind mount, named volume, and service-mount topology in the manifest.

## Enable the contract

Install the reviewed driver and all of its configuration out of band. The file
and every directory in its path must be root-owned, must not be a symlink or be
group/world writable, and the executable must have exactly one hard link.
`/etc/cloud-compose/libexec/offhost-backup-driver` is the portable default on
COS and conventional Linux hosts. An explicit safe absolute path remains
supported when an operator manages the driver elsewhere. Because COS rebuilds
`/etc` at boot, provide the driver through the configured rootfs overlay or an
equivalent startup provisioner there; a one-time manual copy will not survive a
reboot. Keep credentials outside that overlay.
Then enable the provider-neutral runtime input:

```hcl
runtime = {
  disaster_recovery = {
    required    = true
    driver_path = "/etc/cloud-compose/libexec/offhost-backup-driver"
  }
}
```

Terraform, cloud-init, `.env`, plans, state, and application lifecycle commands
must not contain a storage endpoint, bucket credential, encryption key, or
access token. The driver owns those details. A root-only configuration file,
host workload identity, or an operator-managed Vault integration are suitable
implementation choices. Do not use `runtime.extra_env` for driver credentials.

Ansible and Salt accept the same nested `runtime.disaster_recovery` object.
Changing `required` to `true` before the driver is installed intentionally
makes the next nightly handoff and weekly restore test fail.

## Backup invocation

The nightly `cloud-compose-mariadb-backup.timer` starts
`cloud-compose-offhost-backup.service`. Systemd first runs the existing
unprivileged MariaDB dump service. The root service then creates a deterministic
manifest and invokes:

```text
DRIVER backup \
  --manifest PATH \
  --manifest-sha256 SHA256 \
  --operation-id YYYYMMDD-SITE \
  --receipt PATH
```

The driver receives a clean environment containing only `HOME=/root` and a
fixed system `PATH`. Its stdout and stderr are suppressed so an accidental SDK
or credential diagnostic cannot enter the system journal. The driver must load
its own operator-managed configuration and write its receipt to the requested
path. It must not modify the manifest.

For every app, the manifest includes:

- a root-only staged copy of the validated `sql.gz` logical dump, including its
  SHA-256 and byte count;
- the application checkout root and persistent bind-mount sources;
- every declared named volume; and
- every resolved Compose service mount, including target, type, source, and
  read-only state.

Cloud Compose extracts only this topology from `docker compose config`; the
rendered Compose model, which can contain application environment values, stays
in a mode-0600 staging directory and is deleted. Persistent bind mounts outside
`/mnt/disks/data` and `/mnt/disks/volumes` fail closed instead of extending the
privileged backup boundary.

The driver must finish encrypting and durably transferring every referenced
component before it writes this exact receipt shape:

```json
{
  "schema_version": 1,
  "kind": "cloud-compose.offhost-backup-receipt",
  "operation_id": "20260807-example-site",
  "completed_at": "2026-08-07T12:00:00Z",
  "manifest_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "encrypted": true,
  "off_host": true,
  "status": "succeeded",
  "remote_id": "operator-safe-opaque-reference",
  "coverage": {
    "database": true,
    "application_files": true,
    "volume_topology": true
  }
}
```

`remote_id` is deliberately constrained to a short opaque identifier; it must
not contain a signed URL, token, query string, or credential. Unknown fields,
missing coverage, false encryption/off-host claims, a mismatched operation or
manifest digest, unsafe ownership, links, oversized JSON, and malformed values
are rejected. The validated manifest and receipt are atomically published under
`/mnt/disks/data/.cloud-compose-disaster-recovery/`. Driver failure leaves the
last valid receipt untouched.

The off-host handoff runs even when the day's valid local dump already exists.
That is what lets the timer retry an earlier transfer failure without rewriting
the database artifact. The local dump remains subject to its independent
14-day retention policy and must never be reported as DR coverage.

## Scheduled restore proof

When DR is required, bootstrap enables `cloud-compose-restore-test.timer`. It
runs weekly on Sunday with a stable randomized delay of up to six hours. The
service selects the newest validated backup receipt, creates a cryptographically
random one-time test ID, and invokes:

```text
DRIVER restore-test \
  --manifest PATH \
  --backup-receipt PATH \
  --source-manifest-sha256 SHA256 \
  --source-receipt-sha256 SHA256 \
  --test-id ONE_TIME_ID \
  --proof PATH
```

The driver must restore from off-host encrypted storage into a disposable
recovery environment, verify the database plus representative application-file
and volume data, and destroy that environment. Only then may it emit:

```json
{
  "schema_version": 1,
  "kind": "cloud-compose.restore-test-proof",
  "test_id": "20260807T130000Z-random-challenge",
  "completed_at": "2026-08-07T13:00:00Z",
  "source_manifest_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "source_receipt_sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
  "source_encrypted": true,
  "status": "succeeded",
  "recovery_id": "operator-safe-opaque-reference",
  "disposable_recovery": true,
  "recovery_destroyed": true,
  "integrity_verified": true,
  "coverage": {
    "database": true,
    "application_files": true,
    "volume_topology": true
  }
}
```

The one-time ID and both source digests prevent a stale proof from satisfying a
new run. Proofs use the same root-owned, bounded, exact-schema, atomic
publication rules as backup receipts.

## Operator checks

Treat either unit failure as loss of the managed recovery claim and alert on it:

```bash
systemctl status cloud-compose-mariadb-backup.service \
  cloud-compose-offhost-backup.service \
  cloud-compose-restore-test.service
journalctl -u cloud-compose-offhost-backup.service \
  -u cloud-compose-restore-test.service
```

The journal intentionally contains only cloud-compose's generic status and
validation errors. Driver-specific diagnostics must go to an operator-owned
root-only sink that applies its own secret redaction.

Before approving a destructive Terraform plan, verify that the newest backup
receipt covers the current topology and that a recent restore proof exists.
Provider snapshots can shorten recovery time, but they do not replace this
independent encrypted copy and disposable restore evidence.
