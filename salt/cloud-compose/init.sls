{% import_json "templates/apps.json" as app_registry %}
{% set cc = salt['pillar.get']('cloud_compose', {}) %}
{% set name = cc.get('name', 'cloud-compose') %}
{% set provider = cc.get('provider', 'onprem') %}
{% set user = 'cloud-compose' %}
{% set group = 'cloud-compose' %}
{% set home = '/home/cloud-compose' %}
{% set data_dir = '/mnt/disks/data' %}
{% set volumes_dir = '/mnt/disks/volumes' %}
{% set runtime = cc.get('runtime', {}) %}
{% set compose = runtime.get('compose', {}) %}
{% set sitectl = runtime.get('sitectl', {}) %}
{% set docker = runtime.get('docker', {}) %}
{% set managed = runtime.get('managed_runtime', {}) %}
{% set vault = runtime.get('vault', {}) %}
{% set template_name = cc.get('template', '') | lower | trim %}
{% set template = app_registry.default %}
{% if template_name and template_name in app_registry.templates %}
{% set template = app_registry.templates[template_name] %}
{% endif %}
{% set default_ingress = {
  'letsencrypt': False,
  'bot_mitigation': False,
  'mode': '',
  'domain': '',
  'acme_email': '',
  'trusted_ips': [],
  'max_upload_size': '',
  'upload_timeout': ''
} %}
{% set default_init = [
  'sitectl config set-context "${SITECTL_CONTEXT_NAME}" --type local --project-dir "${DOCKER_COMPOSE_DIR}" --site "${CLOUD_COMPOSE_INSTANCE_NAME}" --plugin "${SITECTL_PLUGIN}" --environment "${SITECTL_ENVIRONMENT}" --project-name "${CLOUD_COMPOSE_INSTANCE_NAME}" --compose-project-name "${COMPOSE_PROJECT_NAME}" --docker-socket /var/run/docker.sock --env-file .env --default'
] %}
{% set default_up = [
  'sitectl compose --context "${SITECTL_CONTEXT_NAME}" up -d --remove-orphans',
  'sitectl healthcheck --context "${SITECTL_CONTEXT_NAME}" --persist --timeout "${SITECTL_HEALTHCHECK_TIMEOUT}" --interval "${SITECTL_HEALTHCHECK_INTERVAL}"',
  'if [ "${SITECTL_ENVIRONMENT}" != "production" ]; then sitectl verify --context "${SITECTL_CONTEXT_NAME}" ${SITECTL_VERIFY_ARGS:-}; fi'
] %}
{% set default_down = [
  'sitectl compose --context "${SITECTL_CONTEXT_NAME}" down'
] %}
{% set default_rollout = [
  'TARGET_REF="${GIT_REF:-${GIT_BRANCH:-${DOCKER_COMPOSE_BRANCH:-main}}}"',
  'if [ -x ./scripts/rollout.sh ]; then ./scripts/rollout.sh; else sitectl deploy --context "${SITECTL_CONTEXT_NAME}" --branch "$TARGET_REF"; fi',
  'sitectl healthcheck --context "${SITECTL_CONTEXT_NAME}" --persist --timeout "${SITECTL_HEALTHCHECK_TIMEOUT}" --interval "${SITECTL_HEALTHCHECK_INTERVAL}"',
  'if [ "${SITECTL_ENVIRONMENT}" != "production" ]; then sitectl verify --context "${SITECTL_CONTEXT_NAME}" ${SITECTL_VERIFY_ARGS:-}; fi'
] %}
{% set repo = compose.get('repo') or template.repo %}
{% set branch = compose.get('branch') or template.branch %}
{% set ingress_port = compose.get('ingress_port', 80) %}
{% set ingress = default_ingress.copy() %}
{% set ignored = ingress.update(compose.get('ingress', {})) %}
{% set sitectl_packages = sitectl.get('packages') or template.packages %}
{% if 'sitectl' not in sitectl_packages %}
{% set sitectl_packages = ['sitectl'] + sitectl_packages %}
{% endif %}
{% set repo_path_source = repo | replace('https://github.com/', '') | replace('http://github.com/', '') | replace('git@github.com:', '') %}
{% set repo_path = compose.get('repo_path') or (repo_path_source.strip('/') if repo_path_source else name) %}
{% set project_dir = compose.get('project_dir') or data_dir ~ '/' ~ repo_path ~ '/' ~ branch %}
{% set compose_project_name = compose.get('compose_project_name') or ((repo_path ~ '-' ~ branch) | lower | replace('.git', '') | replace('/', '-') | replace('_', '-')) %}
{% set explicit_projects = compose.get('projects', {}) %}
{% set normalized_projects = {} %}
{% if explicit_projects %}
{% for app_name, app in explicit_projects.items() %}
{% set app_repo = app.get('docker_compose_repo') or app.get('repo') or repo %}
{% set app_branch = app.get('docker_compose_branch') or app.get('branch') or branch %}
{% set app_repo_path_source = app_repo | replace('https://github.com/', '') | replace('http://github.com/', '') | replace('git@github.com:', '') %}
{% set app_repo_path = app.get('repo_path') or (app_repo_path_source.strip('/') if app_repo_path_source else app_name) %}
{% set app_ingress = ingress.copy() %}
{% set ignored = app_ingress.update(app.get('ingress', {})) %}
{% set app_packages = app.get('sitectl_packages', sitectl_packages) %}
{% if 'sitectl' not in app_packages %}
{% set app_packages = ['sitectl'] + app_packages %}
{% endif %}
{% set app_project = {
  'name': app_name,
  'docker_compose_repo': app_repo,
  'docker_compose_branch': app_branch,
  'repo_path': app_repo_path,
  'project_dir': app.get('project_dir') or data_dir ~ '/' ~ app_repo_path ~ '/' ~ app_branch,
  'compose_project_name': app.get('compose_project_name') or ((app_repo_path ~ '-' ~ app_branch) | lower | replace('.git', '') | replace('/', '-') | replace('_', '-')),
  'ingress_port': app.get('ingress_port', ingress_port),
  'ingress': app_ingress,
  'sitectl_context_name': app.get('sitectl_context_name', app_name),
  'sitectl_plugin': app.get('sitectl_plugin', sitectl.get('plugin', template.plugin)),
  'sitectl_environment': app.get('sitectl_environment', sitectl.get('environment', 'production')),
  'sitectl_packages': app_packages,
  'sitectl_verify_args': app.get('sitectl_verify_args', sitectl.get('verify_args', [])),
  'init_commands': app.get('init_commands') or app.get('docker_compose_init') or compose.get('init') or default_init,
  'up_commands': app.get('up_commands') or app.get('docker_compose_up') or compose.get('up') or default_up,
  'down_commands': app.get('down_commands') or app.get('docker_compose_down') or compose.get('down') or default_down,
  'rollout_commands': app.get('rollout_commands') or app.get('docker_compose_rollout') or compose.get('rollout') or default_rollout
} %}
{% set ignored = normalized_projects.update({app_name: app_project}) %}
{% endfor %}
{% else %}
{% set single_project = {
  'name': name,
  'docker_compose_repo': repo,
  'docker_compose_branch': branch,
  'repo_path': repo_path,
  'project_dir': project_dir,
  'compose_project_name': compose_project_name,
  'ingress_port': ingress_port,
  'ingress': ingress,
  'sitectl_context_name': sitectl.get('context_name') or name,
  'sitectl_plugin': sitectl.get('plugin', template.plugin),
  'sitectl_environment': sitectl.get('environment', 'production'),
  'sitectl_packages': sitectl_packages,
  'sitectl_verify_args': sitectl.get('verify_args', []),
  'init_commands': compose.get('init') or default_init,
  'up_commands': compose.get('up') or default_up,
  'down_commands': compose.get('down') or default_down,
  'rollout_commands': compose.get('rollout') or default_rollout
} %}
{% set ignored = normalized_projects.update({name: single_project}) %}
{% endif %}
{% set compose_projects = normalized_projects %}
{% set primary_key = compose.get('primary') or (compose_projects.keys() | list | first) %}
{% set primary_project = compose_projects.get(primary_key, {}) %}
{% set all_packages = [] %}
{% for project in compose_projects.values() %}
{% for package in project.get('sitectl_packages', []) %}
{% if package not in all_packages %}
{% set ignored = all_packages.append(package) %}
{% endif %}
{% endfor %}
{% endfor %}
{% if 'sitectl' not in all_packages %}
{% set ignored = all_packages.insert(0, 'sitectl') %}
{% endif %}
{% set vault_addr = vault.get('addr', '') %}
{% set env = {
  'HOME': home,
  'CLOUD_COMPOSE_PROVIDER': provider,
  'CLOUD_COMPOSE_INSTANCE_NAME': name,
  'CLOUD_COMPOSE_APPS': compose_projects.keys() | list | join(' '),
  'CLOUD_COMPOSE_PRIMARY_APP': primary_key,
  'COMPOSE_PROJECTS_FILE': home ~ '/compose-projects.json',
  'COMPOSE_PROJECT_NAME': primary_project.get('compose_project_name', compose_project_name),
  'COMPOSE_BIND_PORT': primary_project.get('ingress_port', ingress_port),
  'DOCKER_COMPOSE_DIR': primary_project.get('project_dir', project_dir),
  'DOCKER_COMPOSE_REPO': primary_project.get('docker_compose_repo', repo),
  'DOCKER_COMPOSE_BRANCH': primary_project.get('docker_compose_branch', branch),
  'DOCKER_COMPOSE_VERSION': docker.get('compose_version', cc.get('docker_compose_version', 'v5.2.0')),
  'DOCKER_BUILDX_VERSION': docker.get('buildx_version', cc.get('docker_buildx_version', 'v0.35.0')),
  'GCP_PROJECT': '',
  'GCP_PROJECT_NUMBER': '',
  'GCP_INSTANCE_NAME': name,
  'GCP_REGION': '',
  'GCP_ZONE': '',
  'GCP_APP_SERVICE_ACCOUNT_EMAIL': '',
  'SITECTL_PACKAGES': all_packages | join(' '),
  'SITECTL_VERSION': sitectl.get('version', cc.get('sitectl_version', 'latest')),
  'SITECTL_CONTEXT_NAME': primary_project.get('sitectl_context_name', name),
  'SITECTL_PLUGIN': primary_project.get('sitectl_plugin', sitectl.get('plugin', template.plugin)),
  'SITECTL_ENVIRONMENT': primary_project.get('sitectl_environment', sitectl.get('environment', 'production')),
  'SITECTL_HEALTHCHECK_TIMEOUT': sitectl.get('healthcheck_timeout', '20m'),
  'SITECTL_HEALTHCHECK_INTERVAL': sitectl.get('healthcheck_interval', '15s'),
  'SITECTL_VERIFY_ARGS': primary_project.get('sitectl_verify_args', []) | join(' '),
  'POWER_MANAGEMENT_ENABLED': 'false',
  'COMPOSE_PROFILES': '',
  'VAULT_ADDR': vault_addr,
  'VAULT_NAMESPACE': vault.get('namespace', ''),
  'VAULT_ROLE': vault.get('role', ''),
  'VAULT_AGENT_ENABLED': 'true' if vault.get('agent_enabled', False) and vault_addr else 'false',
  'VAULT_AUTH_METHOD': vault.get('auth_method', 'consumer-managed'),
  'VAULT_AGENT_TOKEN_PATH': vault.get('agent_token_path', '/mnt/disks/data/vault/token'),
  'LIBOPS_MANAGED_RUNTIME_ENABLED': 'true' if managed.get('enabled', cc.get('managed_runtime_enabled', True)) else 'false',
  'LIBOPS_INTERNAL_SERVICES_ENABLED': 'true' if managed.get('internal_services_enabled', cc.get('internal_services_enabled', False)) else 'false',
  'LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE': 'true' if managed.get('internal_services_auto_update', cc.get('internal_services_auto_update', False)) else 'false',
  'INTERNAL_SERVICES_COMPOSE_PROFILES': ''
} %}
{% set ignored = env.update(cc.get('extra_env', {})) %}
{% set managed_artifacts = managed.get('artifacts', cc.get('managed_artifacts', [])) %}

{% if not explicit_projects and not repo %}
cloud-compose-requires-repo:
  test.fail_without_changes:
    - name: Set cloud_compose.template, cloud_compose.runtime.compose.repo, or cloud_compose.runtime.compose.projects.
{% endif %}

cloud-compose-packages:
  pkg.installed:
    - pkgs:
      - ca-certificates
      - curl
      - docker.io
      - git
      - jq
      - make

cloud-compose-docker:
  service.running:
    - name: docker
    - enable: True
    - require:
      - pkg: cloud-compose-packages

cloud-compose-group:
  group.present:
    - name: {{ group | json }}

cloud-compose-user:
  user.present:
    - name: {{ user | json }}
    - shell: /bin/bash
    - home: {{ home | json }}
    - createhome: True
    - gid: {{ group | json }}
    - groups:
      - docker
    - require:
      - group: cloud-compose-group
      - pkg: cloud-compose-packages

cloud-compose-data-dirs:
  file.directory:
    - names:
      - {{ data_dir | json }}
      - {{ volumes_dir | json }}
      - {{ (data_dir ~ '/libops') | json }}
    - user: {{ user | json }}
    - group: {{ group | json }}
    - mode: '0775'
    - makedirs: True
    - require:
      - user: cloud-compose-user

cloud-compose-rootfs:
  file.recurse:
    - name: /
    - source: salt://rootfs
    - clean: False
    - include_empty: True
    - require:
      - user: cloud-compose-user

cloud-compose-env:
  file.managed:
    - name: {{ (home ~ '/.env') | json }}
    - source: salt://cloud-compose/files/env.jinja
    - template: jinja
    - user: {{ user | json }}
    - group: {{ group | json }}
    - mode: '0640'
    - context:
        env: {{ env | json }}
    - require:
      - file: cloud-compose-rootfs

cloud-compose-project-manifest:
  file.managed:
    - name: {{ (home ~ '/compose-projects.json') | json }}
    - source: salt://cloud-compose/files/compose-projects.json.jinja
    - template: jinja
    - user: {{ user | json }}
    - group: {{ group | json }}
    - mode: '0640'
    - context:
        compose_projects: {{ compose_projects | json }}
    - require:
      - file: cloud-compose-rootfs

cloud-compose-managed-runtime-artifacts:
  file.managed:
    - name: {{ (home ~ '/managed-runtime-artifacts.tsv') | json }}
    - source: salt://cloud-compose/files/managed-runtime-artifacts.tsv.jinja
    - template: jinja
    - user: {{ user | json }}
    - group: {{ group | json }}
    - mode: '0640'
    - context:
        managed_artifacts: {{ managed_artifacts | json }}
    - require:
      - file: cloud-compose-rootfs

cloud-compose-systemd-reload:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: cloud-compose-rootfs

{% if cc.get('force_bootstrap', False) %}
cloud-compose-clear-bootstrap-marker:
  file.absent:
    - name: {{ (home ~ '/.cloud-compose-bootstrap-complete') | json }}
{% endif %}

{% if cc.get('run_bootstrap', True) %}
cloud-compose-bootstrap:
  cmd.run:
    - name: bash {{ (home ~ '/run.sh') | json }}
    - creates: {{ (home ~ '/.cloud-compose-bootstrap-complete') | json }}
    - require:
      - service: cloud-compose-docker
      - file: cloud-compose-env
      - file: cloud-compose-project-manifest
      - file: cloud-compose-managed-runtime-artifacts
{% endif %}
