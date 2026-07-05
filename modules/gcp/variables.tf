variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "project_number" {
  type        = string
  description = "The GCP project number"
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-east5"
}

variable "zone" {
  description = "GCP zone for resources"
  type        = string
  default     = "us-east5-b"
}

variable "name" {
  type        = string
  description = "The site name (will be the name of the GCP instance)"
}

variable "service_account_email" {
  description = "Existing service account email for the VM. When empty, this module creates one."
  type        = string
  default     = ""
}

variable "app_service_account_email" {
  description = "Existing service account email for the compose app identity. When empty, this module creates one. On GCP this identity is used for app-scoped credentials such as Vault GCP IAM auth."
  type        = string
  default     = ""
}

variable "disk_type" {
  type        = string
  description = "The disk type for disks attached to the machine"
  default     = "hyperdisk-balanced"
  validation {
    condition = contains([
      "hyperdisk-balanced",
      "pd-ssd",
      "pd-standard",
    ], var.disk_type)
    error_message = "Invalid 'disk_type'"
  }
}

variable "machine_type" {
  type        = string
  default     = "n4-standard-2"
  description = "VM machine type (General-purpose series that support Hyperdisk Balanced"

  validation {
    condition = contains([
      "e2-micro",
      "e2-small",
      "e2-medium",
      "n4-standard-2",
      "n4-standard-4",
      "n4-standard-8",
      "n4-standard-16",
      "n4-standard-32",
      "n4-standard-48",
      "n4-standard-64",
      "n4-standard-80",
      "c4-standard-2",
      "c4-standard-4",
      "c4-standard-8",
      "c4-standard-16",
      "c4-standard-32",
      "c4-standard-48",
      "c4-standard-96",
    ], var.machine_type)
    error_message = "The 'machine_type' must be from a General-Purpose family that supports Hyperdisk Balanced (C4, or N4 series)"
  }
}

variable "ingress_port" {
  type        = number
  default     = 80
  description = "TCP port on the VM that the Cloud Run ingress should connect to."
}

variable "primary_compose_project" {
  type        = string
  default     = ""
  description = "Key from compose_projects used as the default ingress and rollout target. Defaults to the first compose_projects key, or var.name for single-app deployments."
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

variable "disk_size_gb" {
  type        = number
  default     = 50
  description = "Data disk size in GB"
}

variable "os" {
  type        = string
  default     = "cos-125-19216-220-185"
  description = "The host OS to install on the GCP instance"
}

variable "docker_compose_repo" {
  type        = string
  default     = ""
  description = "git repo to checkout that contains a docker compose project"
}

variable "compose_projects" {
  description = <<-EOT
    Compose apps to run on this VM. Leave empty to use the legacy single-app
    docker_compose_* inputs. Each app gets its own sitectl context, git checkout,
    compose project name, lifecycle scripts, and optional ingress port so multiple
    compose projects can share one VM.
  EOT
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

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "git branch to checkout for var.docker_compose_repo"
}

variable "docker_compose_init" {
  type = list(string)
  default = [
    "sitectl config set-context \"$${SITECTL_CONTEXT_NAME}\" --type local --project-dir \"$${DOCKER_COMPOSE_DIR}\" --site \"$${CLOUD_COMPOSE_INSTANCE_NAME}\" --plugin \"$${SITECTL_PLUGIN}\" --environment \"$${SITECTL_ENVIRONMENT}\" --project-name \"$${CLOUD_COMPOSE_INSTANCE_NAME}\" --compose-project-name \"$${COMPOSE_PROJECT_NAME}\" --docker-socket /var/run/docker.sock --env-file .env --default"
  ]
  description = "After cloning the docker compose git repo, any initialization that needs to happen before the docker compose project can start. One command per list value"
}

variable "docker_compose_up" {
  type = list(string)
  default = [
    "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" up -d --remove-orphans",
    "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\"",
    "if [ \"$${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"$${SITECTL_CONTEXT_NAME}\" $${SITECTL_VERIFY_ARGS:-}; fi"
  ]
  description = "Command to start the docker compose project"
}

variable "docker_compose_down" {
  type = list(string)
  default = [
    "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" down"
  ]
  description = "Command to stop the docker compose project"
}

variable "docker_compose_rollout" {
  type = list(string)
  default = [
    "TARGET_REF=\"$${GIT_REF:-$${GIT_BRANCH:-$${DOCKER_COMPOSE_BRANCH:-main}}}\"",
    "if [ -x ./scripts/rollout.sh ]; then ./scripts/rollout.sh; else sitectl deploy --context \"$${SITECTL_CONTEXT_NAME}\" --branch \"$TARGET_REF\"; fi",
    "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\"",
    "if [ \"$${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"$${SITECTL_CONTEXT_NAME}\" $${SITECTL_VERIFY_ARGS:-}; fi"
  ]
  description = "Command to roll out a new git ref for the docker compose project. The optional rollout service sets GIT_REF/GIT_BRANCH from the trigger request."
}

variable "sitectl_packages" {
  type        = list(string)
  default     = ["sitectl"]
  description = "LibOps GitHub release package names to install and keep updated on the VM. Include plugin packages such as sitectl-isle or sitectl-wp as needed."

  validation {
    condition = alltrue([
      for package in var.sitectl_packages :
      can(regex("^sitectl(-[a-z0-9]+)*$", package))
    ])
    error_message = "sitectl_packages entries must be release package names such as sitectl, sitectl-isle, or sitectl-wp."
  }
}

variable "sitectl_version" {
  type        = string
  default     = "latest"
  description = "Sitectl release tag to install for sitectl packages, or latest to follow https://github.com/libops/sitectl/releases/latest."

  validation {
    condition     = var.sitectl_version == "latest" || can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+", var.sitectl_version))
    error_message = "sitectl_version must be latest or a release tag such as v0.19.7."
  }
}

variable "docker_compose_version" {
  type = string
  # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
  default     = "v5.2.0"
  description = "Docker Compose release tag installed as the docker compose CLI plugin on hosts that need a manually managed plugin."
}

variable "docker_buildx_version" {
  type = string
  # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
  default     = "v0.35.0"
  description = "Docker Buildx release tag installed as the docker buildx CLI plugin on hosts that need a manually managed plugin."
}

variable "sitectl_context_name" {
  type        = string
  default     = ""
  description = "Sitectl context name to create on the VM. Defaults to var.name."
}

variable "sitectl_plugin" {
  type        = string
  default     = "core"
  description = "Sitectl plugin id to associate with the VM context."
}

variable "sitectl_environment" {
  type        = string
  default     = "production"
  description = "Sitectl environment label. Production runs healthcheck only by default; non-production also runs sitectl verify."
}

variable "production" {
  type        = bool
  default     = false
  description = "Whether this VM is the production environment. Production VMs reserve one matching machine so stop/start and recreate operations keep capacity."
}

variable "sitectl_healthcheck_timeout" {
  type        = string
  default     = "10m"
  description = "Timeout passed to sitectl healthcheck --timeout in default lifecycle commands."
}

variable "sitectl_healthcheck_interval" {
  type        = string
  default     = "15s"
  description = "Interval passed to sitectl healthcheck --interval in default lifecycle commands."
}

variable "sitectl_verify_args" {
  type        = list(string)
  default     = []
  description = "Additional arguments appended to sitectl verify by the default non-production lifecycle commands."
}

variable "libops_managed_runtime_enabled" {
  type        = bool
  default     = true
  description = "Install and periodically update LibOps-managed host tools and internal VM services."
}

variable "libops_internal_services_auto_update" {
  type        = bool
  default     = true
  description = "Whether the managed runtime updater should pull and restart the internal LibOps compose project."
}

variable "libops_internal_services_enabled" {
  type        = bool
  default     = true
  description = "Whether to start the internal LibOps services timer. GCP deployments usually keep this enabled; non-GCP modules disable it by default."
}

variable "power_management_enabled" {
  type        = bool
  default     = true
  description = "Enable GCP power-management support services such as lightsout and Cloud Run proxy-power-button. Disable for providers that do not save cost when VMs are stopped."
}

variable "libops_lightsout_image" {
  type        = string
  default     = "ghcr.io/libops/lightsout:main"
  description = "Container image used for the internal lightsout service."
}

variable "libops_cap_image" {
  type        = string
  default     = "ghcr.io/libops/cap:main"
  description = "Container image used for the internal CAP metrics service."
}

variable "libops_cadvisor_image" {
  type        = string
  default     = "ghcr.io/google/cadvisor:v0.57.0@sha256:e75bdb03b74b0b6995f208f166fead2e6e555dde73e44200113bb26f41b1981d"
  description = "Container image used for the internal cAdvisor service."
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
  description = "Additional LibOps-managed files or binaries to download, verify, install, and optionally restart with the managed runtime updater."

  validation {
    condition = alltrue([
      for artifact in var.libops_managed_artifacts :
      !can(regex("[\t\r\n]", artifact.name)) &&
      !can(regex("[\t\r\n]", artifact.url)) &&
      !can(regex("[\t\r\n]", artifact.sha256)) &&
      !can(regex("[\t\r\n]", artifact.path)) &&
      can(regex("^[0-9a-f]{64}$", artifact.sha256))
    ])
    error_message = "libops_managed_artifacts values must not contain tabs or newlines, and sha256 must be a lowercase SHA256 hex digest."
  }
}

variable "allowed_ips" {
  type        = list(string)
  default     = []
  description = "CIDR IP Addresses allowed to turn on this site's GCP instance"
}

variable "allowed_ssh_ipv4" {
  type        = list(string)
  default     = []
  description = "CIDR IPv4 Addresses allowed to to SSH into this site's GCP instance"
}

variable "allowed_ssh_ipv6" {
  type        = list(string)
  default     = []
  description = "CIDR IPv6 Addresses allowed to SSH into this site's GCP instance"
}

variable "network_name" {
  type        = string
  default     = ""
  description = "Existing VPC network name or self link for the VM and firewall rules. When empty and create_network is true, this module creates a per-deployment network."
}

variable "subnetwork_name" {
  type        = string
  default     = ""
  description = "Existing regional subnetwork name or self link for the VM. When empty and create_network is true, this module creates a per-deployment subnetwork."
}

variable "create_network" {
  type        = bool
  default     = true
  description = "Create a per-deployment VPC network and regional subnetwork when network_name and subnetwork_name are empty."
}

variable "network_ip_cidr_range" {
  type        = string
  default     = "10.42.0.0/24"
  description = "CIDR range used for the managed GCP subnetwork when create_network is true."

  validation {
    condition     = can(cidrhost(var.network_ip_cidr_range, 1))
    error_message = "network_ip_cidr_range must be a valid CIDR range."
  }
}

variable "run_snapshots" {
  type        = bool
  default     = false
  description = "Enable daily snapshots of the data disk (recommended for production). Last seven days of snapshots are available. Also weekly snapshots for past year."
}

variable "overlay_source_instance" {
  type        = string
  default     = ""
  description = "Name of production instance to get latest snapshot from (e.g., 'ojs-production'). Terraform will automatically use the most recent snapshot from this instance's data disk. Leave empty for production environments."
}

variable "volume_names" {
  type        = list(string)
  default     = []
  description = "List of docker volumes to overlay from production snapshot (e.g., ['compose_ojs-public']). Production data is mounted read-only as lower layer, staging writes go to upper layer."
}

variable "users" {
  type        = map(list(string))
  default     = {}
  description = "Map of usernames to lists of SSH public keys. Users will be created with docker group membership. Example: { \"alice\" = [\"ssh-rsa AAAA...\"], \"bob\" = [\"ssh-ed25519 AAAA...\", \"ssh-rsa BBBB...\"] }"
}

variable "rootfs" {
  type        = string
  default     = ""
  description = "Path to additional rootfs files to copy into the VM. Files will be merged with the base rootfs. Example: '/path/to/custom/rootfs'"
}

variable "runcmd" {
  type        = list(string)
  default     = []
  description = "Additional commands to run during cloud-init. Commands are executed after the main initialization."
}

variable "initcmd" {
  type        = list(string)
  default     = []
  description = "Commands to run before /home/cloud-compose/run.sh"
}

variable "artifact_registry_repository" {
  type        = string
  default     = ""
  description = "Optional Artifact Registry repository name to grant the VM service account reader access to. Leave empty to skip creating the IAM binding."
}

variable "artifact_registry_location" {
  type        = string
  default     = "us"
  description = "Artifact Registry location for var.artifact_registry_repository."
}

variable "frontend" {
  description = <<-EOT
    Optional frontend container to deploy as a sidecar next to ppb. When set,
    ppb continues to power on and ping the VM referenced by machineMetadata,
    but proxies incoming requests to this container on localhost instead of
    to the VM. Use this to serve a frontend from Cloud Run while keeping
    backend services on the VM.
  EOT
  type = object({
    image  = string
    port   = optional(number, 8080)
    cpu    = optional(string, "1000m")
    memory = optional(string, "1Gi")
  })
  default = null
}

variable "rollout_enabled" {
  description = "Install and run the optional generic rollout HTTP service on the VM."
  type        = bool
  default     = false
}

variable "rollout_release_url" {
  description = "HTTPS URL for the pinned rollout Linux binary."
  type        = string
  default     = ""
}

variable "rollout_release_sha256" {
  description = "Lowercase SHA256 checksum for var.rollout_release_url."
  type        = string
  default     = ""
  validation {
    condition     = var.rollout_release_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.rollout_release_sha256))
    error_message = "rollout_release_sha256 must be empty or a lowercase SHA256 hex digest."
  }
}

variable "rollout_port" {
  description = "TCP port exposed by the optional rollout service."
  type        = number
  default     = 8081
  validation {
    condition     = var.rollout_port > 0 && var.rollout_port <= 65535
    error_message = "rollout_port must be between 1 and 65535."
  }
}

variable "rollout_jwks_uri" {
  description = "JWKS URI used by the rollout service to validate bearer JWTs."
  type        = string
  default     = ""
}

variable "rollout_jwt_audience" {
  description = "JWT audience required by the rollout service."
  type        = string
  default     = ""
}

variable "rollout_custom_claims" {
  description = "Optional JSON object of additional JWT claims required by the rollout service."
  type        = string
  default     = ""
}

variable "rollout_allowed_ipv4" {
  description = "CIDR IPv4 ranges allowed to reach the rollout service port."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "vault_addr" {
  description = "Vault address exposed to the VM and app contexts. Empty disables the default Vault Agent contract."
  type        = string
  default     = ""
}

variable "vault_namespace" {
  description = "Optional Vault namespace for Enterprise Vault deployments."
  type        = string
  default     = ""
}

variable "vault_role" {
  description = "Vault auth role for the app workload identity."
  type        = string
  default     = ""
}

variable "vault_agent_enabled" {
  description = "Write Vault Agent configuration and start vault-agent.service when Vault is configured."
  type        = bool
  default     = false
}

variable "vault_auth_method" {
  description = "Vault Agent auth method contract. gcp-iam uses the app GSA identity. consumer-managed writes env/config scaffolding only."
  type        = string
  default     = "gcp-iam"

  validation {
    condition     = contains(["gcp-iam", "consumer-managed"], var.vault_auth_method)
    error_message = "vault_auth_method must be gcp-iam or consumer-managed."
  }
}

variable "vault_gcp_auth_mount_path" {
  description = "Vault GCP auth mount path used by Vault Agent for gcp-iam auth."
  type        = string
  default     = "auth/gcp"
}

variable "vault_agent_token_path" {
  description = "Path where Vault Agent writes its auto-auth token sink."
  type        = string
  default     = "/mnt/disks/data/vault/token"
}

variable "vault_agent_templates" {
  description = "Vault Agent template stanzas. Contents should use Vault template syntax and should not contain secret values in Terraform."
  type = list(object({
    destination = string
    contents    = string
    perms       = optional(string, "0640")
    command     = optional(string, "")
  }))
  default = []
}

variable "vault_agent_additional_config" {
  description = "Additional Vault Agent HCL appended to the generated config. Use for consumer-managed auth on non-GCP providers."
  type        = string
  default     = ""
}
