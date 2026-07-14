cloud_compose:
  name: invalid-project-repo
  provider: onprem
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      projects:
        wp:
          ingress_port: 80
