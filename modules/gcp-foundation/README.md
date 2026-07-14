# GCP foundation

This module owns the singleton Google Cloud prerequisites shared by Cloud
Compose application stacks. Keep it in a small, long-lived Terraform state and
apply it before any per-site or per-application state.

It manages, by default:

- `cloudresourcemanager.googleapis.com`, `compute.googleapis.com`,
  `iam.googleapis.com`, `iamcredentials.googleapis.com`,
  `logging.googleapis.com`, `monitoring.googleapis.com`, and
  `run.googleapis.com`;
- the Cloud Run Google-managed service identity, created explicitly after the
  API is enabled so Shared VPC IAM does not race service-agent provisioning;
- the documented `roles/run.serviceAgent` binding for that identity in the
  service project;
- the project-scoped `cloudComposeStart` role with only
  `compute.instances.get`, `compute.instances.start`, and
  `compute.instances.resume`;
- the project-scoped `cloudComposeSuspend` role with only
  `compute.instances.get` and `compute.instances.suspend`;
- Cloud Run Direct VPC IAM when the VPC host project differs from the service
  project; and
- optionally, the Shared VPC service-project attachment itself.

The module queries the service project and derives the Cloud Run service agent
`service-PROJECT_NUMBER@serverless-robot-prod.iam.gserviceaccount.com` from
authoritative project metadata. Downstream callers supply only the project ID,
not a separate numeric identity.

The two custom roles are reusable definitions. They are project-scoped because
Google custom roles must have a project or organization parent, but this module
does not grant them to application principals. Each Cloud Compose application
state consumes the role names and binds its proxy and internal-services service
accounts only to that application's Compute Engine instance.

## Lifecycle contract

These resources are deliberately safer than ordinary app-stack resources:

- Required APIs use `disable_on_destroy = false` and `deletion_policy =
  "ABANDON"`, so removing the foundation state does not disable APIs used by
  surviving workloads.
- Custom roles use `deletion_policy = "PREVENT"` plus Terraform
  `prevent_destroy`. A normal destroy or a change that would replace either
  role fails at planning instead of soft-deleting a long-lived project role.
  Change both controls only during a reviewed decommission.
- The Cloud Run service-agent role membership also uses `prevent_destroy`, so
  external ownership of the power roles cannot make an ordinary foundation
  destroy revoke a Google-managed identity that surviving services require.
- A module-managed Shared VPC attachment uses `deletion_policy = "ABANDON"` so
  state removal does not unexpectedly detach a service project.
- Shared VPC IAM uses non-authoritative member resources. Network Viewer is
  scoped to the host project, while Network User is scoped to one explicit
  regional subnet.

Because role deletion is prevented, this module is not intended to be destroyed
as part of an application teardown. Disconnect every Cloud Run revision, retire
all application states, verify that no other workloads consume the APIs, roles,
service identity, subnets, or Shared VPC attachment, and wait for Direct VPC
addresses to be released before a separately reviewed decommission. Do not
disable the APIs or detach Shared VPC merely because one site is removed.

## Usage

Same-project networking:

```hcl
module "gcp_foundation" {
  source = "github.com/libops/cloud-compose//modules/gcp-foundation?ref=1.0.0"

  service_project_id = "library-production"
}
```

Shared VPC whose association should also be managed here:

```hcl
module "gcp_foundation" {
  source = "github.com/libops/cloud-compose//modules/gcp-foundation?ref=1.0.0"

  service_project_id = "library-production"
  host_project_id    = "organization-network"
  shared_vpc_subnetworks = [{
    name   = "cloud-run-us-east5"
    region = "us-east5"
  }]
  attach_shared_vpc = true
}
```

Use an exact reviewed release or full commit in production. Keep this module in
a state whose lifetime is the service project, not the application. Apply it
before any application state and publish only the role-name outputs needed by
those states.

For same-project networking, this module creates no additional Network Viewer
or Network User membership. It manages the Cloud Run service agent's standard
`roles/run.serviceAgent` membership in the service project, restoring that
documented grant if an earlier project policy removed it.

When `host_project_id` differs from `service_project_id`, at least one explicit
subnet is required even if the Shared VPC attachment is managed in a different
state. Add every subnet used by Cloud Compose stacks in that service project.
The module always grants the derived Cloud Run service agent
`roles/compute.networkViewer` on the host project and
`roles/compute.networkUser` on that subnet, matching the Direct VPC Shared VPC
contract without granting Network User across the whole host project.

In each consuming application, set `gcp.network.project_id` to the host project
and prefer full resource names so project and region selection is explicit:

```text
projects/HOST_PROJECT/global/networks/NETWORK
projects/HOST_PROJECT/regions/REGION/subnetworks/SUBNET
```

The application rejects a project mismatch, a subnet attached to a different
network, or a subnet outside the Cloud Run region. Its deployment identity also
needs separately reviewed permission to inspect and use the host network and to
manage application-specific firewall rules; this foundation's service-agent IAM
does not grant permissions to the Terraform caller.

This least-privilege contract targets IPv4 and internal-IPv6 subnets. A
dual-stack subnet with external IPv6 also requires Compute Public IP Admin;
manage that exceptional grant separately rather than broadening this module's
default role set. Size Direct VPC subnets to `/26` or larger in the network
foundation or consuming app-stack validation, use Cloud Run's default MTU
`1460`, and reserve capacity for `/28` allocation blocks, two addresses per
steady-state service instance, and overlapping revisions. Cloud Run addresses
are ephemeral, so firewall rules must use the entire subnet CIDR rather than
individual revision addresses.

Existing-network callers attest the reviewed network's real MTU through the
application input; changing the Terraform value cannot correct a network whose
actual MTU differs. Cloud Run can retain addresses for one to two hours after a
revision is disconnected. Prefer a persistent shared subnet where lifecycle
independence matters, and wait for address release before deleting or moving
that subnet. A persistent CI subnet is especially useful for upgrade tests: it
keeps delayed serverless address release from making disposable application
teardown flaky and must remain outside smoke-name cleanup ownership.

Set `manage_project_services = false` or `manage_power_roles = false` only when
another long-lived foundation state owns those exact resources. Role-name
outputs remain canonical in externally managed mode. Treat these booleans as
initial ownership choices: after this module creates a `PREVENT` role, hand its
state to another foundation deliberately rather than toggling
`manage_power_roles` and expecting Terraform to delete it.

The identity running Terraform needs permission to inspect the service project,
enable project services, manage project custom roles, and update IAM on the
Shared VPC host project and subnet. `serviceusage.googleapis.com` must already
be enabled so Terraform can enable the seven workload APIs.

The separate identity that applies each application state also needs
`iam.serviceAccounts.actAs` (normally `roles/iam.serviceAccountUser`) on the VM
service account it attaches. Do not grant that role to the project's default
Compute Engine workload service account; the app module deliberately removes
that legacy impersonation edge.

See Google's [Direct VPC Shared VPC
guide](https://cloud.google.com/run/docs/configuring/shared-vpc-direct-vpc) for
the service-agent IAM and subnet-sizing contract.

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `service_project_id` | required | Project that owns Cloud Run and Compute workloads. |
| `host_project_id` | `""` | Shared VPC host; empty means the service project. |
| `shared_vpc_subnetworks` | `[]` | Explicit Shared VPC subnet names and regions available to Direct VPC egress. |
| `manage_project_services` | `true` | Manage the seven required APIs. |
| `manage_power_roles` | `true` | Manage the two least-privilege custom roles. |
| `attach_shared_vpc` | `false` | Manage the Shared VPC service-project association. |

## Outputs

| Name | Description |
| --- | --- |
| `project_number` | Derived numeric service project ID. |
| `cloud_run_service_agent_email` | Derived Cloud Run service-agent email. |
| `cloud_run_service_agent_member` | IAM member form of the service agent. |
| `cloud_compose_start_role_name` | Canonical start/resume custom-role name. |
| `cloud_compose_suspend_role_name` | Canonical suspend custom-role name. |
