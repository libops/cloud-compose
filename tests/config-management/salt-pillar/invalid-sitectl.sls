cloud_compose:
  name: invalid-sitectl
  provider: onprem
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  dedicated_host_acknowledged: true
  template: wp
  runtime:
    sitectl:
      version: v0.38.0/../../latest
