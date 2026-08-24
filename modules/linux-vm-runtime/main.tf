locals {
  rootfs            = "${path.module}/../../rootfs"
  additional_rootfs = var.rootfs != "" ? var.rootfs : ""

  single_compose_project = {
    (var.name) = {
      docker_compose_repo    = var.docker_compose_repo
      docker_compose_branch  = var.docker_compose_branch
      project_dir            = null
      compose_project_name   = null
      ingress_port           = var.ingress_port
      ingress                = var.sitectl_ingress
      sitectl_context_name   = trimspace(var.sitectl_context_name) != "" ? trimspace(var.sitectl_context_name) : var.name
      sitectl_plugin         = var.sitectl_plugin
      sitectl_environment    = var.sitectl_environment
      sitectl_packages       = var.sitectl_packages
      sitectl_verify_args    = var.sitectl_verify_args
      docker_compose_init    = var.docker_compose_init
      docker_compose_up      = var.docker_compose_up
      docker_compose_down    = var.docker_compose_down
      docker_compose_rollout = var.docker_compose_rollout
    }
  }
  raw_compose_projects        = length(var.compose_projects) > 0 ? var.compose_projects : tomap(local.single_compose_project)
  primary_compose_project_key = trimspace(var.primary_compose_project) != "" ? trimspace(var.primary_compose_project) : keys(local.raw_compose_projects)[0]
  compose_projects = {
    for app_name, app in local.raw_compose_projects : app_name => {
      name                  = app_name
      docker_compose_repo   = trimspace(app.docker_compose_repo)
      docker_compose_branch = trimspace(coalesce(try(app.docker_compose_branch, null), var.docker_compose_branch))
      repo_path             = trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/")
      project_dir = (
        try(trimspace(app.project_dir), "") != ""
        ? try(trimspace(app.project_dir), "")
        : "/mnt/disks/data/${trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/")}/${app_name}"
      )
      compose_project_name = (
        try(trimspace(app.compose_project_name), "") != ""
        ? try(trimspace(app.compose_project_name), "")
        : replace(lower(replace(replace(format("%s-%s", trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/"), trimspace(coalesce(try(app.docker_compose_branch, null), var.docker_compose_branch))), ".git", ""), "/[^a-zA-Z0-9]/", "-")), "/-+/", "-")
      )
      ingress_port = coalesce(try(app.ingress_port, null), var.ingress_port)
      ingress = {
        letsencrypt     = coalesce(try(app.ingress.letsencrypt, null), var.sitectl_ingress.letsencrypt)
        bot_mitigation  = coalesce(try(app.ingress.bot_mitigation, null), var.sitectl_ingress.bot_mitigation)
        mode            = try(app.ingress.mode, null) != null ? trimspace(app.ingress.mode) : trimspace(var.sitectl_ingress.mode)
        domain          = try(app.ingress.domain, null) != null ? trimspace(app.ingress.domain) : trimspace(var.sitectl_ingress.domain)
        acme_email      = try(app.ingress.acme_email, null) != null ? trimspace(app.ingress.acme_email) : trimspace(var.sitectl_ingress.acme_email)
        trusted_ips     = try(app.ingress.trusted_ips, null) != null ? app.ingress.trusted_ips : var.sitectl_ingress.trusted_ips
        max_upload_size = try(app.ingress.max_upload_size, null) != null ? trimspace(app.ingress.max_upload_size) : trimspace(var.sitectl_ingress.max_upload_size)
        upload_timeout  = try(app.ingress.upload_timeout, null) != null ? trimspace(app.ingress.upload_timeout) : trimspace(var.sitectl_ingress.upload_timeout)
      }
      sitectl_context_name = (
        trimspace(app.sitectl_context_name != null ? app.sitectl_context_name : "") != ""
        ? trimspace(app.sitectl_context_name)
        : app_name
      )
      sitectl_plugin      = trimspace(coalesce(try(app.sitectl_plugin, null), var.sitectl_plugin))
      sitectl_environment = trimspace(coalesce(try(app.sitectl_environment, null), var.sitectl_environment))
      sitectl_packages = distinct(concat(
        ["sitectl"],
        coalesce(try(app.sitectl_packages, null), var.sitectl_packages),
      ))
      sitectl_verify_args = coalesce(try(app.sitectl_verify_args, null), var.sitectl_verify_args)
      init_commands       = try(app.docker_compose_init, null) != null ? app.docker_compose_init : var.docker_compose_init
      up_commands         = try(app.docker_compose_up, null) != null ? app.docker_compose_up : var.docker_compose_up
      down_commands       = try(app.docker_compose_down, null) != null ? app.docker_compose_down : var.docker_compose_down
      rollout_commands    = try(app.docker_compose_rollout, null) != null ? app.docker_compose_rollout : var.docker_compose_rollout
    }
  }
  validated_compose_projects = {
    for app_name, app in local.compose_projects : app_name => merge(app, {
      project_dir = module.project_directories.project_dirs[app_name]
    })
  }
  primary_compose_project = local.validated_compose_projects[local.primary_compose_project_key]
  sitectl_packages = distinct(concat(
    ["sitectl"],
    var.sitectl_packages,
    flatten([for _, app in local.compose_projects : app.sitectl_packages])
  ))

  gcp_only_files = toset([
    "etc/cloud-compose/libexec/build-cos-make.sh",
    "etc/cloud-compose/libexec/gcp-cloud-init-finalize.sh",
    "etc/cloud-compose/libexec/gcp-cloud-init-post-bootstrap.sh",
    "etc/cloud-compose/libexec/gcp-filesystem-boot.sh",
    "etc/fluent-bit/fluent-bit.conf",
    "etc/systemd/system/cloud-compose-internal-services.service",
    "etc/systemd/system/cloud-compose-internal-services.timer",
    "home/cloud-compose/install-dependencies-cos.sh",
    "mnt/disks/data/libops-internal/docker-compose.yaml",
  ])
  base_files = setsubtract(
    fileset(local.rootfs, "**"),
    var.provider_name == "gcp" ? toset([]) : local.gcp_only_files,
  )
  additional_files = local.additional_rootfs != "" ? fileset(local.additional_rootfs, "**") : []
  all_files = merge(
    { for file in local.base_files : file => "${local.rootfs}/${file}" },
    { for file in local.additional_files : file => "${local.additional_rootfs}/${file}" }
  )
  rootfs_file_permissions = {
    for file in setunion(local.base_files, local.additional_files) :
    file => endswith(file, ".sh") || endswith(file, ".py") || "/${file}" == var.offhost_backup_driver_path ? "0755" : "0644"
  }

  rootfs_bundle_content = jsonencode({
    version = 1
    files = {
      for file, fullpath in local.all_files : file => {
        mode    = local.rootfs_file_permissions[file]
        content = file(fullpath)
      }
    }
  })

  docker_compose_scripts = join("\n", [
    for name in ["init", "up", "down", "rollout"] : <<-EOT
      - path: "/home/cloud-compose/${name}"
        owner: "root:root"
        permissions: "0755"
        encoding: b64
        content: ${filebase64("${local.rootfs}/home/cloud-compose/lifecycle-entrypoint.sh")}
EOT
  ])

  compose_projects_content = jsonencode(local.validated_compose_projects)
  compose_projects_file    = <<-EOT
    - path: "/home/cloud-compose/compose-projects.json"
      owner: "root:root"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.compose_projects_content))}
EOT

  managed_runtime_artifact_lines = [
    for artifact in module.managed_artifacts.artifacts : join("\t", [
      artifact.name,
      artifact.url,
      artifact.sha256,
      artifact.path,
      try(artifact.mode, "0755"),
      try(artifact.owner, "root"),
      try(artifact.group, "root"),
      try(artifact.restart, ""),
    ])
  ]
  managed_runtime_artifacts_content = length(local.managed_runtime_artifact_lines) == 0 ? "\n" : "${join("\n", local.managed_runtime_artifact_lines)}\n"
  managed_runtime_artifacts_file    = <<-EOT
    - path: "/home/cloud-compose/managed-runtime-artifacts.tsv"
      owner: "root:root"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.managed_runtime_artifacts_content))}
EOT

  vault_agent_template_stanzas = join("\n", [
    for template in var.vault_agent_templates : <<-EOT
      template {
        destination = ${jsonencode(template.destination)}
        contents = <<EOH
      ${indent(2, template.contents)}
      EOH
        perms = ${jsonencode(try(template.perms, "0640"))}
      %{if trimspace(try(template.command, "")) != ""}
        command = ${jsonencode(template.command)}
      %{endif}
      }
    EOT
  ])
  vault_agent_auto_auth      = trimspace(var.vault_agent_additional_config)
  vault_agent_env_content    = <<-EOT
    VAULT_ADDR=${trimspace(var.vault_addr)}
    VAULT_NAMESPACE=${trimspace(var.vault_namespace)}
    VAULT_ROLE=${trimspace(var.vault_role)}
    VAULT_AUTH_METHOD=${var.vault_auth_method}
  EOT
  vault_agent_config_content = <<-EOT
    vault {
      address = ${jsonencode(trimspace(var.vault_addr))}
%{if trimspace(var.vault_namespace) != ""}
      namespace = ${jsonencode(trimspace(var.vault_namespace))}
%{endif}
    }

    ${indent(4, local.vault_agent_auto_auth)}

    ${indent(4, local.vault_agent_template_stanzas)}
  EOT
  vault_agent_files_raw      = <<-EOT
    - path: "/etc/default/vault-agent"
      permissions: "0600"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.vault_agent_env_content))}
    - path: "/etc/vault-agent.d/cloud-compose.hcl"
      permissions: "0600"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.vault_agent_config_content))}
  EOT
  vault_agent_files          = var.vault_agent_enabled && trimspace(var.vault_addr) != "" ? local.vault_agent_files_raw : ""

  host_env = {
    HOME                                  = "/home/cloud-compose"
    CLOUD_COMPOSE_PROVIDER                = var.provider_name
    CLOUD_COMPOSE_INSTANCE_NAME           = var.name
    CLOUD_COMPOSE_APPS                    = join(" ", keys(local.compose_projects))
    CLOUD_COMPOSE_PRIMARY_APP             = local.primary_compose_project_key
    CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED = tostring(var.offhost_backup_required)
    CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER   = var.offhost_backup_driver_path
    COMPOSE_PROJECTS_FILE                 = "/home/cloud-compose/compose-projects.json"
    COMPOSE_PROJECT_NAME                  = local.primary_compose_project.compose_project_name
    COMPOSE_BIND_PORT                     = tostring(local.primary_compose_project.ingress_port)
    DOCKER_COMPOSE_DIR                    = local.primary_compose_project.project_dir
    DOCKER_COMPOSE_REPO                   = local.primary_compose_project.docker_compose_repo
    DOCKER_COMPOSE_BRANCH                 = local.primary_compose_project.docker_compose_branch
    DOCKER_COMPOSE_VERSION                = var.docker_compose_version
    DOCKER_BUILDX_VERSION                 = var.docker_buildx_version
    GCP_PROJECT                           = ""
    GCP_PROJECT_NUMBER                    = ""
    GCP_INSTANCE_NAME                     = var.name
    GCP_REGION                            = var.region
    GCP_ZONE                              = var.zone != "" ? var.zone : var.region
    GCP_APP_SERVICE_ACCOUNT_EMAIL         = ""
    GCP_APP_CREDENTIALS_ENABLED           = "false"
    SITECTL_PACKAGES                      = join(" ", module.sitectl_runtime.packages)
    SITECTL_VERSION                       = var.sitectl_version
    SITECTL_PACKAGE_VERSIONS              = jsonencode(module.sitectl_runtime.package_versions)
    SITECTL_CONTEXT_NAME                  = local.primary_compose_project.sitectl_context_name
    SITECTL_PLUGIN                        = local.primary_compose_project.sitectl_plugin
    SITECTL_ENVIRONMENT                   = local.primary_compose_project.sitectl_environment
    SITECTL_VERIFY_ARGS                   = join(" ", local.primary_compose_project.sitectl_verify_args)
    POWER_MANAGEMENT_ENABLED              = "false"
    COMPOSE_PROFILES                      = ""
    VAULT_ADDR                            = trimspace(var.vault_addr)
    VAULT_NAMESPACE                       = trimspace(var.vault_namespace)
    VAULT_ROLE                            = trimspace(var.vault_role)
    VAULT_AGENT_ENABLED                   = var.vault_agent_enabled && trimspace(var.vault_addr) != "" ? "true" : "false"
    VAULT_AUTH_METHOD                     = var.vault_auth_method
    ROLLOUT_ENABLED                       = tostring(var.rollout_enabled)
    ROLLOUT_DOWNLOAD_URL                  = trimspace(var.rollout_release_url)
    ROLLOUT_DOWNLOAD_SHA256               = trimspace(var.rollout_release_sha256)
    ROLLOUT_PORT                          = tostring(var.rollout_port)
    ROLLOUT_JWKS_URI                      = trimspace(var.rollout_jwks_uri)
    ROLLOUT_JWT_AUD                       = trimspace(var.rollout_jwt_audience)
    ROLLOUT_CUSTOM_CLAIMS                 = trimspace(var.rollout_custom_claims)
    ROLLOUT_CMD                           = "/bin/bash"
    ROLLOUT_ARGS                          = "/home/cloud-compose/rollout"
    ROLLOUT_LOCK_FILE                     = "/mnt/disks/data/rollout.lock"
    VAULT_AGENT_TOKEN_PATH                = var.vault_agent_token_path
    LIBOPS_MANAGED_RUNTIME_ENABLED        = tostring(var.libops_managed_runtime_enabled)
    LIBOPS_INTERNAL_SERVICES_ENABLED      = tostring(var.libops_internal_services_enabled)
    LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE  = tostring(var.libops_internal_services_auto_update)
    INTERNAL_SERVICES_COMPOSE_PROFILES    = ""
  }

  env_file_content = <<-EOT
    - path: "/home/cloud-compose/.env"
      owner: "root:root"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(module.runtime_env.content))}
  EOT

  application_env_file_content = <<-EOT
    - path: "/home/cloud-compose/application-env.json"
      owner: "root:root"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(jsonencode(var.extra_env)))}
  EOT
  cloud_init = templatefile("${path.module}/templates/cloud-init.yml", {
    CLOUD_COMPOSE_SSH_KEYS         = var.cloud_compose_ssh_keys
    SSH_USERS                      = var.ssh_users
    ROOTFS_INSTALLER_B64           = base64gzip(file("${local.rootfs}/etc/cloud-compose/libexec/install-rootfs.py"))
    ROOTFS_BUNDLE_B64              = base64gzip(local.rootfs_bundle_content)
    LINUX_CLOUD_INIT_SCRIPT_B64    = base64gzip(file("${local.rootfs}/etc/cloud-compose/libexec/linux-vm-cloud-init.sh"))
    LINUX_CLOUD_INIT_SCRIPT_SHA256 = filesha256("${local.rootfs}/etc/cloud-compose/libexec/linux-vm-cloud-init.sh")
    DIAGNOSTICS_SCRIPT_B64         = base64gzip(file("${local.rootfs}/etc/cloud-compose/bin/cloud-compose-diagnostics.sh"))
    DIAGNOSTICS_SCRIPT_SHA256      = filesha256("${local.rootfs}/etc/cloud-compose/bin/cloud-compose-diagnostics.sh")
    DATA_DEVICE                    = var.data_device
    VOLUMES_DEVICE                 = var.volumes_device
    DOCKER_COMPOSE_SCRIPTS         = local.docker_compose_scripts
    COMPOSE_PROJECTS_FILE          = local.compose_projects_file
    ENV_FILE_CONTENT               = local.env_file_content
    APPLICATION_ENV_FILE_CONTENT   = local.application_env_file_content
    VAULT_AGENT_FILES              = local.vault_agent_files
    MANAGED_RUNTIME_ARTIFACTS_FILE = local.managed_runtime_artifacts_file
    ROLLOUT_ENABLED                = tostring(var.rollout_enabled)
    SITECTL_VERSION                = module.sitectl_runtime.package_versions["sitectl"]
  })
}

module "sitectl_runtime" {
  source = "../sitectl-runtime"

  packages         = local.sitectl_packages
  fallback_version = var.sitectl_version
  package_versions = var.sitectl_package_versions
}

module "managed_artifacts" {
  source = "../managed-artifacts"

  artifacts = var.libops_managed_artifacts
}

module "project_directories" {
  source = "../project-directories"

  project_dirs = { for app_name, app in local.compose_projects : app_name => app.project_dir }
}

module "runtime_env" {
  source = "../runtime-env"

  env = local.host_env
}
