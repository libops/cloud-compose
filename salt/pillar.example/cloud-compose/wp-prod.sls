cloud_compose:
  name: wp-prod
  provider: onprem
  template: wp
  runtime:
    compose:
      ingress:
        domain: wp.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
