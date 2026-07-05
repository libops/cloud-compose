locals {
  rootfs                = "${path.module}/../../rootfs"
  additional_rootfs     = var.rootfs != "" ? var.rootfs : ""
  rootfs_archive_url    = trimspace(var.rootfs_archive_url)
  rootfs_archive_sha256 = trimspace(var.rootfs_archive_sha256)

  single_compose_project = {
    (var.name) = {
      docker_compose_repo    = var.docker_compose_repo
      docker_compose_branch  = var.docker_compose_branch
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
  raw_compose_projects        = length(var.compose_projects) > 0 ? var.compose_projects : local.single_compose_project
  primary_compose_project_key = trimspace(var.primary_compose_project) != "" ? trimspace(var.primary_compose_project) : keys(local.raw_compose_projects)[0]
  compose_projects = {
    for app_name, app in local.raw_compose_projects : app_name => {
      name                  = app_name
      docker_compose_repo   = trimspace(app.docker_compose_repo)
      docker_compose_branch = trimspace(coalesce(try(app.docker_compose_branch, null), var.docker_compose_branch))
      repo_path             = trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/")
      project_dir = (
        trimspace(try(app.project_dir, "")) != ""
        ? trimspace(try(app.project_dir, ""))
        : "/mnt/disks/data/${trim(replace(trimspace(app.docker_compose_repo), "/^[^:]+://[^/]+/", ""), "/")}/${trimspace(coalesce(try(app.docker_compose_branch, null), var.docker_compose_branch))}"
      )
      compose_project_name = (
        trimspace(try(app.compose_project_name, "")) != ""
        ? trimspace(try(app.compose_project_name, ""))
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
        trimspace(try(app.sitectl_context_name, "")) != ""
        ? trimspace(try(app.sitectl_context_name, ""))
        : app_name
      )
      sitectl_plugin      = trimspace(coalesce(try(app.sitectl_plugin, null), var.sitectl_plugin))
      sitectl_environment = trimspace(coalesce(try(app.sitectl_environment, null), var.sitectl_environment))
      sitectl_packages    = distinct(concat(["sitectl"], try(app.sitectl_packages, [])))
      sitectl_verify_args = try(app.sitectl_verify_args, var.sitectl_verify_args)
      init_commands       = try(app.docker_compose_init, null) != null ? app.docker_compose_init : var.docker_compose_init
      up_commands         = try(app.docker_compose_up, null) != null ? app.docker_compose_up : var.docker_compose_up
      down_commands       = try(app.docker_compose_down, null) != null ? app.docker_compose_down : var.docker_compose_down
      rollout_commands    = try(app.docker_compose_rollout, null) != null ? app.docker_compose_rollout : var.docker_compose_rollout
    }
  }
  primary_compose_project = local.compose_projects[local.primary_compose_project_key]
  sitectl_packages = distinct(concat(
    ["sitectl"],
    var.sitectl_packages,
    flatten([for _, app in local.compose_projects : app.sitectl_packages])
  ))

  base_files       = local.rootfs_archive_url == "" ? fileset(local.rootfs, "**") : []
  additional_files = local.additional_rootfs != "" ? fileset(local.additional_rootfs, "**") : []
  all_files = merge(
    { for file in local.base_files : file => "${local.rootfs}/${file}" },
    { for file in local.additional_files : file => "${local.additional_rootfs}/${file}" }
  )

  write_files_content = join("\n", [
    for file, fullpath in local.all_files : <<-EOT
      - path: ${jsonencode("/${file}")}
        permissions: ${jsonencode(endswith(file, ".sh") ? "0755" : "0644")}
        encoding: gzip+base64
        content: ${jsonencode(base64gzip(file(fullpath)))}
EOT
  ])

  docker_compose_scripts = join("\n", [
    for name in ["init", "up", "down", "rollout"] : <<-EOT
      - path: "/home/cloud-compose/${name}"
        permissions: "0755"
        encoding: gzip+base64
        content: ${jsonencode(base64gzip(<<-EOS
          #!/usr/bin/env bash

          set -eou pipefail

          source /home/cloud-compose/profile.sh
          exec bash /home/cloud-compose/compose-dispatch.sh "${name}"
        EOS
))}
EOT
])

compose_projects_content = jsonencode(local.compose_projects)
compose_projects_file    = <<-EOT
    - path: "/home/cloud-compose/compose-projects.json"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.compose_projects_content))}
EOT

managed_runtime_artifact_lines = [
  for artifact in var.libops_managed_artifacts : join("\t", [
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
managed_runtime_artifacts_content = join("\n", local.managed_runtime_artifact_lines)
managed_runtime_artifacts_file    = <<-EOT
    - path: "/home/cloud-compose/managed-runtime-artifacts.tsv"
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
vault_agent_auto_auth_gcp  = <<-EOT
    auto_auth {
      method "gcp" {
        mount_path = ${jsonencode(var.vault_gcp_auth_mount_path)}
        config = {
          type    = "iam"
          role    = ${jsonencode(trimspace(var.vault_role))}
          jwt_exp = 15
        }
      }

      sink "file" {
        config = {
          path = ${jsonencode(var.vault_agent_token_path)}
        }
      }
    }
  EOT
vault_agent_auto_auth      = var.vault_auth_method == "gcp-iam" ? local.vault_agent_auto_auth_gcp : trimspace(var.vault_agent_additional_config)
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

env = merge({
  HOME                                 = "/home/cloud-compose"
  CLOUD_COMPOSE_PROVIDER               = var.provider_name
  CLOUD_COMPOSE_INSTANCE_NAME          = var.name
  CLOUD_COMPOSE_APPS                   = join(" ", keys(local.compose_projects))
  CLOUD_COMPOSE_PRIMARY_APP            = local.primary_compose_project_key
  COMPOSE_PROJECTS_FILE                = "/home/cloud-compose/compose-projects.json"
  COMPOSE_PROJECT_NAME                 = local.primary_compose_project.compose_project_name
  COMPOSE_BIND_PORT                    = tostring(local.primary_compose_project.ingress_port)
  DOCKER_COMPOSE_DIR                   = local.primary_compose_project.project_dir
  DOCKER_COMPOSE_REPO                  = local.primary_compose_project.docker_compose_repo
  DOCKER_COMPOSE_BRANCH                = local.primary_compose_project.docker_compose_branch
  DOCKER_COMPOSE_VERSION               = var.docker_compose_version
  DOCKER_BUILDX_VERSION                = var.docker_buildx_version
  GCP_PROJECT                          = ""
  GCP_PROJECT_NUMBER                   = ""
  GCP_INSTANCE_NAME                    = var.name
  GCP_REGION                           = var.region
  GCP_ZONE                             = var.zone != "" ? var.zone : var.region
  GCP_APP_SERVICE_ACCOUNT_EMAIL        = ""
  SITECTL_PACKAGES                     = join(" ", local.sitectl_packages)
  SITECTL_VERSION                      = var.sitectl_version
  SITECTL_CONTEXT_NAME                 = local.primary_compose_project.sitectl_context_name
  SITECTL_PLUGIN                       = local.primary_compose_project.sitectl_plugin
  SITECTL_ENVIRONMENT                  = local.primary_compose_project.sitectl_environment
  SITECTL_HEALTHCHECK_TIMEOUT          = var.sitectl_healthcheck_timeout
  SITECTL_HEALTHCHECK_INTERVAL         = var.sitectl_healthcheck_interval
  SITECTL_VERIFY_ARGS                  = join(" ", local.primary_compose_project.sitectl_verify_args)
  POWER_MANAGEMENT_ENABLED             = "false"
  COMPOSE_PROFILES                     = ""
  VAULT_ADDR                           = trimspace(var.vault_addr)
  VAULT_NAMESPACE                      = trimspace(var.vault_namespace)
  VAULT_ROLE                           = trimspace(var.vault_role)
  VAULT_AGENT_ENABLED                  = var.vault_agent_enabled && trimspace(var.vault_addr) != "" ? "true" : "false"
  VAULT_AUTH_METHOD                    = var.vault_auth_method
  VAULT_AGENT_TOKEN_PATH               = var.vault_agent_token_path
  LIBOPS_MANAGED_RUNTIME_ENABLED       = tostring(var.libops_managed_runtime_enabled)
  LIBOPS_INTERNAL_SERVICES_ENABLED     = tostring(var.libops_internal_services_enabled)
  LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE = tostring(var.libops_internal_services_auto_update)
  INTERNAL_SERVICES_COMPOSE_PROFILES   = ""
}, var.extra_env)

env_file_plain   = join("\n", [for key, value in local.env : "${key}=${jsonencode(tostring(value))}"])
env_file_content = <<-EOT
    - path: "/home/cloud-compose/.env"
      permissions: "0640"
      encoding: gzip+base64
      content: ${jsonencode(base64gzip(local.env_file_plain))}
  EOT

rootfs_archive_command_raw = <<-EOT
    - |
      set -eu
      archive_url=${jsonencode(local.rootfs_archive_url)}
      archive_sha256=${jsonencode(local.rootfs_archive_sha256)}
      if ! command -v curl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get install -y ca-certificates curl tar
        elif command -v dnf >/dev/null 2>&1; then
          dnf install -y ca-certificates curl tar
        elif command -v rpm-ostree >/dev/null 2>&1; then
          rpm-ostree install --apply-live ca-certificates curl tar
        else
          echo "No supported package manager found to install curl" >&2
          exit 1
        fi
      fi
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      curl -fsSL "$archive_url" -o "$tmp/rootfs.tar.gz"
      if [ -n "$archive_sha256" ]; then
        printf '%s  %s\n' "$archive_sha256" "$tmp/rootfs.tar.gz" | sha256sum -c -
      fi
      tar -xzf "$tmp/rootfs.tar.gz" -C "$tmp"
      rootfs_dir="$(find "$tmp" -mindepth 2 -maxdepth 2 -type d -name rootfs | head -n 1)"
      if [ -z "$rootfs_dir" ]; then
        echo "rootfs directory not found in $archive_url" >&2
        exit 1
      fi
      cp -a "$rootfs_dir"/. /
  EOT
rootfs_archive_command     = local.rootfs_archive_url != "" ? local.rootfs_archive_command_raw : ""

cloud_init = templatefile("${path.module}/templates/cloud-init.yml", {
  CLOUD_COMPOSE_SSH_KEYS         = var.cloud_compose_ssh_keys
  SSH_USERS                      = var.ssh_users
  DATA_DEVICE                    = var.data_device
  VOLUMES_DEVICE                 = var.volumes_device
  WRITE_FILES_CONTENT            = local.write_files_content
  DOCKER_COMPOSE_SCRIPTS         = local.docker_compose_scripts
  COMPOSE_PROJECTS_FILE          = local.compose_projects_file
  ENV_FILE_CONTENT               = local.env_file_content
  VAULT_AGENT_FILES              = local.vault_agent_files
  MANAGED_RUNTIME_ARTIFACTS_FILE = local.managed_runtime_artifacts_file
  ROOTFS_ARCHIVE_COMMAND         = local.rootfs_archive_command
})
}
