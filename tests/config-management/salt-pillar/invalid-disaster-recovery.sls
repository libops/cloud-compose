cloud_compose:
  name: invalid-disaster-recovery
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    disaster_recovery:
      required: true
      driver_path: /usr/local/libexec/cloud-compose/../untrusted
