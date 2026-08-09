# Examples

The `examples/` directory contains runnable Terraform entry points for common
compose app shapes.

## Single app examples

- `examples/app` deploys any supported template by setting `template`.
- `examples/archivesspace` deploys ArchivesSpace.
- `examples/ojs` deploys OJS.
- `examples/isle` deploys ISLE.
- `examples/drupal` deploys Drupal.
- `examples/wp` deploys WordPress.
- `examples/omeka-s` deploys Omeka S.
- `examples/omeka-classic` deploys Omeka Classic.
- `examples/digitalocean` deploys WordPress on DigitalOcean.
- `examples/linode` deploys Drupal on Linode.

Provider-specific entrypoints know the default compose repo, `sitectl` plugin,
and package set for each template. A minimal caller selects the provider by
module path and supplies the template:

```hcl
module "app" {
  source = "github.com/libops/cloud-compose//providers/do?ref=REPLACE_WITH_EXACT_RELEASE"

  name     = "cc-wp"
  template = "wp"
  digitalocean = {
    ssh = {
      cloud_compose_keys = var.operator_ssh_keys
    }
  }
  runtime = {
    rootfs_archive_url    = var.cloud_compose_rootfs_archive_url
    rootfs_archive_sha256 = var.cloud_compose_rootfs_archive_sha256
  }
}
```

Replace the source placeholder with an exact release that publishes all three
canonical rootfs assets, and set the URL and SHA-256 from that same release.
The runnable DigitalOcean and Linode examples intentionally provide no release
default. Terraform fetches the adjacent rootfs contract during planning and
rejects a module/archive mismatch; omitting `?ref=` would make future plans
consume a moving module source.

## GCP foundation and application states

Apply the GCP foundation once from a long-lived state, not once per site:

```hcl
module "cloud_compose_foundation" {
  source = "github.com/libops/cloud-compose//modules/gcp-foundation?ref=1.0.0"

  service_project_id = "library-production"
}

output "cloud_compose_start_role" {
  value = module.cloud_compose_foundation.cloud_compose_start_role_name
}

output "cloud_compose_suspend_role" {
  value = module.cloud_compose_foundation.cloud_compose_suspend_role_name
}
```

Publish those output values through your reviewed remote-state or deployment
configuration boundary. A separate application state consumes them; it does not
own the foundation:

```hcl
module "wp" {
  source = "github.com/libops/cloud-compose//providers/gcp?ref=1.0.0"

  name     = "cc-wp"
  template = "wp"
  gcp = {
    project_id = "library-production"
    region     = "us-east5"
    zone       = "us-east5-b"
    network = {
      power_button_allowed_ips = var.operator_cidrs
      power_button_ip_depth    = 0 # direct public Cloud Run URL
    }
    power_management = {
      enabled      = true
      start_role   = var.cloud_compose_start_role
      suspend_role = var.cloud_compose_suspend_role
    }
  }
}
```

The application module derives the project number. Do not duplicate that
identity as caller configuration. It binds the two power principals to this
application's VM instance only.

For Shared VPC, configure the foundation with the service project, host
project, and each permitted regional subnet first. Then select that network in
the application with full resource names:

```hcl
gcp = {
  project_id = "library-production"
  region     = "us-east5"
  zone       = "us-east5-b"
  network = {
    create     = false
    project_id = "organization-network"
    name       = "projects/organization-network/global/networks/library"
    subnetwork = "projects/organization-network/regions/us-east5/subnetworks/cloud-run-us-east5"
    mtu        = 1460 # attests the reviewed network's real MTU
    power_button_allowed_ips = var.operator_cidrs
    power_button_ip_depth    = 0 # direct public Cloud Run URL
  }
  power_management = {
    enabled      = true
    start_role   = var.cloud_compose_start_role
    suspend_role = var.cloud_compose_suspend_role
  }
}
```

The subnet must be in the Cloud Run region, use a supported IPv4 `/26` or larger
range, and have enough free addresses for allocation blocks and overlapping
revisions. The foundation grants the Cloud Run service agent Network Viewer on
the host project and Network User on the explicit subnet. The application
deployment identity separately needs permission to inspect and use the network
and to manage its app-specific firewall rules.

Use `runtime` only for overrides such as branch, ingress, Vault Agent, or
healthcheck settings:

```hcl
runtime = {
  sitectl = {
    package_versions = {
      sitectl      = "v1.8.2"
      sitectl-wp   = "v2.0.0"
    }
  }
  compose = {
    branch = "v1.1.0"
    ingress = {
      letsencrypt    = true
      bot_mitigation = true
      domain         = "example.org"
      acme_email     = "ops@example.org"
    }
  }
}
```

The same template defaults are stored in `templates/apps.json` and are reused by
the Ansible role and Salt formula for existing Debian/Ubuntu hosts. Terraform
presets also consume the registry's exact `package_versions`; an explicit
`runtime.sitectl.package_versions` entry replaces the matching preset selector.

## Bin packing

`examples/binpack` shows how several compose projects can share one VM:

```hcl
runtime = {
  compose = {
    primary = "wp"
    projects = {
      wp = {
        docker_compose_repo = "https://github.com/libops/wp.git"
        ingress_port        = 8080
        sitectl_plugin      = "wp"
        sitectl_packages    = ["sitectl-wp"]
      }
      drupal = {
        docker_compose_repo = "https://github.com/libops/drupal.git"
        ingress_port        = 8081
        sitectl_plugin      = "drupal"
        sitectl_packages    = ["sitectl-drupal"]
      }
    }
  }
  sitectl = {
    package_versions = {
      sitectl        = "v1.8.2"
      sitectl-wp     = "v2.0.0"
      sitectl-drupal = "v1.3.0"
    }
  }
}
```

`cloud-compose` provides the VM/runtime primitives for bin packing. Placement
policy is intentionally left to consumers for now. Every project in one GCP
application state shares the host, Docker daemon and kernel boundary, app
service account, managed Vault workload identity, and—when legacy file
credentials are explicitly enabled—the same app JSON credential. Bin-pack only
applications that belong to the same IAM and secret trust boundary. Use
separate application states and VMs when an app needs an independent workload
identity, credential, or host isolation boundary.
