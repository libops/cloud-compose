cloud_compose:
  name: invalid-project
  provider: onprem
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      projects:
        "Bad/Name":
          docker_compose_repo: https://github.com/libops/wp.git
          ingress_port: 80
