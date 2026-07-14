cloud_compose:
  name: invalid-primary
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      primary: missing
      projects:
        wp:
          docker_compose_repo: https://github.com/libops/wp.git
