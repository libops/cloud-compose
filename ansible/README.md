# cloud-compose Ansible Adapter

This role deploys the cloud-compose runtime onto an existing Debian or Ubuntu
host. Use it when Terraform should not create the VM, disks, firewall, or DNS.

The role consumes the same `templates/apps.json` template defaults used by the
Terraform provider modules.

The packaged runtime currently uses fixed host paths: `/home/cloud-compose`,
`/mnt/disks/data`, and `/mnt/disks/volumes`. For multiple apps on one host, pass
the same `cloud_compose_runtime.compose.projects` shape used by Terraform.

Example inventory:

```yaml
all:
  children:
    cloud_compose:
      hosts:
        isle.example.edu:
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
```

Run:

```bash
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/site.yml
```
