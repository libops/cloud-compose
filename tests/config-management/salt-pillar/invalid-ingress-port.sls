cloud_compose:
  name: invalid-ingress-port
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      ingress_port: 80.5
