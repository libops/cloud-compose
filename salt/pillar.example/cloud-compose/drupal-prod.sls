cloud_compose:
  name: drupal-prod
  provider: onprem
  template: drupal
  dedicated_host_acknowledged: true
  runtime:
    compose:
      ingress:
        domain: drupal.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
