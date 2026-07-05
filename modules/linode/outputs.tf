output "instance" {
  value = {
    id          = linode_instance.cloud_compose.id
    label       = linode_instance.cloud_compose.label
    region      = linode_instance.cloud_compose.region
    public_ipv4 = one(setsubtract(linode_instance.cloud_compose.ipv4, [linode_instance.cloud_compose.private_ip_address]))
    ipv4        = linode_instance.cloud_compose.ipv4
    private_ip  = linode_instance.cloud_compose.private_ip_address
    ipv6        = linode_instance.cloud_compose.ipv6
  }
  description = "Linode instance details."
}

output "volumes" {
  value = {
    data = {
      id              = linode_volume.data.id
      label           = linode_volume.data.label
      filesystem_path = linode_volume.data.filesystem_path
    }
    docker_volumes = {
      id              = linode_volume.docker_volumes.id
      label           = linode_volume.docker_volumes.label
      filesystem_path = linode_volume.docker_volumes.filesystem_path
    }
  }
  description = "Persistent Linode volumes."
}

output "compose_projects" {
  value       = module.runtime.compose_projects
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value       = module.runtime.primary_compose_project
  description = "Normalized primary compose project."
}
