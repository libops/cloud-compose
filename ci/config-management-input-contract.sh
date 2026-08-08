#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/ansible/roles/cloud_compose/files/validate-runtime-inputs.py"
salt_validator="$repo_root/salt/cloud-compose/files/validate-runtime-inputs.py"

cmp -s "$validator" "$salt_validator" || {
  echo "config-management input contract: Ansible and Salt validators diverged" >&2
  exit 1
}

python3 - "$repo_root" "$validator" <<'PY'
import base64
import copy
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

repo_root = Path(sys.argv[1])
validator = Path(sys.argv[2])


def fail(message):
    raise SystemExit(f"config-management input contract: {message}")


def snapshot(root):
    entries = []
    for path in sorted(root.rglob("*")):
        metadata = path.lstat()
        relative = str(path.relative_to(root))
        if path.is_symlink():
            payload = ("symlink", os.readlink(path))
        elif path.is_file():
            payload = ("file", path.read_bytes())
        else:
            payload = ("other", b"")
        entries.append(
            (
                relative,
                stat.S_IMODE(metadata.st_mode),
                metadata.st_uid,
                metadata.st_gid,
                payload,
            )
        )
    return entries


with tempfile.TemporaryDirectory(prefix="cloud-compose-input-contract.") as temp_dir:
    test_root = Path(temp_dir)
    data_root = test_root / "mnt" / "disks" / "data"
    outside = test_root / "outside"
    data_root.mkdir(parents=True)
    outside.mkdir()
    (outside / "sentinel").write_text("must-not-change\n")
    (data_root / "escape").symlink_to(outside, target_is_directory=True)

    safe_artifact = {
        "name": "rollout-agent",
        "url": "https://example.invalid/rollout-agent",
        "sha256": "a" * 64,
        "path": "/usr/local/bin/rollout-agent",
        "mode": "0750",
        "owner": "root",
        "group": "root",
        "restart": "cloud-compose-rollout.service",
    }
    safe_payload = {
        "projects": [{"name": "app", "project_dir": str(data_root / "app")}],
        "artifacts": [safe_artifact],
    }

    def run(payload):
        before = snapshot(test_root)
        environment = os.environ.copy()
        environment["CLOUD_COMPOSE_VALIDATION_PAYLOAD_B64"] = base64.b64encode(
            json.dumps(payload).encode("utf-8")
        ).decode("ascii")
        result = subprocess.run(
            [sys.executable, str(validator), "--data-root", str(data_root)],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        after = snapshot(test_root)
        if before != after:
            fail("validator mutated the host fixture")
        return result

    accepted = run(safe_payload)
    if accepted.returncode != 0:
        fail(f"safe payload was rejected: {accepted.stderr}")

    def reject(label, payload, expected):
        result = run(payload)
        if result.returncode == 0:
            fail(f"{label} was accepted")
        if expected not in result.stderr:
            fail(f"{label} did not report {expected!r}: {result.stderr}")

    invalid_project_paths = {
        "root project path": "/",
        "system project path": "/etc",
        "data root itself": str(data_root),
        "traversal project path": str(data_root / ".." / "outside"),
        "dot project segment": f"{data_root}/./app",
        "empty project segment": f"{data_root}//app",
        "control-character project segment": f"{data_root}/bad\x7fname",
        "symlink escape": str(data_root / "escape" / "app"),
    }
    for label, project_dir in invalid_project_paths.items():
        payload = copy.deepcopy(safe_payload)
        payload["projects"][0]["project_dir"] = project_dir
        reject(label, payload, "project_dir")

    duplicate_ports = copy.deepcopy(safe_payload)
    duplicate_ports["projects"] = [
        {"name": "alpha", "project_dir": str(data_root / "alpha"), "ingress_port": 8080},
        {"name": "beta", "project_dir": str(data_root / "beta"), "ingress_port": 8080},
    ]
    reject("duplicate project ports", duplicate_ports, "ingress ports must be unique")

    artifact_cases = []

    def artifact_case(label, field, value, expected):
        payload = copy.deepcopy(safe_payload)
        payload["artifacts"][0][field] = value
        artifact_cases.append((label, payload, expected))

    artifact_case("unsafe artifact name", "name", "../agent", "safe basename")
    artifact_case("overlong artifact name", "name", "a" * 129, "safe basename")
    artifact_case("non-HTTPS artifact URL", "url", "http://example.invalid/agent", "HTTPS URL")
    artifact_case("uppercase artifact SHA", "sha256", "A" * 64, "64 lowercase hex")
    artifact_case("root artifact path", "path", "/", "non-root absolute path")
    artifact_case("relative artifact path", "path", "usr/local/bin/agent", "non-root absolute path")
    artifact_case("dot artifact path", "path", "/usr/local/../bin/agent", "non-root absolute path")
    artifact_case("empty artifact segment", "path", "/usr//local/bin/agent", "non-root absolute path")
    artifact_case("control artifact segment", "path", "/usr/local/bad\x7fname", "non-root absolute path")
    artifact_case("unsafe artifact mode", "mode", "4755", "mode must match")
    artifact_case("unsafe artifact owner", "owner", "root:root", "owner must be")
    artifact_case("unsafe artifact group", "group", "root:root", "group must be")
    artifact_case("unsafe restart unit", "restart", "../docker.service", "safe .service")

    duplicate_name = copy.deepcopy(safe_payload)
    second = copy.deepcopy(safe_artifact)
    second["path"] = "/usr/local/bin/rollout-agent-two"
    duplicate_name["artifacts"].append(second)
    artifact_cases.append(("duplicate artifact name", duplicate_name, "names must be unique"))

    duplicate_path = copy.deepcopy(safe_payload)
    second = copy.deepcopy(safe_artifact)
    second["name"] = "rollout-agent-two"
    duplicate_path["artifacts"].append(second)
    artifact_cases.append(("duplicate artifact path", duplicate_path, "target paths must be unique"))

    for label, payload, expected in artifact_cases:
        reject(label, payload, expected)

ansible_tasks = (repo_root / "ansible/roles/cloud_compose/tasks/main.yml").read_text()
ansible_defaults = (repo_root / "ansible/roles/cloud_compose/defaults/main.yml").read_text()
ansible_gate = ansible_tasks.find("Validate project directory and managed artifact host boundaries")
ansible_first_mutation = ansible_tasks.find("Install Debian runtime dependencies")
if ansible_gate < 0 or ansible_first_mutation < 0 or ansible_gate > ansible_first_mutation:
    fail("Ansible host-input validation does not precede its first host mutation")
if "files/validate-runtime-inputs.py" not in ansible_tasks:
    fail("Ansible does not execute the shared host-input validator")
if "--data-root" in ansible_tasks:
    fail("Ansible makes the production project ownership boundary configurable")
if 'cmd: bash "{{ cloud_compose_home }}/start-cloud-compose-bootstrap.sh"' not in ansible_tasks:
    fail("Ansible bypasses the retryable bootstrap service")
if 'cmd: bash "{{ cloud_compose_home }}/run.sh"' in ansible_tasks:
    fail("Ansible still invokes the one-shot bootstrap script directly")
if "cloud_compose_bootstrap_timeout: 14400" not in ansible_defaults:
    fail("Ansible bootstrap timeout does not cover the bounded retryable bootstrap wait")

salt_state = (repo_root / "salt/cloud-compose/init.sls").read_text()
cloud_smoke_driver = (repo_root / "ci/config-management-cloud-smoke.sh").read_text()
cloud_smoke_inner = (repo_root / "ci/config-management-cloud-smoke-inner.sh").read_text()
salt_gate = salt_state.find("cloud-compose-host-inputs-valid:")
salt_first_mutation = salt_state.find("cloud-compose-packages:")
if salt_gate < 0 or salt_first_mutation < 0 or salt_gate > salt_first_mutation:
    fail("Salt host-input validation does not precede its first host mutation")
if "home ~ '/start-cloud-compose-bootstrap.sh'" not in salt_state:
    fail("Salt bypasses the retryable bootstrap service")
if "home ~ '/run.sh'" in salt_state:
    fail("Salt still invokes the one-shot bootstrap script directly")
gate_block = salt_state[salt_gate:salt_first_mutation]
for marker in (
    "cmd.run:",
    '/usr/bin/env python3 "$CLOUD_COMPOSE_RUNTIME_VALIDATOR"',
    "failhard: True",
    "order: 2",
):
    if marker not in gate_block:
        fail(f"Salt host-input validation gate is missing {marker!r}")
for state_name in ("cloud-compose-packages:", "cloud-compose-docker-group:", "cloud-compose-group:"):
    state_start = salt_state.find(state_name)
    state_end = salt_state.find("\n\n", state_start)
    if "cmd: cloud-compose-host-inputs-valid" not in salt_state[state_start:state_end]:
        fail(f"Salt mutating state {state_name} does not require host-input validation")

for marker in (
    "_cc_compose.init | default(cloud_compose_default_init)",
    "_cc_compose.up | default(cloud_compose_default_up)",
    "_cc_compose.down | default(cloud_compose_default_down)",
    "_cc_compose.rollout | default(cloud_compose_default_rollout)",
    "item.value.docker_compose_up | default(_cc_up_commands)",
):
    if marker not in ansible_tasks:
        fail(f"Ansible explicit-empty lifecycle parity marker is missing: {marker!r}")

for marker in (
    "_cc_template.package_versions | default({})",
    "_cc_template_sitectl_package_versions[item] | default(_cc_sitectl_version)",
    "_cc_sitectl_package_version_overrides[item] | default(",
    "_cc_sitectl.packages | default(_cc_template.packages)",
    "item.value.sitectl_packages | default(_cc_sitectl_packages)",
    "(_cc_managed.enabled | default(cloud_compose_managed_runtime_enabled)) is boolean",
    "(_cc_vault.agent_enabled | default(false)) is boolean",
    "(_cc_disaster_recovery.required | default(false)) is boolean",
    "CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED",
    "CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER",
):
    if marker not in ansible_tasks:
        fail(f"Ansible template package-version parity marker is missing: {marker!r}")

for marker in (
    "configured_commands = compose.get(lifecycle)",
    "configured_commands if lifecycle in compose else default_commands",
    "if legacy_key in app",
    "elif docker_key in app",
):
    if marker not in salt_state:
        fail(f"Salt explicit-empty lifecycle parity marker is missing: {marker!r}")

for marker in (
    "template_sitectl_package_versions = template.get('package_versions', {})",
    "sitectl_package_version_overrides.get(package, template_sitectl_package_versions.get(package, sitectl_version))",
    "sitectl.get('packages') if 'packages' in sitectl else template.packages",
    "app.get('sitectl_packages', sitectl_packages)",
    "all_packages = sitectl_packages | list",
    "'managed_runtime.enabled': managed_runtime_enabled",
    "'vault.agent_enabled': vault.get('agent_enabled', False)",
    "runtime_sections.disaster_recovery",
    "CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED",
    "CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER",
    "run_bootstrap is sameas true",
):
    if marker not in salt_state:
        fail(f"Salt template package-version parity marker is missing: {marker!r}")

for marker in (
    'retry_remote_operation "Ansible deployment" deploy_ansible',
    'retry_remote_operation "Salt deployment" deploy_salt',
    'retry_remote_operation "Remote verification" verify_remote',
    '-o ServerAliveInterval=30',
    'for attempt in 1 2 3; do',
):
    if marker not in cloud_smoke_inner:
        fail(f"hosted adapter smoke retry contract is missing: {marker!r}")

for text in (cloud_smoke_driver, cloud_smoke_inner):
    if "SMOKE_SSH_KEY_B64" in text:
        fail("hosted adapter smoke exposes its SSH private key through the environment")
if 'type=bind,src=${key_path},dst=/run/secrets/cloud-compose-ssh-key,readonly' not in cloud_smoke_driver:
    fail("hosted adapter smoke does not mount its SSH private key read-only")
if 'git -C "$repo_root" archive --format=tar HEAD' not in cloud_smoke_driver:
    fail("hosted adapter smoke does not limit its source stream to committed files")
if 'tar \\\n    --exclude="./.git"' in cloud_smoke_driver:
    fail("hosted adapter smoke still archives the secret-bearing working tree")
for marker in (
    '[[ -L "$key_path" || ! -f "$key_path" ]]',
    'key_path="$(cd -P -- "$(dirname -- "$key_path")" && pwd)/$(basename -- "$key_path")"',
):
    if marker not in cloud_smoke_driver:
        fail(f"hosted adapter smoke key-source validation is missing: {marker!r}")
for marker in (
    'readonly smoke_ssh_key_mount="/run/secrets/cloud-compose-ssh-key"',
    'install -m 0600 "$smoke_ssh_key_mount" /tmp/cloud-compose-ssh/id_ed25519',
    '-i /tmp/cloud-compose-ssh/id_ed25519',
    'ansible_ssh_private_key_file: /tmp/cloud-compose-ssh/id_ed25519',
):
    if marker not in cloud_smoke_inner:
        fail(f"hosted adapter smoke key-file contract is missing: {marker!r}")

for label, text, owner_marker, mode_marker in (
    ("Ansible", ansible_tasks, "owner: root", 'mode: "0640"'),
    ("Salt", salt_state, "- user: root", "- mode: '0640'"),
):
    if text.count(owner_marker) < 4 or text.count(mode_marker) < 4:
        fail(f"{label} does not keep every root-consumed runtime input root-owned and mode 0640")

if "no_log: true" not in ansible_tasks[ansible_tasks.find("Write Compose application environment data"):]:
    fail("Ansible may expose application environment data in task output")
for state_name in ("cloud-compose-env:", "cloud-compose-application-env:", "cloud-compose-managed-runtime-artifacts:"):
    state_start = salt_state.find(state_name)
    state_end = salt_state.find("\n\n", state_start)
    if "- show_changes: False" not in salt_state[state_start:state_end]:
        fail(f"Salt sensitive state {state_name} may expose rendered data in state output")

terraform_artifacts = (repo_root / "modules/managed-artifacts/main.tf").read_text()
validator_source = validator.read_text()
if 'PRODUCTION_DATA_ROOT = "/mnt/disks/data"' not in validator_source:
    fail("configuration-management validator changed the fixed production data boundary")
if "--data-root" in salt_state:
    fail("Salt makes the production project ownership boundary configurable")
if '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' not in terraform_artifacts:
    fail("Terraform managed-artifact name bound changed without adapter parity")
if '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' not in validator_source:
    fail("configuration-management validator is missing the 128-character artifact name bound")

project_fixture_values = {
    "invalid-project-dir-root": "project_dir: /",
    "invalid-project-dir-etc": "project_dir: /etc",
    "invalid-project-dir-traversal": "project_dir: /mnt/disks/data/../escape",
    "invalid-project-dir-symlink": "project_dir: /mnt/disks/data/escape/site",
}
for fixture_name, marker in project_fixture_values.items():
    for relative_path in (
        f"tests/config-management/ansible/{fixture_name}.yml",
        f"tests/config-management/salt-pillar/{fixture_name}.sls",
    ):
        fixture = repo_root / relative_path
        if not fixture.is_file() or marker not in fixture.read_text():
            fail(f"project boundary fixture {relative_path} is missing {marker!r}")

artifact_fixture_markers = (
    "../unsafe-name",
    "a" * 129,
    "http://example.invalid/unsafe-url",
    "A" * 64,
    "path: /",
    "path: usr/local/bin/relative-path",
    "path: /usr/local/../bin/dot-path",
    "path: /usr//local/bin/empty-path-segment",
    "bad\\u007fname",
    'mode: "4755"',
    "owner: root:root",
    "group: root:root",
    "restart: ../docker.service",
    "name: duplicate-name",
    "path: /usr/local/bin/duplicate-path",
)
for relative_path in (
    "tests/config-management/ansible/invalid-artifacts.yml",
    "tests/config-management/salt-pillar/invalid-artifacts.sls",
):
    fixture_text = (repo_root / relative_path).read_text()
    for marker in artifact_fixture_markers:
        if marker not in fixture_text:
            fail(f"managed artifact fixture {relative_path} is missing {marker!r}")

adapter_fixture_markers = {
    "invalid-ingress-port": "ingress_port: 80.5",
    "invalid-project-port": "ingress_port: 443.5",
    "invalid-lifecycle": "- 42",
    "invalid-project-lifecycle": "docker_compose_up: not-a-list",
    "invalid-internal-services": "internal_services_enabled: true",
    "invalid-disaster-recovery": "driver_path: /usr/local/libexec/cloud-compose/../untrusted",
}
for fixture_name, marker in adapter_fixture_markers.items():
    for relative_path in (
        f"tests/config-management/ansible/{fixture_name}.yml",
        f"tests/config-management/salt-pillar/{fixture_name}.sls",
    ):
        fixture = repo_root / relative_path
        if not fixture.is_file() or marker not in fixture.read_text():
            fail(f"adapter parity fixture {relative_path} is missing {marker!r}")

for relative_path in (
    "tests/config-management/ansible/smoke.yml",
    "tests/config-management/salt-pillar/wp-prod.sls",
):
    fixture_text = (repo_root / relative_path).read_text()
    for marker in ("init: []", "docker_compose_up: []", "app-down-command"):
        if marker not in fixture_text:
            fail(f"explicit-empty lifecycle fixture {relative_path} is missing {marker!r}")

print("Configuration-management input contracts passed")
PY
