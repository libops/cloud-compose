# Rollout API

`cloud-compose` can optionally run a small authenticated HTTP service on the VM
that triggers a compose project rollout. This is generic infrastructure: callers
send a signed request, the VM validates the bearer JWT, and the service runs the
commands configured in `runtime.compose.rollout`.

## Terraform

```hcl
module "site" {
  source = "github.com/libops/cloud-compose//providers/gcp?ref=1.0.0"

  name = "example-site"
  gcp = {
    project_id = var.gcp_project_id
    rollout = {
      enabled        = true
      release_url    = "https://example.com/releases/cloud-compose-rollout-linux-amd64"
      release_sha256 = var.rollout_release_sha256
      jwks_uri       = "https://www.googleapis.com/oauth2/v3/certs"
      jwt_audience   = "libops-site-controller:<site_public_id>"
      # controller-ingress reaches rollout over direct VPC egress to the VM.
      allowed_ipv4 = ["10.0.0.0/8"]
    }
  }

  runtime = {
    compose = {
      rollout = [
        "/home/cloud-compose/default-lifecycle.sh rollout",
      ]
    }
  }
}
```

The `runtime.compose.rollout` entry above is the built-in default and may be
omitted. It is shown to make the single-program execution boundary explicit.

The example pins the reviewed cloud-compose `1.0.0` release. Replace that ref
only with an exact reviewed release or full commit. `gcp.rollout.release_url`
should point to a pinned Linux binary built from the generic rollout service;
`gcp.rollout.release_sha256` is required so the VM verifies the binary before
installing it. Both the release URL and JWKS URI must use HTTPS. Binary download
and redirects are restricted to HTTPS with TLS 1.2 or newer. The VM rejects
an insecure JWKS transport before starting the command-executing rollout
service, and `custom_claims` must be empty or a JSON object. Apply the singleton GCP foundation before this application
state; cloud-compose derives project metadata from `gcp.project_id` rather than
requiring a caller-supplied numeric project identifier.

The rollout service listens on `gcp.rollout.port`, which defaults to `8081`.
`gcp.rollout.allowed_ipv4` controls the VM firewall rule for that port and
defaults to `10.0.0.0/8`. LibOps controller-ingress calls the VM's internal IP
over Cloud Run Direct VPC egress, so this allows private control-plane traffic
without opening the rollout endpoint to the public internet. This is outbound
VPC connectivity from the Cloud Run service, not Direct VPC ingress. In
production, replace the broad default with the exact controller subnet CIDR and
ensure that subnet is `/26` or larger, is in the controller's Cloud Run region,
and uses the default MTU `1460`. Controller-ingress networking and service-agent
IAM remain owned by its own foundation; this application state owns only the VM
firewall rule.

On the VM these trusted settings use the `ROLLOUT_PORT`, `ROLLOUT_JWKS_URI`,
`ROLLOUT_JWT_AUD`, and `ROLLOUT_CUSTOM_CLAIMS` host-control names. The service
maps them to the generic names expected by the rollout binary only when it is
executed. Values supplied through `runtime.extra_env` are application-only
Compose data, so an app-level `PORT`, `JWKS_URI`, `JWT_AUD`, or `CUSTOM_CLAIMS`
cannot change the rollout listener or authentication policy.

## HTTP Surface

The service exposes:

- `GET /healthcheck`
- `POST /rollout`
- `POST /reconcile/deployment`

Rollout endpoints require:

```http
Authorization: Bearer <jwt>
Content-Type: application/json
```

The JWT must validate against `gcp.rollout.jwks_uri`, include the configured
`gcp.rollout.jwt_audience` as `aud`, and match any JSON object in
`gcp.rollout.custom_claims`.

Example request:

```json
{
  "request_type": "deployment",
  "site_public_id": "site-uuid",
  "project_public_id": "project-uuid",
  "org_public_id": "org-uuid",
  "deployment_id": "deployment-uuid",
  "git_ref": "refs/pull/123/head",
  "git_branch": "feature-branch",
  "rollout_arg1": "manifest-app-key"
}
```

Every non-empty field accepted by the service is exported as an environment
variable before `runtime.compose.rollout` runs:

- `GIT_REF`
- `GIT_BRANCH`
- `GIT_REPO`
- `DOCKER_IMAGE`
- `DOCKER_TAG`
- `DEPLOYMENT_ID`
- `SITE_PUBLIC_ID`
- `PROJECT_PUBLIC_ID`
- `ORG_PUBLIC_ID`
- `REQUEST_TYPE`
- `ROLLOUT_ARG1`
- `ROLLOUT_ARG2`
- `ROLLOUT_ARG3`

For bin-packed hosts, set `rollout_arg1` to the exact app key from
`compose_projects`. The shared dispatcher maps that value to
`CLOUD_COMPOSE_APP` only for the rollout lifecycle and validates it against the
manifest before running any command. Omit it to retain the primary-app default.

The root-owned default lifecycle program runs from the checked-out compose
repository after the host dispatcher loads the validated app environment. For
controller-compatible callers that additionally provide `GIT_COMMIT_SHA`, the
default contract requires an exact lowercase 40-character commit SHA and
prefers it over `GIT_REF`, then `GIT_BRANCH`. The authenticated rollout service
currently supplies the latter two fields. When a source selector is present,
`sitectl deploy --ref`
fetches that exact remote ref into a dedicated local ref, verifies it resolves
to a commit, and checks it out detached before invoking the active plugin's
component lifecycle. This supports branch names, advertised commit IDs, and
provider refs such as `refs/pull/123/head` without rewriting the checkout's
configured branch. When neither is present, `sitectl deploy --skip-git`
reconciles the current checkout without moving its source ref. A successful
rollout becomes the deployed checkout: ordinary `up` operations and service
restarts preserve it rather than first forcing it through the configured
baseline branch. A later explicit rollout can therefore move from a feature or
pull-request ref back to the baseline cleanly. The default then always runs
`sitectl healthcheck`; non-production environments also run `sitectl verify`
with the project's configured verify arguments.

Templates do not need a host-specific rollout script. Keep application rollout
behavior in the sitectl plugin's component definitions so Terraform, Ansible,
Salt, operator-driven deploys, and the authenticated rollout service all use the
same lifecycle contract. Override `runtime.compose.rollout` only when the whole
command contract needs to change, and preserve the deploy, healthcheck, and
non-production verification gates in any override.

## DigitalOcean and Linode

The same service is available through `digitalocean.rollout` and
`linode.rollout`. Supply the same pinned release URL/digest, HTTPS JWKS URI,
audience, and optional claims used on GCP. Non-GCP providers deliberately have
no broad default control-plane network: enabling rollout requires explicit
source CIDRs, which are added to the provider firewall for only the rollout
port. The resulting `rollout` output contains the private host, port, and JWT
audience. The Linux runtime installs the verified binary and enables the same
systemd service; request payloads and per-app targeting are identical on every
cloud.

Ansible and Salt accept the same settings under `runtime.rollout`; they write
the `ROLLOUT_*` host environment, install the digest-pinned binary, and start
the unit. They deliberately do not own a cloud firewall. Authorize the exact
controller CIDR at the host or upstream firewall before enabling the listener.
