output "instance" {
  value = {
    id         = digitalocean_droplet.cloud_compose.id
    urn        = digitalocean_droplet.cloud_compose.urn
    name       = digitalocean_droplet.cloud_compose.name
    region     = digitalocean_droplet.cloud_compose.region
    ipv4       = digitalocean_droplet.cloud_compose.ipv4_address
    private_ip = digitalocean_droplet.cloud_compose.ipv4_address_private
    ipv6       = digitalocean_droplet.cloud_compose.ipv6_address
  }
  description = "DigitalOcean Droplet details."
}

output "volumes" {
  value = {
    data = {
      id   = digitalocean_volume.data.id
      name = digitalocean_volume.data.name
    }
    docker_volumes = {
      id   = digitalocean_volume.docker_volumes.id
      name = digitalocean_volume.docker_volumes.name
    }
  }
  description = "Persistent DigitalOcean volumes."
}

output "compose_projects" {
  value       = module.runtime.compose_projects
  description = "Normalized compose project manifest."
}

output "primary_compose_project" {
  value       = module.runtime.primary_compose_project
  description = "Normalized primary compose project."
}
