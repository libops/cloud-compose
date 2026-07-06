# cloud-compose Salt Formula

This formula deploys the cloud-compose runtime onto an existing Debian or
Ubuntu host. Use it when Salt already manages the OS, network, storage, DNS, and
firewall, and cloud-compose should only manage the application runtime.

The formula reads `templates/apps.json`, so template defaults stay shared with
the Terraform provider modules and the Ansible role.

The packaged runtime currently uses fixed host paths: `/home/cloud-compose`,
`/mnt/disks/data`, and `/mnt/disks/volumes`.

The normal on-prem shape is one app per machine. Use pillar targeting to give
each minion its own `cloud_compose` values, then apply the same
`cloud-compose` state to every app host.

Your Salt `file_roots` must expose both the formula and repository root so the
formula and packaged rootfs resolve. Your `pillar_roots` should point at your
environment-specific pillar tree:

```yaml
file_roots:
  base:
    - /srv/cloud-compose/salt
    - /srv/cloud-compose
pillar_roots:
  base:
    - /srv/cloud-compose/salt/pillar.example
```

Example pillar top:

```yaml
base:
  'isle-prod.example.edu':
    - cloud-compose.isle-prod
  'wp-prod.example.edu':
    - cloud-compose.wp-prod
```

Example per-host pillar:

```yaml
cloud_compose:
  name: isle-prod
  template: isle
  runtime:
    compose:
      ingress:
        domain: isle.example.edu
        acme_email: admin@example.edu
    sitectl:
      environment: production
```

Apply:

```bash
salt 'isle-prod.example.edu' state.apply cloud-compose
salt 'wp-prod.example.edu' state.apply cloud-compose
```
