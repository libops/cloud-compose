# Rollout API

`cloud-compose` can optionally run a small authenticated HTTP service on the VM
that triggers a compose project rollout. This is generic infrastructure: callers
send a signed request, the VM validates the bearer JWT, and the service runs the
commands configured in `docker_compose_rollout`.

## Terraform

```hcl
module "site" {
  source = "github.com/libops/cloud-compose"

  # existing cloud-compose inputs...

  rollout_enabled        = true
  rollout_release_url    = "https://example.com/releases/cloud-compose-rollout-linux-amd64"
  rollout_release_sha256 = "..."
  rollout_jwks_uri       = "https://www.googleapis.com/oauth2/v3/certs"
  rollout_jwt_audience   = "libops-site-controller:<site_public_id>"
  # Default shown for clarity: controller-ingress reaches rollout over direct
  # VPC egress to the VM internal IP.
  rollout_allowed_ipv4   = ["10.0.0.0/8"]

  docker_compose_rollout = [
    "if [ -x ./scripts/rollout.sh ]; then exec ./scripts/rollout.sh; fi",
    "TARGET_REF=\"$${GIT_REF:-$${GIT_BRANCH:-$${DOCKER_COMPOSE_BRANCH:-main}}}\"",
    "git fetch origin \"$TARGET_REF\" || git fetch origin",
    "git checkout \"$TARGET_REF\" || git checkout FETCH_HEAD",
    "systemctl restart cloud-compose",
  ]
}
```

`rollout_release_url` should point to a pinned Linux binary built from the
generic rollout service. `rollout_release_sha256` is required so the VM verifies
the binary before installing it.

The rollout service listens on `rollout_port`, which defaults to `8081`.
`rollout_allowed_ipv4` controls the VM firewall rule for that port and defaults
to `10.0.0.0/8`. LibOps controller-ingress calls the VM's internal IP over Cloud
Run direct VPC egress, so this allows private control-plane traffic without
opening the rollout endpoint to the public internet.

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

The JWT must validate against `rollout_jwks_uri`, include the configured
`rollout_jwt_audience` as `aud`, and match any JSON object in
`rollout_custom_claims`.

Example request:

```json
{
  "request_type": "deployment",
  "site_public_id": "site-uuid",
  "project_public_id": "project-uuid",
  "org_public_id": "org-uuid",
  "deployment_id": "deployment-uuid",
  "git_ref": "refs/pull/123/head",
  "git_branch": "feature-branch"
}
```

Every non-empty field accepted by the service is exported as an environment
variable before `docker_compose_rollout` runs:

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

The generated rollout script runs from the checked-out compose repository after
sourcing `/home/cloud-compose/profile.sh`. First-class LibOps app templates
should commit `scripts/rollout.sh`; the default `docker_compose_rollout` will
delegate to that script when it exists, otherwise it falls back to a generic git
checkout and `cloud-compose` service restart.
