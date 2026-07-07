cloud_compose:
  name: wp-prod
  provider: onprem
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  template: wp
  runtime:
    compose:
      project_dir: /opt/wp
      ingress:
        domain: wp.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
