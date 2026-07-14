cloud_compose:
  name: invalid-env
  provider: onprem
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  dedicated_host_acknowledged: true
  template: wp
  extra_env:
    BAD-NAME: value
