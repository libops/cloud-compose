# cloud-compose Ansible Adapter

This role deploys the cloud-compose runtime onto an existing Debian or Ubuntu
host. Use it when Terraform should not create the VM, disks, firewall, or DNS.

The role consumes the same `templates/apps.json` template defaults used by the
Terraform provider modules.

The packaged runtime currently uses fixed host paths: `/home/cloud-compose`,
`/mnt/disks/data`, and `/mnt/disks/volumes`.

The normal on-prem shape is one app per machine. Put each machine in the
`cloud_compose` inventory group and set that host's template/runtime variables.
For multiple apps on one host, pass the same
`cloud_compose_runtime.compose.projects` shape used by Terraform.

Example inventory:

```yaml
all:
  children:
    cloud_compose:
      hosts:
        isle-prod.example.edu:
          ansible_user: debian
          cloud_compose_name: isle-prod
          cloud_compose_template: isle
          cloud_compose_runtime:
            compose:
              ingress:
                domain: isle.example.edu
                acme_email: admin@example.edu
            sitectl:
              environment: production
        wp-prod.example.edu:
          ansible_user: debian
          cloud_compose_name: wp-prod
          cloud_compose_template: wp
          cloud_compose_runtime:
            compose:
              ingress:
                domain: wp.example.edu
                acme_email: admin@example.edu
```

Run:

```bash
ansible-playbook ansible/playbooks/site.yml
```
