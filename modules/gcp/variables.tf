variable "project_id" {
  description = "The GCP project ID"
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid lowercase GCP project ID (legacy domain-scoped prefixes are accepted)."
  }
}

variable "project_number" {
  type        = string
  default     = ""
  description = "Deprecated optional project-number assertion. The module derives the authoritative number from project_id and rejects a mismatched non-empty value."

  validation {
    condition     = var.project_number == "" || can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be empty or contain only decimal digits."
  }
}

variable "power_start_role" {
  type        = string
  default     = ""
  description = "Full project- or organization-custom-role name granting compute.instances.get, start, and resume. Required when power management is enabled; create it in the singleton GCP foundation module."

  validation {
    condition = var.power_start_role == "" || can(regex(
      "^(projects/([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]|organizations/[0-9]+)/roles/[A-Za-z0-9_.]+$",
      var.power_start_role,
    ))
    error_message = "power_start_role must be empty or a full projects/.../roles/... or organizations/.../roles/... custom-role name."
  }
}

variable "power_suspend_role" {
  type        = string
  default     = ""
  description = "Full project- or organization-custom-role name granting compute.instances.get and suspend. Required when power management is enabled; create it in the singleton GCP foundation module."

  validation {
    condition = var.power_suspend_role == "" || can(regex(
      "^(projects/([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]|organizations/[0-9]+)/roles/[A-Za-z0-9_.]+$",
      var.power_suspend_role,
    ))
    error_message = "power_suspend_role must be empty or a full projects/.../roles/... or organizations/.../roles/... custom-role name."
  }
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

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,19}[a-z0-9]$", var.name))
    error_message = "name must be 6 through 21 lowercase letters, numbers, or hyphens; it must start with a letter and end with a letter or number so every generated GCP service-account ID is valid."
  }
}

variable "service_account_email" {
  description = "Existing same-project service account email dedicated to this application state for the VM. When empty, this module creates one. Reuse across application states and cross-project attachment are not supported."
  type        = string
  default     = ""

  validation {
    condition     = var.service_account_email == "" || can(regex("^[a-z0-9-]+@[a-z0-9.-]+\\.iam\\.gserviceaccount\\.com$", var.service_account_email))
    error_message = "service_account_email must be empty or a valid Google service-account email."
  }
}

variable "app_service_account_email" {
  description = "Existing same-project service account email dedicated to this application state for the compose app identity. When empty, this module creates one. Reuse across application states is not supported. On GCP this identity is used for optional app-scoped credentials and managed Vault GCP IAM auth."
  type        = string
  default     = ""

  validation {
    condition     = var.app_service_account_email == "" || can(regex("^[a-z0-9-]+@[a-z0-9.-]+\\.iam\\.gserviceaccount\\.com$", var.app_service_account_email))
    error_message = "app_service_account_email must be empty or a valid Google service-account email."
  }
}

variable "app_credentials_enabled" {
  description = "Create and rotate a user-managed JSON key for the app service account. Leave false unless an application explicitly requires a file credential; managed Vault Agent GCP IAM auth uses VM attached identity and does not require this."
  type        = bool
  default     = false
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
  description = "Reviewed general-purpose VM machine type."

  validation {
    condition = contains([
      "e2-micro",
      "e2-small",
      "e2-medium",
      "n2d-standard-2",
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
    error_message = "machine_type must be an explicitly reviewed general-purpose profile."
  }
}

variable "ingress_port" {
  type        = number
  default     = 80
  description = "TCP port on the VM that the Cloud Run ingress should connect to."

  validation {
    condition     = var.ingress_port >= 1 && var.ingress_port <= 65535 && floor(var.ingress_port) == var.ingress_port
    error_message = "ingress_port must be a whole number between 1 and 65535."
  }
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
  description = "Docker-volume disk size in GB"
}

variable "data_disk_size_gb" {
  type        = number
  default     = 20
  description = "Application-data disk size in GB. Size this independently for checkouts, configuration, credentials, tools, and caller-managed data such as logical backups. Terraform can grow the block device in place; the mounted ext4 filesystem grows when cloud-init reruns filesystem preparation on the next controlled boot. Existing disks cannot shrink."

  validation {
    condition     = var.data_disk_size_gb >= 10 && floor(var.data_disk_size_gb) == var.data_disk_size_gb
    error_message = "data_disk_size_gb must be a whole number of at least 10 GB."
  }
}

variable "os" {
  type        = string
  default     = "cos-125-19216-220-185"
  description = "Reviewed Container-Optimized OS image name. Renovate cannot discover GCP image-family members; update this pin manually from the COS release notes."
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
    sitectl_packages       = optional(list(string))
    sitectl_verify_args    = optional(list(string))
    docker_compose_init    = optional(list(string))
    docker_compose_up      = optional(list(string))
    docker_compose_down    = optional(list(string))
    docker_compose_rollout = optional(list(string))
  }))
  default = {}

  validation {
    condition = length(distinct([
      for _, app in var.compose_projects : coalesce(try(app.ingress_port, null), var.ingress_port)
      ])) == length(var.compose_projects) && alltrue([
      for name, app in var.compose_projects :
      can(regex("^[a-z][a-z0-9-]*$", name)) &&
      trimspace(app.docker_compose_repo) != "" &&
      coalesce(try(app.ingress_port, null), var.ingress_port) >= 1 &&
      coalesce(try(app.ingress_port, null), var.ingress_port) <= 65535 &&
      floor(coalesce(try(app.ingress_port, null), var.ingress_port)) == coalesce(try(app.ingress_port, null), var.ingress_port)
    ])
    error_message = "compose_projects keys must match ^[a-z][a-z0-9-]*$, docker_compose_repo is required, and every app must use a unique whole-number ingress_port between 1 and 65535."
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
    "sitectl config set-context \"$${SITECTL_CONTEXT_NAME}\" --type local --project-dir \"$${DOCKER_COMPOSE_DIR}\" --site \"$${CLOUD_COMPOSE_INSTANCE_NAME}\" --plugin \"$${SITECTL_PLUGIN}\" --environment \"$${SITECTL_ENVIRONMENT}\" --compose-project-name \"$${COMPOSE_PROJECT_NAME}\" --docker-socket /var/run/docker.sock --env-file .env --yolo --default"
  ]
  nullable    = false
  description = "After cloning the docker compose git repo, any initialization that needs to happen before the docker compose project can start. One command per list value"
}

variable "docker_compose_up" {
  type = list(string)
  default = [
    "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" up -d --remove-orphans",
    "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist",
    "if [ \"$${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"$${SITECTL_CONTEXT_NAME}\" $${SITECTL_VERIFY_ARGS:-}; fi"
  ]
  nullable    = false
  description = "Command to start the docker compose project"
}

variable "docker_compose_down" {
  type = list(string)
  default = [
    "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" down"
  ]
  nullable    = false
  description = "Command to stop the docker compose project"
}

variable "docker_compose_rollout" {
  type = list(string)
  default = [
    "TARGET_REF=\"$${GIT_REF:-$${GIT_BRANCH:-}}\"",
    "if [ -n \"$TARGET_REF\" ]; then sitectl deploy --context \"$${SITECTL_CONTEXT_NAME}\" --ref \"$TARGET_REF\"; else sitectl deploy --context \"$${SITECTL_CONTEXT_NAME}\" --skip-git; fi",
    "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist",
    "if [ \"$${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"$${SITECTL_CONTEXT_NAME}\" $${SITECTL_VERIFY_ARGS:-}; fi"
  ]
  nullable    = false
  description = "Commands used by rollout triggers. GIT_REF/GIT_BRANCH selects a source ref; without one, sitectl reconciles the current checkout."
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
  description = "Legacy fallback sitectl release tag for packages without a package-specific override."

  validation {
    condition = (
      var.sitectl_version == "latest" ||
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", var.sitectl_version))
    )
    error_message = "sitectl_version must be latest or an exact semantic-version release tag such as v0.38.0."
  }
}

variable "sitectl_package_versions" {
  type        = map(string)
  default     = {}
  description = "Per-package release tags that override sitectl_version."

  validation {
    condition = alltrue([
      for package, version in var.sitectl_package_versions :
      can(regex("^sitectl(-[a-z0-9]+)*$", package)) && (
        version == "latest" ||
        can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", version))
      )
    ])
    error_message = "sitectl_package_versions keys must be sitectl package names and values must be latest or exact semantic-version release tags."
  }
}

variable "docker_compose_version" {
  type = string
  # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
  default     = "v5.3.1"
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
  default     = false
  description = "Whether the managed runtime updater should pull and restart the internal LibOps compose project."
}

variable "libops_internal_services_enabled" {
  type        = bool
  default     = false
  description = "Whether to start the privileged internal LibOps services. Enable explicitly only when the Docker socket and host-observability access are accepted."
}

variable "power_management_enabled" {
  type        = bool
  default     = false
  description = "Enable GCP power-management support services such as lightsout and Cloud Run proxy-power-button. This explicitly enables the privileged internal-services runtime required by lightsout."
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
  description = "Original-client CIDRs allowed to turn on this site's GCP instance after the configured trusted X-Forwarded-For suffix is removed. Required when power management is enabled."

  validation {
    condition     = alltrue([for cidr in var.allowed_ips : can(cidrhost(cidr, 0))])
    error_message = "allowed_ips entries must be valid IPv4 or IPv6 CIDR ranges."
  }
}

variable "allowed_ip_forwarded_depth" {
  type        = number
  default     = null
  nullable    = true
  description = "Explicit number of trusted proxy addresses after the original client in X-Forwarded-For. Direct public Cloud Run uses 0 because Google appends the original client as the rightmost value. Any additional proxy requires a separately verified larger value. Required when power management is enabled."

  validation {
    condition = var.allowed_ip_forwarded_depth == null ? true : (
      var.allowed_ip_forwarded_depth >= 0 &&
      var.allowed_ip_forwarded_depth <= 10 &&
      floor(var.allowed_ip_forwarded_depth) == var.allowed_ip_forwarded_depth
    )
    error_message = "allowed_ip_forwarded_depth must be null or a whole number from 0 through 10."
  }
}

variable "allowed_ssh_ipv4" {
  type        = list(string)
  default     = []
  description = "IPv4 CIDR ranges allowed to SSH into this site's GCP instance."

  validation {
    condition = alltrue([
      for cidr in var.allowed_ssh_ipv4 :
      can(cidrhost(cidr, 0)) && length(regexall(":", cidr)) == 0
    ])
    error_message = "allowed_ssh_ipv4 entries must be valid IPv4 CIDR ranges."
  }
}

variable "allowed_ssh_ipv6" {
  type        = list(string)
  default     = []
  description = "IPv6 CIDR ranges allowed to SSH into this site's GCP instance."

  validation {
    condition = alltrue([
      for cidr in var.allowed_ssh_ipv6 :
      can(cidrhost(cidr, 0)) && length(regexall(":", cidr)) > 0
    ])
    error_message = "allowed_ssh_ipv6 entries must be valid IPv6 CIDR ranges."
  }
}

variable "network_name" {
  type        = string
  default     = ""
  description = "Existing VPC network name or self link for the VM, Cloud Run Direct VPC egress, and firewall rules. When supplied without subnetwork_name, Cloud Run and the module select the same-named regional subnet."
}

variable "subnetwork_name" {
  type        = string
  default     = ""
  description = "Existing regional subnetwork name or self link for the VM and Cloud Run Direct VPC egress. When supplied without network_name, the module derives its parent network."
}

variable "network_project_id" {
  type        = string
  default     = ""
  description = "Project containing an existing network and subnetwork. Defaults to project_id. Set it for Shared VPC; the singleton GCP foundation owns Cloud Run subnet IAM, while this stack's Terraform caller must be able to inspect the network and manage its per-stack firewall rules."

  validation {
    condition     = var.network_project_id == "" || can(regex("^([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.network_project_id))
    error_message = "network_project_id must be empty or a valid lowercase GCP project ID."
  }
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
    condition     = can(cidrhost(var.network_ip_cidr_range, 1)) && length(regexall(":", var.network_ip_cidr_range)) == 0
    error_message = "network_ip_cidr_range must be a valid IPv4 CIDR range."
  }
}

variable "network_mtu" {
  type        = number
  default     = 1460
  description = "MTU for a managed network, or the caller-attested MTU of an existing/Shared VPC network. Cloud Run Direct VPC egress requires 1460."

  validation {
    condition     = var.network_mtu >= 1300 && var.network_mtu <= 8896 && floor(var.network_mtu) == var.network_mtu
    error_message = "network_mtu must be a whole number from 1300 through 8896."
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
  description = "Map of safe Linux usernames to lists of single-line SSH public keys. Example: { \"alice\" = [\"ssh-rsa AAAA...\"], \"bob\" = [\"ssh-ed25519 AAAA...\", \"ssh-rsa BBBB...\"] }"

  validation {
    condition = alltrue(concat(
      [for username in keys(var.users) : can(regex("^[a-z_][a-z0-9_-]{0,31}\\$?$", username))],
      flatten([
        for _, keys in var.users : [
          for key in keys : trimspace(key) != "" && !can(regex("[\\r\\n]", key))
        ]
      ]),
    ))
    error_message = "users names must be safe Linux usernames and SSH keys must be non-empty single-line values."
  }
}

variable "rootfs" {
  type        = string
  default     = ""
  description = "Path to additional rootfs files to copy into the VM. Files will be merged with the base rootfs. Example: '/path/to/custom/rootfs'"
}

variable "rootfs_archive_url" {
  type        = string
  default     = ""
  description = "Optional HTTPS tar.gz URL containing a rootfs directory to fetch during boot instead of embedding the packaged rootfs. Must be set with rootfs_archive_sha256."

  validation {
    condition = (
      trimspace(var.rootfs_archive_url) == "" ||
      can(regex("^https://[^[:space:]]+$", trimspace(var.rootfs_archive_url)))
    )
    error_message = "rootfs_archive_url must be empty or an HTTPS URL without whitespace."
  }
}

variable "rootfs_archive_sha256" {
  type        = string
  default     = ""
  description = "Required 64-character SHA-256 checksum when rootfs_archive_url is set."
}

variable "offhost_backup_required" {
  type        = bool
  default     = false
  description = "Require nightly encrypted off-host coverage and scheduled disposable restore proofs from an operator-owned driver. Same-disk MariaDB dumps are retained but are not disaster recovery."
}

variable "offhost_backup_driver_path" {
  type        = string
  default     = "/etc/cloud-compose/libexec/offhost-backup-driver"
  description = "Absolute path to the operator-supplied, root-owned provider-neutral DR driver. The driver owns its credentials; do not pass them through Terraform."

  validation {
    condition = (
      can(regex("^/[A-Za-z0-9._/+:-]+$", var.offhost_backup_driver_path)) &&
      !strcontains(var.offhost_backup_driver_path, "//") &&
      length(regexall("(^|/)\\.\\.?(/|$)", var.offhost_backup_driver_path)) == 0
    )
    error_message = "offhost_backup_driver_path must be a safe absolute path without whitespace or dot segments."
  }
}

variable "extra_env" {
  type        = map(string)
  default     = {}
  description = "Application-only Compose environment values written as JSON data and reconciled into every project .env."

  validation {
    condition = alltrue([
      for name in keys(var.extra_env) :
      can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name)) &&
      !contains(["HOME", "PATH"], name) &&
      alltrue([
        for prefix in [
          "CLOUD_COMPOSE_",
          "COMPOSE_",
          "DOCKER_",
          "SITECTL_",
          "LIBOPS_",
          "GCP_",
          "VAULT_",
          "ROLLOUT_",
          "POWER_MANAGEMENT_",
        ] : !startswith(name, prefix)
      ])
    ])
    error_message = "extra_env names must be valid environment names and must not override cloud-compose control-plane keys (HOME, PATH, or CLOUD_COMPOSE_/COMPOSE_/DOCKER_/SITECTL_/LIBOPS_/GCP_/VAULT_/ROLLOUT_/POWER_MANAGEMENT_ prefixes)."
  }
}

variable "runcmd" {
  type        = list(string)
  default     = []
  description = "Additional commands to run during cloud-init. Commands are executed after the main initialization."
}

variable "initcmd" {
  type        = list(string)
  default     = []
  description = "Commands to run before the root-owned Cloud Compose bootstrap entrypoint"
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

  validation {
    condition = var.frontend == null ? true : (
      var.frontend.port >= 1 &&
      var.frontend.port <= 65535 &&
      floor(var.frontend.port) == var.frontend.port
    )
    error_message = "frontend.port must be a whole number between 1 and 65535."
  }
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

  validation {
    condition     = var.rollout_release_url == "" || can(regex("^https://[^[:space:]]+$", var.rollout_release_url))
    error_message = "rollout_release_url must be empty or an HTTPS URL."
  }
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
    condition     = var.rollout_port >= 1 && var.rollout_port <= 65535 && floor(var.rollout_port) == var.rollout_port
    error_message = "rollout_port must be a whole number between 1 and 65535."
  }
}

variable "rollout_jwks_uri" {
  description = "JWKS URI used by the rollout service to validate bearer JWTs."
  type        = string
  default     = ""

  validation {
    condition     = var.rollout_jwks_uri == "" || can(regex("^https://[^[:space:]]+$", var.rollout_jwks_uri))
    error_message = "rollout_jwks_uri must be empty or an HTTPS URL."
  }
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

  validation {
    condition = (
      trimspace(var.rollout_custom_claims) == "" ||
      can(keys(jsondecode(var.rollout_custom_claims)))
    )
    error_message = "rollout_custom_claims must be empty or a JSON object."
  }
}

variable "rollout_allowed_ipv4" {
  description = "CIDR IPv4 ranges allowed to reach the rollout service port."
  type        = list(string)
  default     = ["10.0.0.0/8"]

  validation {
    condition = alltrue([
      for cidr in var.rollout_allowed_ipv4 :
      can(cidrhost(cidr, 0)) && length(regexall(":", cidr)) == 0
    ])
    error_message = "rollout_allowed_ipv4 entries must be valid IPv4 CIDR ranges."
  }
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
  description = "Write Vault Agent configuration and start cloud-compose-vault-agent.service when Vault is configured."
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
