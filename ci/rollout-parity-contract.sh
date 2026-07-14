#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import ast
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

expected_rollout = [
    'TARGET_REF="${GIT_REF:-${GIT_BRANCH:-}}"',
    'if [ -n "$TARGET_REF" ]; then sitectl deploy --context "${SITECTL_CONTEXT_NAME}" --ref "$TARGET_REF"; else sitectl deploy --context "${SITECTL_CONTEXT_NAME}" --skip-git; fi',
    'sitectl healthcheck --context "${SITECTL_CONTEXT_NAME}" --persist',
    'if [ "${SITECTL_ENVIRONMENT}" != "production" ]; then sitectl verify --context "${SITECTL_CONTEXT_NAME}" ${SITECTL_VERIFY_ARGS:-}; fi',
]


def fail(message):
    raise SystemExit(f"rollout parity contract: {message}")


def require_match(pattern, text, label, flags=0):
    match = re.search(pattern, text, flags)
    if match is None:
        fail(f"could not find {label}")
    return match


def parse_hcl_rollout(path, pattern, label):
    text = path.read_text()
    block = require_match(pattern, text, label, re.MULTILINE | re.DOTALL).group("items")
    commands = []
    for raw_line in block.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.endswith(","):
            line = line[:-1]
        try:
            command = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"could not parse {label} command {line!r}: {exc}")
        commands.append(command.replace("$${", "${"))
    return commands


def parse_ansible_rollout(path):
    text = path.read_text()
    block = require_match(
        r"^cloud_compose_default_rollout:\n(?P<items>(?:^  - .*\n)+)",
        text,
        "Ansible default rollout list",
        re.MULTILINE,
    ).group("items")
    commands = []
    for raw_line in block.splitlines():
        match = re.fullmatch(r"  - '(.*)'", raw_line)
        if match is None:
            fail(f"could not parse Ansible rollout command {raw_line!r}")
        commands.append(match.group(1))
    return commands


def parse_salt_rollout(path):
    text = path.read_text()
    block = require_match(
        r"^\{% set default_rollout = \[\n(?P<items>.*?)^\] %\}",
        text,
        "Salt default rollout list",
        re.MULTILINE | re.DOTALL,
    ).group("items")
    commands = []
    for raw_line in block.splitlines():
        line = raw_line.strip().removesuffix(",")
        if not line:
            continue
        try:
            command = ast.literal_eval(line)
        except (SyntaxError, ValueError) as exc:
            fail(f"could not parse Salt rollout command {line!r}: {exc}")
        if not isinstance(command, str):
            fail(f"Salt rollout entry is not a string: {line!r}")
        commands.append(command)
    return commands


rollout_sources = {
    "GCP Terraform": (
        root / "modules/gcp/variables.tf",
        parse_hcl_rollout(
            root / "modules/gcp/variables.tf",
            r'^variable "docker_compose_rollout" \{.*?^  default = \[\n(?P<items>.*?)^  \]\n',
            "GCP Terraform default rollout list",
        ),
    ),
    "Linux VM Terraform": (
        root / "modules/linux-vm-runtime/variables.tf",
        parse_hcl_rollout(
            root / "modules/linux-vm-runtime/variables.tf",
            r'^variable "docker_compose_rollout" \{.*?^  default = \[\n(?P<items>.*?)^  \]\n',
            "Linux VM Terraform default rollout list",
        ),
    ),
    "Ansible": (
        root / "ansible/roles/cloud_compose/defaults/main.yml",
        parse_ansible_rollout(root / "ansible/roles/cloud_compose/defaults/main.yml"),
    ),
    "Salt": (
        root / "salt/cloud-compose/init.sls",
        parse_salt_rollout(root / "salt/cloud-compose/init.sls"),
    ),
    "rollout documentation": (
        root / "docs/rollout.md",
        parse_hcl_rollout(
            root / "docs/rollout.md",
            r"^      rollout = \[\n(?P<items>.*?)^      \]\n",
            "documented rollout list",
        ),
    ),
}

for label, (path, commands) in rollout_sources.items():
    if commands != expected_rollout:
        fail(
            f"{label} rollout list in {path.relative_to(root)} diverged:\n"
            f"expected {json.dumps(expected_rollout, indent=2)}\n"
            f"actual   {json.dumps(commands, indent=2)}"
        )

legacy_rollout_script = "scripts/" + "rollout.sh"
for label, (path, _) in rollout_sources.items():
    if legacy_rollout_script in path.read_text():
        fail(f"{label} still delegates lifecycle ownership to {legacy_rollout_script}")

compose_versions = {}
version_patterns = {
    "root Terraform": (
        "variables.tf",
        r'compose_version\s*=\s*optional\(string,\s*"(?P<version>[^"]+)"\)',
    ),
    "GCP provider": (
        "providers/gcp/variables.tf",
        r'compose_version\s*=\s*optional\(string,\s*"(?P<version>[^"]+)"\)',
    ),
    "DigitalOcean provider": (
        "providers/do/variables.tf",
        r'compose_version\s*=\s*optional\(string,\s*"(?P<version>[^"]+)"\)',
    ),
    "Linode provider": (
        "providers/linode/variables.tf",
        r'compose_version\s*=\s*optional\(string,\s*"(?P<version>[^"]+)"\)',
    ),
    "DigitalOcean module": (
        "modules/digitalocean/variables.tf",
        r'compose_version\s*=\s*optional\(string,\s*"(?P<version>[^"]+)"\)',
    ),
    "Linode module": (
        "modules/linode/variables.tf",
        r'compose_version\s*=\s*optional\(string,\s*"(?P<version>[^"]+)"\)',
    ),
    "GCP module": (
        "modules/gcp/variables.tf",
        r'variable "docker_compose_version" \{.*?default\s*=\s*"(?P<version>[^"]+)"',
    ),
    "Linux VM module": (
        "modules/linux-vm-runtime/variables.tf",
        r'variable "docker_compose_version" \{.*?default\s*=\s*"(?P<version>[^"]+)"',
    ),
    "Ansible": (
        "ansible/roles/cloud_compose/defaults/main.yml",
        r'^cloud_compose_docker_compose_version:\s*(?P<version>\S+)\s*$',
    ),
    "Salt": (
        "salt/cloud-compose/init.sls",
        r"docker\.get\('compose_version',\s*cc\.get\('docker_compose_version',\s*'(?P<version>[^']+)'\)\)",
    ),
    "host installer fallback": (
        "rootfs/home/cloud-compose/install-docker-plugins.sh",
        r'DOCKER_COMPOSE_VERSION="\$\{DOCKER_COMPOSE_VERSION:-(?P<version>[^}]+)\}"',
    ),
}

for label, (relative_path, pattern) in version_patterns.items():
    path = root / relative_path
    version = require_match(
        pattern,
        path.read_text(),
        f"{label} Docker Compose default",
        re.MULTILINE | re.DOTALL,
    ).group("version")
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        fail(f"{label} has an invalid Docker Compose release tag: {version!r}")
    compose_versions[label] = version

if len(set(compose_versions.values())) != 1:
    fail(f"Docker Compose defaults diverged: {json.dumps(compose_versions, indent=2)}")

renovate = (root / "renovate.json5").read_text()
for marker in (
    "Update Docker Compose configuration-management defaults",
    "ansible/roles/cloud_compose/defaults/main",
    "salt/cloud-compose/init",
):
    if marker not in renovate:
        fail(f"Renovate configuration is missing configuration-management marker {marker!r}")

print("Rollout and Docker Compose adapter parity contracts passed")
PY
