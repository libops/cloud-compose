cloud_compose:
  name: isle-prod
  provider: onprem
  template: isle

  runtime:
    compose:
      ingress:
        domain: isle.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
