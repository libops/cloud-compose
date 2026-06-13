# Managed Runtime

`cloud-compose` installs a small LibOps-managed runtime on each VM. The runtime
keeps host tools and LibOps-side support services current without changing the
customer application repository.

Managed by default:

- `sitectl` from `https://github.com/libops/sitectl/releases/latest`
- additional sitectl plugin packages listed in `sitectl_packages`
- the internal LibOps compose project, including CAP and lightsout images
- optional verified artifacts listed in `libops_managed_artifacts`

The updater runs once during boot before the application initializes, then on a
daily systemd timer. `sitectl_version` defaults to `latest`; set it to a tag such
as `v0.19.7` to pin all configured sitectl packages.

Application-specific plugins should be passed as package names:

```hcl
sitectl_packages = [
  "sitectl",
  "sitectl-isle",
]
sitectl_plugin = "isle"
```

Additional LibOps-owned binaries or scripts can use the artifact manifest:

```hcl
libops_managed_artifacts = [
  {
    name    = "libops-controller"
    url     = "https://example.com/libops-controller-linux-amd64"
    sha256  = "..."
    path    = "/usr/local/bin/libops-controller"
    restart = "libops-controller.service"
  }
]
```

Artifacts are downloaded, SHA-256 verified, installed atomically with `install`,
and then optionally restart a systemd unit with `systemctl try-restart`.
