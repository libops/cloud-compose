cloud_compose:
  name: wp-prod
  provider: onprem
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  template: wp
  runtime:
    compose:
      ingress:
        domain: wp.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
