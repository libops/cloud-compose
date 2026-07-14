cloud_compose:
  name: invalid-project-dir-symlink
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    compose:
      project_dir: /mnt/disks/data/escape/site
