cloud_compose:
  name: isle-prod
  provider: onprem
  template: isle
  dedicated_host_acknowledged: true
  runtime:
    compose:
      ingress:
        domain: isle.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
