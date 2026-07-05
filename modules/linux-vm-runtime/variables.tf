variable "name" {
  type        = string
  description = "Deployment name used for the VM and default compose project."
}

variable "provider_name" {
  type        = string
  description = "Cloud provider identifier written to CLOUD_COMPOSE_PROVIDER."
}

variable "region" {
  type        = string
  description = "Provider region."
}

variable "zone" {
  type        = string
  default     = ""
  description = "Provider zone or region-local placement label."
}

variable "data_device" {
  type        = string
  description = "Stable device path for the persistent data disk."
}

variable "volumes_device" {
  type        = string
  description = "Stable device path for the persistent Docker volumes disk."
}

variable "ssh_users" {
  type        = map(list(string))
  default     = {}
  description = "Additional Linux users and authorized SSH keys to create through cloud-init."
}

variable "cloud_compose_ssh_keys" {
  type        = list(string)
  default     = []
  description = "Authorized SSH keys for the cloud-compose Linux user."
}

variable "rootfs" {
  type        = string
  default     = ""
  description = "Optional rootfs overlay. Files here override the packaged cloud-compose rootfs by relative path."
}

variable "rootfs_archive_url" {
  type        = string
  default     = ""
  description = "Optional tar.gz URL containing a rootfs directory to fetch during boot instead of embedding the packaged rootfs in cloud-init."
}

variable "rootfs_archive_sha256" {
  type        = string
  default     = ""
  description = "Optional SHA-256 checksum for rootfs_archive_url."
}

variable "ingress_port" {
  type        = number
  default     = 80
  description = "Default TCP port exposed by a compose project on the VM."
}

variable "primary_compose_project" {
  type        = string
  default     = ""
  description = "Key from compose_projects used as the default target. Defaults to the first compose_projects key, or var.name for single-app deployments."
}

variable "sitectl_ingress" {
  type = object({
    letsencrypt     = optional(bool, false)
    bot_mitigation  = optional(bool, false)
    mode            = optional(string, "")
    domain          = optional(string, "")
    acme_email      = optional(string, "")
    trusted_ips     = optional(list(string), [])
    max_upload_size = optional(string, "")
    upload_timeout  = optional(string, "")
  })
  default     = {}
  description = "Default sitectl ingress component settings applied during init. Per-app compose_projects entries can override these values."
}

variable "docker_compose_repo" {
  type        = string
  default     = ""
  description = "Legacy single-app git repo containing a Docker Compose project."
}

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "Default git branch for compose repositories."
}

variable "compose_projects" {
  description = "Compose apps to run on this VM."
  type = map(object({
    docker_compose_repo   = string
    docker_compose_branch = optional(string)
    project_dir           = optional(string)
    compose_project_name  = optional(string)
    ingress_port          = optional(number)
    ingress = optional(object({
      letsencrypt     = optional(bool)
      bot_mitigation  = optional(bool)
      mode            = optional(string)
      domain          = optional(string)
      acme_email      = optional(string)
      trusted_ips     = optional(list(string))
      max_upload_size = optional(string)
      upload_timeout  = optional(string)
    }), {})
    sitectl_context_name   = optional(string)
    sitectl_plugin         = optional(string)
    sitectl_environment    = optional(string)
    sitectl_packages       = optional(list(string), [])
    sitectl_verify_args    = optional(list(string), [])
    docker_compose_init    = optional(list(string))
    docker_compose_up      = optional(list(string))
    docker_compose_down    = optional(list(string))
    docker_compose_rollout = optional(list(string))
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, app in var.compose_projects :
      can(regex("^[a-z][a-z0-9-]*$", name)) &&
      trimspace(app.docker_compose_repo) != "" &&
      try(app.ingress_port, 80) > 0 &&
      try(app.ingress_port, 80) <= 65535
    ])
    error_message = "compose_projects keys must match ^[a-z][a-z0-9-]*$, docker_compose_repo is required, and ingress_port must be between 1 and 65535."
  }
}

variable "docker_compose_init" {
  type = list(string)
  default = [
    "sitectl config set-context \"$${SITECTL_CONTEXT_NAME}\" --type local --project-dir \"$${DOCKER_COMPOSE_DIR}\" --site \"$${CLOUD_COMPOSE_INSTANCE_NAME}\" --plugin \"$${SITECTL_PLUGIN}\" --environment \"$${SITECTL_ENVIRONMENT}\" --project-name \"$${CLOUD_COMPOSE_INSTANCE_NAME}\" --compose-project-name \"$${COMPOSE_PROJECT_NAME}\" --docker-socket /var/run/docker.sock --env-file .env --default"
  ]
  description = "Commands run after a compose repository is cloned."
}

variable "docker_compose_up" {
  type = list(string)
  default = [
    "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" up -d --remove-orphans",
    "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\"",
    "if [ \"$${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"$${SITECTL_CONTEXT_NAME}\" $${SITECTL_VERIFY_ARGS:-}; fi"
  ]
  description = "Commands used to bring a compose project up."
}

variable "docker_compose_down" {
  type = list(string)
  default = [
    "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" down"
  ]
  description = "Commands used to stop a compose project."
}

variable "docker_compose_rollout" {
  type = list(string)
  default = [
    "sitectl deploy --context \"$${SITECTL_CONTEXT_NAME}\" --skip-git",
    "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\""
  ]
  description = "Commands used by rollout triggers."
}

variable "sitectl_packages" {
  type        = list(string)
  default     = ["sitectl"]
  description = "sitectl release packages to install."
}

variable "sitectl_version" {
  type        = string
  default     = "latest"
  description = "sitectl release tag to install, or latest."
}

variable "sitectl_context_name" {
  type        = string
  default     = ""
  description = "Legacy single-app sitectl context name. Defaults to var.name."
}

variable "sitectl_plugin" {
  type        = string
  default     = "core"
  description = "Default sitectl plugin id."
}

variable "sitectl_environment" {
  type        = string
  default     = "production"
  description = "Default sitectl environment label."
}

variable "sitectl_healthcheck_timeout" {
  type        = string
  default     = "10m"
  description = "Timeout passed to sitectl healthcheck."
}

variable "sitectl_healthcheck_interval" {
  type        = string
  default     = "15s"
  description = "Interval passed to sitectl healthcheck."
}

variable "sitectl_verify_args" {
  type        = list(string)
  default     = []
  description = "Additional arguments appended to sitectl verify."
}

variable "docker_compose_version" {
  type = string
  # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
  default     = "v5.2.0"
  description = "Docker Compose release tag installed as the Docker CLI plugin."
}

variable "docker_buildx_version" {
  type = string
  # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
  default     = "v0.35.0"
  description = "Docker Buildx release tag installed as the Docker CLI plugin."
}

variable "libops_managed_runtime_enabled" {
  type        = bool
  default     = true
  description = "Install and periodically update sitectl packages and managed artifacts."
}

variable "libops_internal_services_enabled" {
  type        = bool
  default     = false
  description = "Start internal LibOps metrics and power services."
}

variable "libops_internal_services_auto_update" {
  type        = bool
  default     = false
  description = "Allow the managed runtime to update internal LibOps services."
}

variable "libops_managed_artifacts" {
  type = list(object({
    name    = string
    url     = string
    sha256  = string
    path    = string
    mode    = optional(string, "0755")
    owner   = optional(string, "root")
    group   = optional(string, "root")
    restart = optional(string, "")
  }))
  default     = []
  description = "Extra host artifacts installed by the managed runtime."
}

variable "vault_addr" {
  type        = string
  default     = ""
  description = "Vault server address."
}

variable "vault_namespace" {
  type        = string
  default     = ""
  description = "Vault namespace."
}

variable "vault_role" {
  type        = string
  default     = ""
  description = "Vault auth role."
}

variable "vault_agent_enabled" {
  type        = bool
  default     = false
  description = "Write Vault Agent configuration and start vault-agent.service when Vault is configured."
}

variable "vault_auth_method" {
  type        = string
  default     = "consumer-managed"
  description = "Vault Agent auth method contract. Non-GCP providers default to consumer-managed."

  validation {
    condition     = contains(["gcp-iam", "consumer-managed"], var.vault_auth_method)
    error_message = "vault_auth_method must be gcp-iam or consumer-managed."
  }
}

variable "vault_gcp_auth_mount_path" {
  type        = string
  default     = "auth/gcp"
  description = "Vault GCP auth mount path used by Vault Agent for gcp-iam auth."
}

variable "vault_agent_token_path" {
  type        = string
  default     = "/mnt/disks/data/vault/token"
  description = "Path where Vault Agent writes its token sink."
}

variable "vault_agent_templates" {
  type = list(object({
    destination = string
    contents    = string
    perms       = optional(string, "0640")
    command     = optional(string, "")
  }))
  default     = []
  description = "Vault Agent template stanzas."
}

variable "vault_agent_additional_config" {
  type        = string
  default     = ""
  description = "Additional Vault Agent HCL appended to the generated config."
}

variable "extra_env" {
  type        = map(string)
  default     = {}
  description = "Additional shell environment variables written to /home/cloud-compose/.env."
}
