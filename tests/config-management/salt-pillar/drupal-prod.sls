cloud_compose:
  name: drupal-prod
  provider: onprem
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  template: drupal
  runtime:
    compose:
      ingress:
        domain: drupal.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
