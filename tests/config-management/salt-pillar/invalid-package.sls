cloud_compose:
  name: invalid-package
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    sitectl:
      packages:
        - sitectl
        - bad/package
