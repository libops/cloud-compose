cloud_compose:
  name: invalid-reserved-env
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  extra_env:
    LIBOPS_FUTURE_CONTROL: "true"
