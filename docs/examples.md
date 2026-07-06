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
  source = "github.com/libops/cloud-compose//providers/do"

  name     = "cc-wp"
  template = "wp"
  digitalocean = {
    ssh = {
      cloud_compose_keys = var.operator_ssh_keys
    }
  }
}
```

Use `runtime` only for overrides such as branch, ingress, Vault Agent, or
healthcheck settings:

```hcl
runtime = {
  compose = {
    branch = "main"
    ingress = {
      letsencrypt    = true
      bot_mitigation = true
      domain         = "example.org"
      acme_email     = "ops@example.org"
    }
  }
}
```

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
}
```

`cloud-compose` provides the VM/runtime primitives for bin packing. Placement
policy is intentionally left to consumers for now.
