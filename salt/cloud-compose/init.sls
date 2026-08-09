{% import_json "templates/apps.json" as app_registry %}
{% macro normalize_compose_project_name(repo_path, ref) -%}
{%- set candidate = (repo_path | replace('.git', '')) ~ '-' ~ ref -%}
{%- set normalized = namespace(value='', separator=False) -%}
{%- for character in candidate | lower -%}
{%- if character in 'abcdefghijklmnopqrstuvwxyz0123456789' -%}
{%- if normalized.separator and normalized.value -%}
{%- set normalized.value = normalized.value ~ '-' -%}
{%- endif -%}
{%- set normalized.value = normalized.value ~ character -%}
{%- set normalized.separator = False -%}
{%- elif normalized.value -%}
{%- set normalized.separator = True -%}
{%- endif -%}
{%- endfor -%}
{{- normalized.value -}}
{%- endmacro %}
{% set invalid_runtime_inputs = [] %}
{% set raw_cc = salt['pillar.get']('cloud_compose', {}) %}
{% if raw_cc is mapping %}
{% set cc = raw_cc %}
{% else %}
{% set cc = {} %}
{% set ignored = invalid_runtime_inputs.append('cloud_compose must be a map') %}
{% endif %}
{% set name = cc.get('name', 'cloud-compose') %}
{% set provider = cc.get('provider', 'onprem') %}
{% set user = 'cloud-compose' %}
{% set group = 'cloud-compose' %}
{% set home = '/home/cloud-compose' %}
{% set data_dir = '/mnt/disks/data' %}
{% set volumes_dir = '/mnt/disks/volumes' %}
{% set raw_runtime = cc.get('runtime', {}) %}
{% if raw_runtime is mapping %}
{% set runtime = raw_runtime %}
{% else %}
{% set runtime = {} %}
{% set ignored = invalid_runtime_inputs.append('runtime must be a map') %}
{% endif %}
{% set runtime_sections = {
  'compose': runtime.get('compose', {}),
  'sitectl': runtime.get('sitectl', {}),
  'docker': runtime.get('docker', {}),
  'managed_runtime': runtime.get('managed_runtime', {}),
  'vault': runtime.get('vault', {}),
  'disaster_recovery': runtime.get('disaster_recovery', {})
} %}
{% for section_name, section_value in runtime_sections.items() %}
{% if section_value is not mapping %}
{% set ignored = invalid_runtime_inputs.append('runtime.' ~ section_name ~ ' must be a map') %}
{% endif %}
{% endfor %}
{% set compose = runtime_sections.compose if runtime_sections.compose is mapping else {} %}
{% set sitectl = runtime_sections.sitectl if runtime_sections.sitectl is mapping else {} %}
{% set docker = runtime_sections.docker if runtime_sections.docker is mapping else {} %}
{% set managed = runtime_sections.managed_runtime if runtime_sections.managed_runtime is mapping else {} %}
{% set vault = runtime_sections.vault if runtime_sections.vault is mapping else {} %}
{% set disaster_recovery = runtime_sections.disaster_recovery if runtime_sections.disaster_recovery is mapping else {} %}
{% set raw_rollout_service = runtime.get('rollout', {}) %}
{% if raw_rollout_service is mapping %}
{% set rollout_service = raw_rollout_service %}
{% else %}
{% set rollout_service = {} %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout must be a map') %}
{% endif %}
{% set raw_extra_env = runtime.get('extra_env', cc.get('extra_env', {})) %}
{% if raw_extra_env is mapping %}
{% set extra_env = raw_extra_env %}
{% else %}
{% set extra_env = {} %}
{% set ignored = invalid_runtime_inputs.append('extra_env must be a map') %}
{% endif %}
{% set env_name_first = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_' %}
{% set env_name_rest = env_name_first ~ '0123456789' %}
{% set reserved_env_names = [
  'HOME', 'PATH',
  'CLOUD_COMPOSE_PROVIDER', 'CLOUD_COMPOSE_INSTANCE_NAME', 'CLOUD_COMPOSE_APPS', 'CLOUD_COMPOSE_PRIMARY_APP',
  'COMPOSE_PROJECTS_FILE', 'COMPOSE_PROJECT_NAME', 'COMPOSE_BIND_PORT', 'COMPOSE_PROFILES',
  'DOCKER_COMPOSE_DIR', 'DOCKER_COMPOSE_REPO', 'DOCKER_COMPOSE_BRANCH', 'DOCKER_COMPOSE_VERSION', 'DOCKER_BUILDX_VERSION',
  'GCP_PROJECT', 'GCP_PROJECT_NUMBER', 'GCP_INSTANCE_NAME', 'GCP_REGION', 'GCP_ZONE', 'GCP_PUBLIC_IP', 'GCP_PRIVATE_IP', 'GCP_APP_SERVICE_ACCOUNT_EMAIL',
  'SITECTL_PACKAGES', 'SITECTL_VERSION', 'SITECTL_PACKAGE_VERSIONS', 'SITECTL_CONTEXT_NAME', 'SITECTL_PLUGIN', 'SITECTL_ENVIRONMENT', 'SITECTL_VERIFY_ARGS',
  'POWER_MANAGEMENT_ENABLED',
  'VAULT_ADDR', 'VAULT_NAMESPACE', 'VAULT_ROLE', 'VAULT_AGENT_ENABLED', 'VAULT_AUTH_METHOD', 'VAULT_AGENT_TOKEN_PATH',
  'LIBOPS_MANAGED_RUNTIME_ENABLED', 'LIBOPS_INTERNAL_SERVICES_ENABLED', 'LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE', 'INTERNAL_SERVICES_COMPOSE_PROFILES'
] %}
{% set reserved_env_prefixes = [
  'CLOUD_COMPOSE_', 'COMPOSE_', 'DOCKER_', 'SITECTL_', 'LIBOPS_',
  'GCP_', 'VAULT_', 'ROLLOUT_', 'POWER_MANAGEMENT_'
] %}
{% set safe_extra_env = {} %}
{% for env_name, env_value in extra_env.items() %}
{% set env_name_check = namespace(valid=(env_name is string and env_name | length > 0 and env_name[0] in env_name_first)) %}
{% set env_reserved_check = namespace(reserved=(env_name in reserved_env_names)) %}
{% if env_name is string %}
{% for character in env_name %}
{% if character not in env_name_rest %}
{% set env_name_check.valid = False %}
{% endif %}
{% endfor %}
{% for reserved_prefix in reserved_env_prefixes %}
{% if env_name.startswith(reserved_prefix) %}
{% set env_reserved_check.reserved = True %}
{% endif %}
{% endfor %}
{% endif %}
{% if not env_name_check.valid %}
{% set ignored = invalid_runtime_inputs.append('extra_env name must match ^[A-Za-z_][A-Za-z0-9_]*$: ' ~ (env_name | string)) %}
{% elif env_reserved_check.reserved %}
{% set ignored = invalid_runtime_inputs.append('extra_env cannot replace reserved host control: ' ~ env_name) %}
{% elif env_value is not string %}
{% set ignored = invalid_runtime_inputs.append('extra_env value must be a string: ' ~ env_name) %}
{% else %}
{% set ignored = safe_extra_env.update({env_name: env_value}) %}
{% endif %}
{% endfor %}
{% set install_packages = cc.get('install_packages', True) %}
{% set reload_systemd = cc.get('reload_systemd', True) %}
{% set run_bootstrap = cc.get('run_bootstrap', True) %}
{% set force_bootstrap = cc.get('force_bootstrap', False) %}
{% set raw_template_name = cc.get('template', '') %}
{% if raw_template_name is string %}
{% set template_name = raw_template_name | lower | trim %}
{% else %}
{% set template_name = '' %}
{% set ignored = invalid_runtime_inputs.append('template must be a string') %}
{% endif %}
{% set template = app_registry.default %}
{% if template_name and template_name in app_registry.templates %}
{% set template = app_registry.templates[template_name] %}
{% elif template_name %}
{% set ignored = invalid_runtime_inputs.append('template must name a supported cloud-compose app: ' ~ template_name) %}
{% endif %}
{% set template_sitectl_package_versions = template.get('package_versions', {}) %}
{% if provider != 'onprem' %}
{% set ignored = invalid_runtime_inputs.append('the Salt adapter requires provider=onprem') %}
{% endif %}
{% if name is not string or not (name is match('^[a-z][a-z0-9-]*$')) %}
{% set ignored = invalid_runtime_inputs.append('name must match ^[a-z][a-z0-9-]*$') %}
{% endif %}
{% if cc.get('dedicated_host_acknowledged', False) is not sameas true %}
{% set ignored = invalid_runtime_inputs.append('dedicated_host_acknowledged=true is required before Salt can own Docker and host runtime configuration') %}
{% endif %}
{% if vault.get('agent_enabled', False) %}
{% set ignored = invalid_runtime_inputs.append('Vault Agent is currently supported only by Terraform providers; set vault.agent_enabled=false for Salt') %}
{% endif %}
{% set offhost_backup_required = disaster_recovery.get('required', False) %}
{% set offhost_backup_driver = disaster_recovery.get('driver_path', '/etc/cloud-compose/libexec/offhost-backup-driver') %}
{% if offhost_backup_required is not boolean %}
{% set ignored = invalid_runtime_inputs.append('runtime.disaster_recovery.required must be a boolean') %}
{% endif %}
{% if offhost_backup_driver is not string or not (offhost_backup_driver is match('^/[A-Za-z0-9._/+:-]+$')) or '//' in offhost_backup_driver or '/./' in offhost_backup_driver or '/../' in offhost_backup_driver or offhost_backup_driver.endswith('/.') or offhost_backup_driver.endswith('/..') %}
{% set ignored = invalid_runtime_inputs.append('runtime.disaster_recovery.driver_path must be a safe absolute path without whitespace or dot segments') %}
{% endif %}
{% set rollout_enabled = rollout_service.get('enabled', False) %}
{% set rollout_port = rollout_service.get('port', 8081) %}
{% if rollout_enabled is not boolean %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout.enabled must be a boolean') %}
{% endif %}
{% if rollout_port is boolean or rollout_port is not number or rollout_port < 1 or rollout_port > 65535 or rollout_port != (rollout_port | int) %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout.port must be a whole number between 1 and 65535') %}
{% endif %}
{% if rollout_enabled is sameas true %}
{% if rollout_service.get('release_url', '') is not string or not (rollout_service.get('release_url', '') is match('^https://[^\\s]+$')) %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout.release_url must be HTTPS') %}
{% endif %}
{% if rollout_service.get('release_sha256', '') is not string or not (rollout_service.get('release_sha256', '') is match('^[0-9a-f]{64}$')) %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout.release_sha256 must be a lowercase SHA-256 digest') %}
{% endif %}
{% if rollout_service.get('jwks_uri', '') is not string or not (rollout_service.get('jwks_uri', '') is match('^https://[^\\s]+$')) %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout.jwks_uri must be HTTPS') %}
{% endif %}
{% if rollout_service.get('jwt_audience', '') is not string or not rollout_service.get('jwt_audience', '') | trim %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout.jwt_audience must be non-empty') %}
{% endif %}
{% endif %}
{% if rollout_service.get('custom_claims', '') is not string %}
{% set ignored = invalid_runtime_inputs.append('runtime.rollout.custom_claims must be empty or a JSON object string') %}
{% endif %}
{% set internal_services_enabled = managed.get('internal_services_enabled') if 'internal_services_enabled' in managed else cc.get('internal_services_enabled', False) %}
{% set managed_runtime_enabled = managed.get('enabled', cc.get('managed_runtime_enabled', True)) %}
{% set internal_services_auto_update = managed.get('internal_services_auto_update', cc.get('internal_services_auto_update', False)) %}
{% set boolean_settings = {
  'install_packages': install_packages,
  'reload_systemd': reload_systemd,
  'run_bootstrap': run_bootstrap,
  'force_bootstrap': force_bootstrap,
  'managed_runtime.enabled': managed_runtime_enabled,
  'managed_runtime.internal_services_auto_update': internal_services_auto_update,
  'vault.agent_enabled': vault.get('agent_enabled', False)
} %}
{% for setting_name, setting_value in boolean_settings.items() %}
{% if setting_value is not boolean %}
{% set ignored = invalid_runtime_inputs.append(setting_name ~ ' must be a boolean') %}
{% endif %}
{% endfor %}
{% if internal_services_enabled is not boolean %}
{% set ignored = invalid_runtime_inputs.append('managed_runtime.internal_services_enabled must be a boolean') %}
{% elif internal_services_enabled %}
{% set ignored = invalid_runtime_inputs.append('the privileged internal-services stack is GCP-specific and is not supported by the on-prem Salt adapter; set managed_runtime.internal_services_enabled=false') %}
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
  'sitectl config set-context "${SITECTL_CONTEXT_NAME}" --type local --project-dir "${DOCKER_COMPOSE_DIR}" --site "${CLOUD_COMPOSE_INSTANCE_NAME}" --plugin "${SITECTL_PLUGIN}" --environment "${SITECTL_ENVIRONMENT}" --compose-project-name "${COMPOSE_PROJECT_NAME}" --docker-socket /var/run/docker.sock --env-file .env --yolo --default'
] %}
{% set default_up = [
  'sitectl compose --context "${SITECTL_CONTEXT_NAME}" up -d --remove-orphans',
  'sitectl healthcheck --context "${SITECTL_CONTEXT_NAME}" --persist',
  'if [ "${SITECTL_ENVIRONMENT}" != "production" ]; then sitectl verify --context "${SITECTL_CONTEXT_NAME}" ${SITECTL_VERIFY_ARGS:-}; fi'
] %}
{% set default_down = [
  'sitectl compose --context "${SITECTL_CONTEXT_NAME}" down'
] %}
{% set default_rollout = [
  'TARGET_REF="${GIT_REF:-${GIT_BRANCH:-}}"',
  'if [ -n "$TARGET_REF" ]; then sitectl deploy --context "${SITECTL_CONTEXT_NAME}" --ref "$TARGET_REF"; else sitectl deploy --context "${SITECTL_CONTEXT_NAME}" --skip-git; fi',
  'sitectl healthcheck --context "${SITECTL_CONTEXT_NAME}" --persist',
  'if [ "${SITECTL_ENVIRONMENT}" != "production" ]; then sitectl verify --context "${SITECTL_CONTEXT_NAME}" ${SITECTL_VERIFY_ARGS:-}; fi'
] %}
{% set lifecycle_defaults = {
  'init': default_init,
  'up': default_up,
  'down': default_down,
  'rollout': default_rollout
} %}
{% set lifecycle_commands = {} %}
{% for lifecycle, default_commands in lifecycle_defaults.items() %}
{% set configured_commands = compose.get(lifecycle) %}
{% set resolved_commands = configured_commands if lifecycle in compose else default_commands %}
{% if resolved_commands is string or resolved_commands is mapping or resolved_commands is not sequence %}
{% set ignored = invalid_runtime_inputs.append('compose.' ~ lifecycle ~ ' must be a list of strings') %}
{% set resolved_commands = [] %}
{% else %}
{% for command in resolved_commands %}
{% if command is not string %}
{% set ignored = invalid_runtime_inputs.append('compose.' ~ lifecycle ~ ' must be a list of strings') %}
{% endif %}
{% endfor %}
{% endif %}
{% set ignored = lifecycle_commands.update({lifecycle: resolved_commands}) %}
{% endfor %}
{% set repo = compose.get('repo') or template.repo %}
{% set branch = compose.get('branch') or template.branch %}
{% if repo is not string %}
{% set ignored = invalid_runtime_inputs.append('compose.repo must be a string') %}
{% set repo = '' %}
{% endif %}
{% if branch is not string %}
{% set ignored = invalid_runtime_inputs.append('compose.branch must be a string') %}
{% set branch = 'main' %}
{% endif %}
{% set ingress_port = compose.get('ingress_port', 80) %}
{% if ingress_port is boolean or ingress_port is not number or ingress_port < 1 or ingress_port > 65535 or ingress_port != (ingress_port | int) %}
{% set ignored = invalid_runtime_inputs.append('compose.ingress_port must be a whole number between 1 and 65535') %}
{% set ingress_port = 80 %}
{% endif %}
{% set raw_ingress = compose.get('ingress', {}) %}
{% if raw_ingress is mapping %}
{% set ingress_overrides = raw_ingress %}
{% else %}
{% set ingress_overrides = {} %}
{% set ignored = invalid_runtime_inputs.append('compose.ingress must be a map') %}
{% endif %}
{% set ingress = default_ingress.copy() %}
{% set ignored = ingress.update(ingress_overrides) %}
{% set raw_sitectl_packages = sitectl.get('packages') if 'packages' in sitectl else template.packages %}
{% if raw_sitectl_packages is string or raw_sitectl_packages is mapping or raw_sitectl_packages is not sequence %}
{% set ignored = invalid_runtime_inputs.append('sitectl.packages must be a list') %}
{% set sitectl_packages = template.packages %}
{% else %}
{% set sitectl_packages = raw_sitectl_packages %}
{% endif %}
{% if 'sitectl' not in sitectl_packages %}
{% set sitectl_packages = ['sitectl'] + sitectl_packages %}
{% endif %}
{% set sitectl_version = sitectl.get('version', cc.get('sitectl_version', 'latest')) %}
{% set raw_sitectl_package_version_overrides = sitectl.get('package_versions', cc.get('sitectl_package_versions', {})) %}
{% set invalid_sitectl_version_inputs = [] %}
{% if raw_sitectl_package_version_overrides is mapping %}
{% set sitectl_package_version_overrides = raw_sitectl_package_version_overrides %}
{% else %}
{% set sitectl_package_version_overrides = {} %}
{% set ignored = invalid_sitectl_version_inputs.append('sitectl.package_versions must be a map') %}
{% endif %}
{% if sitectl_version is not string or not (sitectl_version == 'latest' or sitectl_version is match('^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$')) %}
{% set ignored = invalid_sitectl_version_inputs.append('sitectl.version must be latest or an exact semantic-version release tag') %}
{% endif %}
{% for package, version in sitectl_package_version_overrides.items() %}
{% if package is not string or not (package is match('^sitectl(-[a-z0-9]+)*$')) %}
{% set ignored = invalid_sitectl_version_inputs.append('invalid package_versions key: ' ~ (package | string)) %}
{% endif %}
{% if version is not string or not (version == 'latest' or version is match('^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$')) %}
{% set ignored = invalid_sitectl_version_inputs.append('invalid package_versions value for ' ~ (package | string)) %}
{% endif %}
{% endfor %}
{% set repo_path_source = repo | replace('https://github.com/', '') | replace('http://github.com/', '') | replace('git@github.com:', '') %}
{% set repo_path = compose.get('repo_path') or (repo_path_source.strip('/') if repo_path_source else name) %}
{% set project_dir = compose.get('project_dir') or data_dir ~ '/' ~ repo_path ~ '/' ~ name %}
{% set compose_project_name = compose.get('compose_project_name') or normalize_compose_project_name(repo_path, branch) %}
{% set raw_explicit_projects = compose.get('projects', {}) %}
{% if raw_explicit_projects is mapping %}
{% set explicit_projects = raw_explicit_projects %}
{% else %}
{% set explicit_projects = {} %}
{% set ignored = invalid_runtime_inputs.append('compose.projects must be a map') %}
{% endif %}
{% set normalized_projects = {} %}
{% if explicit_projects %}
{% for app_name, app in explicit_projects.items() %}
{% set app_name_valid = app_name is string and app_name is match('^[a-z][a-z0-9-]*$') %}
{% if not app_name_valid %}
{% set ignored = invalid_runtime_inputs.append('compose.projects key must match ^[a-z][a-z0-9-]*$: ' ~ (app_name | string)) %}
{% endif %}
{% if app is not mapping %}
{% set ignored = invalid_runtime_inputs.append('compose.projects entry must be a map: ' ~ (app_name | string)) %}
{% elif app_name_valid %}
{% set app_repo = app.get('docker_compose_repo') or app.get('repo') or '' %}
{% set app_branch = app.get('docker_compose_branch') or app.get('branch') or branch %}
{% if app_repo is not string or not (app_repo | trim) %}
{% set ignored = invalid_runtime_inputs.append('docker_compose_repo is required and must be a string for project: ' ~ (app_name | string)) %}
{% set app_repo = '' %}
{% endif %}
{% if app_branch is not string %}
{% set ignored = invalid_runtime_inputs.append('docker_compose_branch must be a string for project: ' ~ (app_name | string)) %}
{% set app_branch = branch %}
{% endif %}
{% set app_repo_path_source = app_repo | replace('https://github.com/', '') | replace('http://github.com/', '') | replace('git@github.com:', '') %}
{% set app_repo_path = app.get('repo_path') or (app_repo_path_source.strip('/') if app_repo_path_source else app_name) %}
{% set raw_app_ingress = app.get('ingress', {}) %}
{% if raw_app_ingress is mapping %}
{% set app_ingress_overrides = raw_app_ingress %}
{% else %}
{% set app_ingress_overrides = {} %}
{% set ignored = invalid_runtime_inputs.append('ingress must be a map for project: ' ~ app_name) %}
{% endif %}
{% set app_ingress = ingress.copy() %}
{% set ignored = app_ingress.update(app_ingress_overrides) %}
{% set app_packages = app.get('sitectl_packages', sitectl_packages) %}
{% if app_packages is string or app_packages is mapping or app_packages is not sequence %}
{% set ignored = invalid_runtime_inputs.append('sitectl_packages must be a list for project: ' ~ (app_name | string)) %}
{% set app_packages = sitectl_packages %}
{% endif %}
{% if 'sitectl' not in app_packages %}
{% set app_packages = ['sitectl'] + app_packages %}
{% endif %}
{% set app_ingress_port = app.get('ingress_port', ingress_port) %}
{% if app_ingress_port is boolean or app_ingress_port is not number or app_ingress_port < 1 or app_ingress_port > 65535 or app_ingress_port != (app_ingress_port | int) %}
{% set ignored = invalid_runtime_inputs.append('ingress_port must be a whole number between 1 and 65535 for project: ' ~ (app_name | string)) %}
{% set app_ingress_port = ingress_port %}
{% endif %}
{% set app_lifecycle_commands = {} %}
{% for lifecycle in ['init', 'up', 'down', 'rollout'] %}
{% set legacy_key = lifecycle ~ '_commands' %}
{% set docker_key = 'docker_compose_' ~ lifecycle %}
{% if legacy_key in app %}
{% set resolved_commands = app.get(legacy_key) %}
{% elif docker_key in app %}
{% set resolved_commands = app.get(docker_key) %}
{% else %}
{% set resolved_commands = lifecycle_commands.get(lifecycle, []) %}
{% endif %}
{% if resolved_commands is string or resolved_commands is mapping or resolved_commands is not sequence %}
{% set ignored = invalid_runtime_inputs.append(legacy_key ~ ' or ' ~ docker_key ~ ' must be a list of strings for project: ' ~ (app_name | string)) %}
{% set resolved_commands = [] %}
{% else %}
{% for command in resolved_commands %}
{% if command is not string %}
{% set ignored = invalid_runtime_inputs.append(legacy_key ~ ' or ' ~ docker_key ~ ' must be a list of strings for project: ' ~ (app_name | string)) %}
{% endif %}
{% endfor %}
{% endif %}
{% set ignored = app_lifecycle_commands.update({lifecycle: resolved_commands}) %}
{% endfor %}
{% set app_project = {
  'name': app_name,
  'docker_compose_repo': app_repo,
  'docker_compose_branch': app_branch,
  'repo_path': app_repo_path,
  'project_dir': app.get('project_dir') or data_dir ~ '/' ~ app_repo_path ~ '/' ~ app_name,
  'compose_project_name': app.get('compose_project_name') or normalize_compose_project_name(app_repo_path, app_branch),
  'ingress_port': app_ingress_port,
  'ingress': app_ingress,
  'sitectl_context_name': app.get('sitectl_context_name', app_name),
  'sitectl_plugin': app.get('sitectl_plugin', sitectl.get('plugin', template.plugin)),
  'sitectl_environment': app.get('sitectl_environment', sitectl.get('environment', 'production')),
  'sitectl_packages': app_packages,
  'sitectl_verify_args': app.get('sitectl_verify_args', sitectl.get('verify_args', [])),
  'init_commands': app_lifecycle_commands.get('init', []),
  'up_commands': app_lifecycle_commands.get('up', []),
  'down_commands': app_lifecycle_commands.get('down', []),
  'rollout_commands': app_lifecycle_commands.get('rollout', [])
} %}
{% set ignored = normalized_projects.update({app_name: app_project}) %}
{% endif %}
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
  'init_commands': lifecycle_commands.get('init', []),
  'up_commands': lifecycle_commands.get('up', []),
  'down_commands': lifecycle_commands.get('down', []),
  'rollout_commands': lifecycle_commands.get('rollout', [])
} %}
{% set ignored = normalized_projects.update({name: single_project}) %}
{% endif %}
{% set compose_projects = normalized_projects %}
{% set raw_primary_key = compose.get('primary', '') %}
{% if raw_primary_key is not string %}
{% set ignored = invalid_runtime_inputs.append('compose.primary must be a string') %}
{% set raw_primary_key = '' %}
{% endif %}
{% set project_keys = compose_projects.keys() | list | sort %}
{% set primary_key = raw_primary_key or ((project_keys | first) if project_keys else '') %}
{% if not primary_key or primary_key not in compose_projects %}
{% set ignored = invalid_runtime_inputs.append('compose.primary must match a compose.projects key') %}
{% endif %}
{% set primary_project = compose_projects.get(primary_key, {}) %}
{% set ingress_ports = [] %}
{% for project in compose_projects.values() %}
{% set ignored = ingress_ports.append(project.get('ingress_port')) %}
{% endfor %}
{% if ingress_ports | unique | list | length != ingress_ports | length %}
{% set ignored = invalid_runtime_inputs.append('Compose project ingress ports must be unique on a shared host') %}
{% endif %}
{% set all_packages = sitectl_packages | list %}
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
{% for package in all_packages %}
{% if package is not string or not (package is match('^sitectl(-[a-z0-9]+)*$')) %}
{% set ignored = invalid_sitectl_version_inputs.append('invalid installed package: ' ~ (package | string)) %}
{% endif %}
{% endfor %}
{% for package in sitectl_package_version_overrides.keys() %}
{% if package not in all_packages %}
{% set ignored = invalid_sitectl_version_inputs.append('package_versions selects an uninstalled package: ' ~ package) %}
{% endif %}
{% endfor %}
{% set sitectl_package_versions = {} %}
{% for package in all_packages %}
{% set ignored = sitectl_package_versions.update({package: sitectl_package_version_overrides.get(package, template_sitectl_package_versions.get(package, sitectl_version))}) %}
{% endfor %}
{% set vault_addr = vault.get('addr', '') %}
{% set env = {
  'HOME': home,
  'CLOUD_COMPOSE_PROVIDER': provider,
  'CLOUD_COMPOSE_INSTANCE_NAME': name,
  'CLOUD_COMPOSE_APPS': compose_projects.keys() | list | join(' '),
  'CLOUD_COMPOSE_PRIMARY_APP': primary_key,
  'CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED': 'true' if offhost_backup_required is sameas true else 'false',
  'CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER': offhost_backup_driver,
  'COMPOSE_PROJECTS_FILE': home ~ '/compose-projects.json',
  'COMPOSE_PROJECT_NAME': primary_project.get('compose_project_name', compose_project_name),
  'COMPOSE_BIND_PORT': primary_project.get('ingress_port', ingress_port),
  'DOCKER_COMPOSE_DIR': primary_project.get('project_dir', project_dir),
  'DOCKER_COMPOSE_REPO': primary_project.get('docker_compose_repo', repo),
  'DOCKER_COMPOSE_BRANCH': primary_project.get('docker_compose_branch', branch),
  'DOCKER_COMPOSE_VERSION': docker.get('compose_version', cc.get('docker_compose_version', 'v5.3.1')),
  'DOCKER_BUILDX_VERSION': docker.get('buildx_version', cc.get('docker_buildx_version', 'v0.35.0')),
  'GCP_PROJECT': '',
  'GCP_PROJECT_NUMBER': '',
  'GCP_INSTANCE_NAME': name,
  'GCP_REGION': '',
  'GCP_ZONE': '',
  'GCP_APP_SERVICE_ACCOUNT_EMAIL': '',
  'SITECTL_PACKAGES': all_packages | join(' '),
  'SITECTL_VERSION': sitectl_version,
  'SITECTL_PACKAGE_VERSIONS': sitectl_package_versions | tojson,
  'SITECTL_CONTEXT_NAME': primary_project.get('sitectl_context_name', name),
  'SITECTL_PLUGIN': primary_project.get('sitectl_plugin', sitectl.get('plugin', template.plugin)),
  'SITECTL_ENVIRONMENT': primary_project.get('sitectl_environment', sitectl.get('environment', 'production')),
  'SITECTL_VERIFY_ARGS': primary_project.get('sitectl_verify_args', []) | join(' '),
  'POWER_MANAGEMENT_ENABLED': 'false',
  'COMPOSE_PROFILES': '',
  'VAULT_ADDR': vault_addr,
  'VAULT_NAMESPACE': vault.get('namespace', ''),
  'VAULT_ROLE': vault.get('role', ''),
  'VAULT_AGENT_ENABLED': 'true' if vault.get('agent_enabled', False) and vault_addr else 'false',
  'VAULT_AUTH_METHOD': vault.get('auth_method', 'consumer-managed'),
  'VAULT_AGENT_TOKEN_PATH': vault.get('agent_token_path', '/mnt/disks/data/vault/token'),
  'LIBOPS_MANAGED_RUNTIME_ENABLED': 'true' if managed_runtime_enabled else 'false',
  'LIBOPS_INTERNAL_SERVICES_ENABLED': 'true' if internal_services_enabled else 'false',
  'LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE': 'true' if internal_services_auto_update else 'false',
  'INTERNAL_SERVICES_COMPOSE_PROFILES': ''
  ,'ROLLOUT_ENABLED': 'true' if rollout_enabled is sameas true else 'false'
  ,'ROLLOUT_DOWNLOAD_URL': rollout_service.get('release_url', '')
  ,'ROLLOUT_DOWNLOAD_SHA256': rollout_service.get('release_sha256', '')
  ,'ROLLOUT_PORT': rollout_port
  ,'ROLLOUT_JWKS_URI': rollout_service.get('jwks_uri', '')
  ,'ROLLOUT_JWT_AUD': rollout_service.get('jwt_audience', '')
  ,'ROLLOUT_CUSTOM_CLAIMS': rollout_service.get('custom_claims', '')
} %}
{% set managed_artifacts = managed.get('artifacts', cc.get('managed_artifacts', [])) %}
{% set validation_payload = {'projects': compose_projects.values() | list, 'artifacts': managed_artifacts} %}
{% set validation_payload_b64 = salt['hashutil.base64_b64encode'](validation_payload | json) %}
{% set managed_artifacts_json_b64 = salt['hashutil.base64_b64encode'](managed_artifacts | json) %}
{% set runtime_validator_path = salt['cp.cache_file']('salt://cloud-compose/files/validate-runtime-inputs.py') %}
{% if not runtime_validator_path %}
{% set ignored = invalid_runtime_inputs.append('could not cache the cloud-compose host input validator') %}
{% endif %}

cloud-compose-runtime-inputs-valid:
{% if invalid_runtime_inputs %}
  test.fail_without_changes:
    - name: {{ ('Invalid cloud_compose runtime settings: ' ~ (invalid_runtime_inputs | join(', '))) | json }}
    - failhard: True
    - order: 1
{% else %}
  test.nop:
    - name: cloud-compose runtime inputs are valid
    - order: 1
{% endif %}

cloud-compose-sitectl-inputs-valid:
{% if invalid_sitectl_version_inputs %}
  test.fail_without_changes:
    - name: {{ ('Invalid cloud_compose sitectl settings: ' ~ (invalid_sitectl_version_inputs | join(', '))) | json }}
    - failhard: True
    - order: 1
{% else %}
  test.nop:
    - name: cloud-compose sitectl inputs are valid
    - order: 1
{% endif %}

cloud-compose-host-inputs-valid:
  cmd.run:
    - name: /usr/bin/env python3 "$CLOUD_COMPOSE_RUNTIME_VALIDATOR"
    - env:
        CLOUD_COMPOSE_RUNTIME_VALIDATOR: {{ runtime_validator_path | json }}
        CLOUD_COMPOSE_VALIDATION_PAYLOAD_B64: {{ validation_payload_b64 | json }}
    - stateful: True
    - failhard: True
    - order: 2
    - require:
      - test: cloud-compose-runtime-inputs-valid
      - test: cloud-compose-sitectl-inputs-valid

{% if not explicit_projects and not repo %}
cloud-compose-requires-repo:
  test.fail_without_changes:
    - name: Set cloud_compose.template, cloud_compose.runtime.compose.repo, or cloud_compose.runtime.compose.projects.
    - failhard: True
    - order: 1
{% endif %}

{% if install_packages %}
cloud-compose-packages:
  pkg.installed:
    - pkgs:
      - ca-certificates
      - curl
      - docker.io
      - git
      - jq
      - make
      - openssl
    - require:
      - cmd: cloud-compose-host-inputs-valid

cloud-compose-docker:
  service.running:
    - name: docker
    - enable: True
    - require:
      - pkg: cloud-compose-packages
{% endif %}

cloud-compose-docker-group:
  group.present:
    - name: docker
    - require:
      - cmd: cloud-compose-host-inputs-valid

cloud-compose-group:
  group.present:
    - name: {{ group | json }}
    - require:
      - cmd: cloud-compose-host-inputs-valid

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
      - group: cloud-compose-docker-group
{% if install_packages %}
      - pkg: cloud-compose-packages
{% endif %}

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

{% if compose_projects %}
cloud-compose-project-dirs:
  file.directory:
    - names:
{% for project in compose_projects.values() %}
      - {{ project.get('project_dir') | json }}
{% endfor %}
    - user: {{ user | json }}
    - group: {{ group | json }}
    - mode: '0775'
    - makedirs: True
    - require:
      - user: cloud-compose-user
{% endif %}

cloud-compose-rootfs:
  file.recurse:
    - name: /
    - source: salt://rootfs
    - clean: False
    - include_empty: True
    - require:
      - user: cloud-compose-user

cloud-compose-privileged-program-directories:
  file.directory:
    - names:
      - /etc/cloud-compose
      - /etc/cloud-compose/bin
      - /etc/cloud-compose/jq
      - /etc/cloud-compose/libexec
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: cloud-compose-rootfs

cloud-compose-lifecycle-lock:
  cmd.run:
    - name: systemd-tmpfiles --create /etc/tmpfiles.d/cloud-compose.conf
    - unless: >-
        test ! -L /run/lock/cloud-compose &&
        test -d /run/lock/cloud-compose &&
        test "$(stat -c '%U:%G:%a' /run/lock/cloud-compose)" = root:cloud-compose:750 &&
        test ! -L /run/lock/cloud-compose/lifecycle.lock &&
        test -f /run/lock/cloud-compose/lifecycle.lock &&
        test "$(stat -c '%U:%G:%a' /run/lock/cloud-compose/lifecycle.lock)" = root:cloud-compose:660
    - require:
      - file: cloud-compose-rootfs

cloud-compose-rootfs-script-modes:
  cmd.run:
    - name: find /home/cloud-compose /etc/cloud-compose/bin /etc/cloud-compose/libexec -maxdepth 1 -type f -name '*.sh' -exec chown root:root {} + -exec chmod 0755 {} +
    - unless: test -z "$(find /home/cloud-compose /etc/cloud-compose/bin /etc/cloud-compose/libexec -maxdepth 1 -type f -name '*.sh' \( ! -user root -o ! -group root -o ! -perm 0755 \) -print -quit)"
    - require:
      - file: cloud-compose-rootfs
      - file: cloud-compose-privileged-program-directories

cloud-compose-rootfs-jq-modes:
  cmd.run:
    - name: find /etc/cloud-compose/jq -maxdepth 1 -type f -name '*.jq' -exec chown root:root {} + -exec chmod 0644 {} +
    - unless: test -z "$(find /etc/cloud-compose/jq -maxdepth 1 -type f -name '*.jq' \( ! -user root -o ! -group root -o ! -perm 0644 \) -print -quit)"
    - require:
      - file: cloud-compose-rootfs
      - file: cloud-compose-privileged-program-directories

{% for lifecycle in ['init', 'up', 'down', 'rollout'] %}
cloud-compose-lifecycle-{{ lifecycle }}:
  file.managed:
    - name: {{ (home ~ '/' ~ lifecycle) | json }}
    - user: root
    - group: {{ group | json }}
    - mode: '0750'
    - contents: |
        #!/usr/bin/env bash

        set -eou pipefail

        source /home/cloud-compose/profile.sh
        exec bash /home/cloud-compose/compose-dispatch.sh "{{ lifecycle }}"
    - require:
      - file: cloud-compose-rootfs
{% endfor %}

cloud-compose-env:
  file.managed:
    - name: {{ (home ~ '/.env') | json }}
    - source: salt://cloud-compose/files/env.jinja
    - template: jinja
    - user: root
    - group: {{ group | json }}
    - mode: '0640'
    - show_changes: False
    - context:
        env: {{ env | json }}
    - require:
      - test: cloud-compose-runtime-inputs-valid
      - file: cloud-compose-rootfs

cloud-compose-application-env:
  file.managed:
    - name: {{ (home ~ '/application-env.json') | json }}
    - source: salt://cloud-compose/files/application-env.json.jinja
    - template: jinja
    - user: root
    - group: {{ group | json }}
    - mode: '0640'
    - show_changes: False
    - context:
        application_env: {{ safe_extra_env | json }}
    - require:
      - test: cloud-compose-runtime-inputs-valid
      - file: cloud-compose-rootfs

cloud-compose-project-manifest:
  file.managed:
    - name: {{ (home ~ '/compose-projects.json') | json }}
    - source: salt://cloud-compose/files/compose-projects.json.jinja
    - template: jinja
    - user: root
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
    - user: root
    - group: {{ group | json }}
    - mode: '0640'
    - show_changes: False
    - context:
        managed_artifacts_json_b64: {{ managed_artifacts_json_b64 | json }}
    - require:
      - file: cloud-compose-rootfs

{% if run_bootstrap is sameas true %}
cloud-compose-bootstrap-paths-hardened:
  cmd.run:
    - name: /etc/cloud-compose/libexec/harden-bootstrap-paths.sh
    - require:
      - file: cloud-compose-env
      - file: cloud-compose-application-env
      - file: cloud-compose-project-manifest
      - file: cloud-compose-managed-runtime-artifacts
      - cmd: cloud-compose-rootfs-script-modes
      - cmd: cloud-compose-rootfs-jq-modes
{% for lifecycle in ['init', 'up', 'down', 'rollout'] %}
      - file: cloud-compose-lifecycle-{{ lifecycle }}
{% endfor %}
{% endif %}

{% if reload_systemd %}
cloud-compose-systemd-reload:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: cloud-compose-rootfs
{% endif %}

{% if rollout_enabled is sameas true %}
cloud-compose-rollout-service:
  cmd.run:
    - name: bash /etc/cloud-compose/libexec/run-root-program.sh deploy-rollout.sh
    - require:
      - file: cloud-compose-env
      - file: cloud-compose-application-env
      - file: cloud-compose-project-manifest
      - file: cloud-compose-managed-runtime-artifacts
      - file: cloud-compose-rootfs
      - cmd: cloud-compose-lifecycle-lock
      - cmd: cloud-compose-rootfs-script-modes
      - file: cloud-compose-lifecycle-init
      - file: cloud-compose-lifecycle-up
      - file: cloud-compose-lifecycle-down
      - file: cloud-compose-lifecycle-rollout
{% if reload_systemd %}
      - module: cloud-compose-systemd-reload
{% endif %}
{% endif %}

{% if force_bootstrap is sameas true %}
cloud-compose-clear-bootstrap-marker:
  file.absent:
    - name: /var/lib/cloud-compose/bootstrap-complete
    - require:
      - cmd: cloud-compose-host-inputs-valid
{% endif %}

{% if run_bootstrap is sameas true %}
cloud-compose-bootstrap:
  cmd.run:
    - name: bash /etc/cloud-compose/libexec/start-cloud-compose-bootstrap.sh
    - unless: bash /etc/cloud-compose/libexec/require-bootstrap-ready.sh
    - require:
{% if install_packages %}
      - service: cloud-compose-docker
{% endif %}
      - file: cloud-compose-env
      - file: cloud-compose-application-env
      - file: cloud-compose-project-manifest
      - file: cloud-compose-managed-runtime-artifacts
      - cmd: cloud-compose-rootfs-script-modes
      - cmd: cloud-compose-rootfs-jq-modes
      - cmd: cloud-compose-bootstrap-paths-hardened
{% for lifecycle in ['init', 'up', 'down', 'rollout'] %}
      - file: cloud-compose-lifecycle-{{ lifecycle }}
{% endfor %}
{% if force_bootstrap is sameas true %}
      - file: cloud-compose-clear-bootstrap-marker
{% endif %}
{% if compose_projects %}
      - file: cloud-compose-project-dirs
{% endif %}
{% endif %}
