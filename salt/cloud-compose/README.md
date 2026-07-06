# cloud-compose Salt Formula

This formula deploys the cloud-compose runtime onto an existing Debian or
Ubuntu host. Use it when Salt already manages the OS, network, storage, DNS, and
firewall, and cloud-compose should only manage the application runtime.

The formula reads `templates/apps.json`, so template defaults stay shared with
the Terraform provider modules and the Ansible role.

The packaged runtime currently uses fixed host paths: `/home/cloud-compose`,
`/mnt/disks/data`, and `/mnt/disks/volumes`.

Your Salt `file_roots` must expose the repository root so these paths resolve:

```yaml
file_roots:
  base:
    - /srv/cloud-compose
```

Example pillar:

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
salt 'isle.example.edu' state.apply cloud-compose
```
