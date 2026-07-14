cloud_compose:
  name: invalid-project-dir-etc
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      project_dir: /etc
