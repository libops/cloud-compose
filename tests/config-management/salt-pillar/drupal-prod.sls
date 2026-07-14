cloud_compose:
  name: drupal-prod
  provider: onprem
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  dedicated_host_acknowledged: true
  template: drupal
  runtime:
    compose:
      project_dir: /mnt/disks/data/libops/drupal/main
      ingress:
        domain: drupal.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
