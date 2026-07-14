cloud_compose:
  name: invalid-vault
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    vault:
      agent_enabled: true
