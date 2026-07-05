# Examples

The `examples/` directory contains runnable Terraform entry points for common
compose app shapes.

## Single app examples

- `examples/ojs` deploys OJS production and staging environments.
- `examples/wp` deploys a WordPress compose project with `sitectl-wp`.
- `examples/drupal` deploys a Drupal compose project with `sitectl-drupal`.
- `examples/isle` deploys an ISLE compose project with `sitectl-isle`.
- `examples/digitalocean` deploys WordPress on DigitalOcean.
- `examples/linode` deploys Drupal on Linode.

Each single-app example passes a provider object and a runtime object:

```hcl
runtime = {
  compose = {
    repo   = "https://github.com/libops/wp.git"
    branch = "main"
  }
  sitectl = {
    packages = ["sitectl", "sitectl-wp"]
    plugin   = "wp"
  }
}
```

## Bin packing

`examples/binpack` shows how several compose projects can share one VM:

```hcl
compose_projects = {
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
