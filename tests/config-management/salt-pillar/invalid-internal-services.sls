cloud_compose:
  name: invalid-internal-services
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    managed_runtime:
      internal_services_enabled: true
