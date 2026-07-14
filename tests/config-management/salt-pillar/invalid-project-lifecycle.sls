cloud_compose:
  name: invalid-project-lifecycle
  provider: onprem
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      projects:
        wp:
          docker_compose_repo: https://github.com/libops/wp.git
          docker_compose_up: not-a-list
