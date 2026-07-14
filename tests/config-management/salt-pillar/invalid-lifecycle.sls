cloud_compose:
  name: invalid-lifecycle
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      init:
        - valid-command
        - 42
