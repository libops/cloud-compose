#!/usr/bin/env python3

"""Assertions for the containerized Ansible and Salt smoke tests."""

import argparse
import grp
import json
import os
import stat
import subprocess
from pathlib import Path


RUNTIME_HOME = Path("/home/cloud-compose")
PRIVILEGED_PROGRAM_ROOT = Path("/etc/cloud-compose")
DIAGNOSTICS_PROGRAM = PRIVILEGED_PROGRAM_ROOT / "bin/cloud-compose-diagnostics.sh"
BOOTSTRAP_LIBEXEC = Path("/etc/cloud-compose/libexec")
JQ_PROGRAM_DIR = PRIVILEGED_PROGRAM_ROOT / "jq"


def load_runtime_env(path: Path) -> dict[str, str]:
    result = subprocess.run(
        [
            "env",
            "-i",
            "PATH=/usr/bin:/bin",
            f"CLOUD_COMPOSE_ENV_FILE={path}",
            "bash",
            "--noprofile",
            "--norc",
            "-c",
            "source /home/cloud-compose/profile.sh; env -0",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    return {
        entry.split(b"=", 1)[0].decode(): entry.split(b"=", 1)[1].decode()
        for entry in result.stdout.split(b"\0")
        if b"=" in entry
    }


def assert_runtime_files() -> None:
    for path in [
        RUNTIME_HOME / "init",
        RUNTIME_HOME / "up",
        RUNTIME_HOME / "down",
        RUNTIME_HOME / "rollout",
        RUNTIME_HOME / "run.sh",
        RUNTIME_HOME / "start-cloud-compose-bootstrap.sh",
        BOOTSTRAP_LIBEXEC / "bootstrap-required.sh",
        BOOTSTRAP_LIBEXEC / "bootstrap-security.sh",
        BOOTSTRAP_LIBEXEC / "run-bootstrap.sh",
        BOOTSTRAP_LIBEXEC / "require-bootstrap-ready.sh",
        BOOTSTRAP_LIBEXEC / "run-root-program.sh",
        BOOTSTRAP_LIBEXEC / "start-cloud-compose-bootstrap.sh",
        DIAGNOSTICS_PROGRAM,
    ]:
        assert path.exists(), path
        assert os.access(path, os.X_OK), path

    for path in [
        JQ_PROGRAM_DIR / "diagnostics-validate-compose-projects.jq",
        JQ_PROGRAM_DIR / "offhost-validate-manifest.jq",
    ]:
        assert path.exists(), path

    cloud_compose_gid = grp.getgrnam("cloud-compose").gr_gid
    for path, expected_mode in {
        RUNTIME_HOME / "init": 0o750,
        RUNTIME_HOME / "up": 0o750,
        RUNTIME_HOME / "down": 0o750,
        RUNTIME_HOME / "rollout": 0o750,
        RUNTIME_HOME / ".env": 0o640,
        RUNTIME_HOME / "application-env.json": 0o640,
        RUNTIME_HOME / "compose-projects.json": 0o640,
        RUNTIME_HOME / "managed-runtime-artifacts.tsv": 0o640,
    }.items():
        metadata = path.stat()
        assert metadata.st_uid == 0, (path, metadata.st_uid)
        assert metadata.st_gid == cloud_compose_gid, (path, metadata.st_gid)
        assert stat.S_IMODE(metadata.st_mode) == expected_mode, (
            path,
            oct(stat.S_IMODE(metadata.st_mode)),
        )

    for path in BOOTSTRAP_LIBEXEC.glob("*.sh"):
        metadata = path.stat()
        assert metadata.st_uid == 0, (path, metadata.st_uid)
        assert metadata.st_gid == 0, (path, metadata.st_gid)
        assert stat.S_IMODE(metadata.st_mode) == 0o755, (
            path,
            oct(stat.S_IMODE(metadata.st_mode)),
        )

    for path in [
        PRIVILEGED_PROGRAM_ROOT,
        DIAGNOSTICS_PROGRAM.parent,
        BOOTSTRAP_LIBEXEC,
        JQ_PROGRAM_DIR,
    ]:
        metadata = path.stat()
        assert metadata.st_uid == 0, (path, metadata.st_uid)
        assert metadata.st_gid == 0, (path, metadata.st_gid)
        assert stat.S_IMODE(metadata.st_mode) == 0o755, (
            path,
            oct(stat.S_IMODE(metadata.st_mode)),
        )

    diagnostics_metadata = DIAGNOSTICS_PROGRAM.stat()
    assert diagnostics_metadata.st_uid == 0
    assert diagnostics_metadata.st_gid == 0
    assert stat.S_IMODE(diagnostics_metadata.st_mode) == 0o755

    jq_programs = list(JQ_PROGRAM_DIR.glob("*.jq"))
    assert jq_programs
    for path in jq_programs:
        metadata = path.stat()
        assert metadata.st_uid == 0, (path, metadata.st_uid)
        assert metadata.st_gid == 0, (path, metadata.st_gid)
        assert stat.S_IMODE(metadata.st_mode) == 0o644, (
            path,
            oct(stat.S_IMODE(metadata.st_mode)),
        )


def assert_ansible_runtime() -> None:
    env = load_runtime_env(RUNTIME_HOME / ".env")
    application_env = json.loads(
        (RUNTIME_HOME / "application-env.json").read_text()
    )
    projects = json.loads((RUNTIME_HOME / "compose-projects.json").read_text())
    project = projects["isle-prod"]

    assert env["CLOUD_COMPOSE_PROVIDER"] == "onprem"
    assert env["CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED"] == "false"
    assert (
        env["CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER"]
        == "/etc/cloud-compose/libexec/ansible-offhost"
    )
    assert env["DOCKER_COMPOSE_DIR"] == "/mnt/disks/data/libops/isle/isle-prod"
    assert env["DOCKER_COMPOSE_REPO"] == "https://github.com/libops/isle"
    assert env["SITECTL_PLUGIN"] == "isle"
    assert "sitectl-isle" in env["SITECTL_PACKAGES"].split()
    assert json.loads(env["SITECTL_PACKAGE_VERSIONS"]) == {
        "sitectl": "v1.8.2",
        "sitectl-drupal": "v1.3.0",
        "sitectl-isle": "v1.5.0",
    }
    assert project["docker_compose_repo"] == "https://github.com/libops/isle"
    assert project["project_dir"] == "/mnt/disks/data/libops/isle/isle-prod"
    assert project["compose_project_name"] == "libops-isle-v1-3-0"
    assert project["ingress"]["domain"] == "isle.example.edu"
    assert project["sitectl_plugin"] == "isle"
    assert project["init_commands"] == []
    assert project["up_commands"] == []
    assert project["down_commands"] == ["app-down-command"]
    assert project["rollout_commands"] == ["global-rollout-command"]
    assert Path("/mnt/disks/data/libops/isle/isle-prod").is_dir()
    assert "BASH_ENV" not in env
    assert "LD_PRELOAD" not in env
    assert "PORT" not in env
    assert application_env["BASH_ENV"] == (
        "/tmp/cloud-compose-ansible-untrusted-bash-env"
    )
    assert application_env["LD_PRELOAD"] == (
        "/tmp/cloud-compose-ansible-untrusted-preload.so"
    )
    assert application_env["PORT"] == "9999"
    assert application_env["CONTRACT_BACKTICKS"] == (
        "`touch /tmp/cloud-compose-ansible-backtick-injection`"
    )
    assert application_env["CONTRACT_BACKSLASH"] == "a\\path\\ends\\"
    assert application_env["CONTRACT_COMMAND_SUB"] == (
        "$(touch /tmp/cloud-compose-ansible-command-injection)"
    )
    assert application_env["CONTRACT_DOLLARS"] == "$HOME ${HOME}"
    assert application_env["CONTRACT_QUOTES"] == (
        'a "double" and a single quote: O\'Reilly'
    )
    assert application_env["CONTRACT_WHITESPACE"] == "  leading and trailing  "
    assert application_env["CONTRACT_MULTILINE"] == "line one\nline two"
    assert not Path("/tmp/cloud-compose-ansible-backtick-injection").exists()
    assert not Path("/tmp/cloud-compose-ansible-command-injection").exists()

    assert_runtime_files()


def assert_salt_noop() -> None:
    states = json.loads(Path("/tmp/cloud-compose-salt-noop.json").read_text())[
        "local"
    ]
    lock_states = [
        state
        for state_id, state in states.items()
        if "|-cloud-compose-lifecycle-lock_|-" in state_id
    ]
    assert len(lock_states) == 1, lock_states
    assert lock_states[0]["result"] is True, lock_states[0]
    assert lock_states[0]["changes"] == {}, lock_states[0]


def assert_salt_runtime(
    expected_name: str,
    expected_repo: str,
    expected_plugin: str,
    expected_package: str,
    expected_domain: str,
    expected_project_dir: str,
    expected_compose_project_name: str,
) -> None:
    env = load_runtime_env(RUNTIME_HOME / ".env")
    application_env = json.loads(
        (RUNTIME_HOME / "application-env.json").read_text()
    )
    projects = json.loads((RUNTIME_HOME / "compose-projects.json").read_text())
    project = projects[expected_name]
    artifact_manifest = (RUNTIME_HOME / "managed-runtime-artifacts.tsv").read_text()

    assert env["CLOUD_COMPOSE_PROVIDER"] == "onprem"
    assert env["CLOUD_COMPOSE_APPS"] == expected_name
    assert env["CLOUD_COMPOSE_PRIMARY_APP"] == expected_name
    assert env["DOCKER_COMPOSE_DIR"] == expected_project_dir
    assert env["DOCKER_COMPOSE_REPO"] == expected_repo
    assert env["COMPOSE_PROJECT_NAME"] == expected_compose_project_name, (
        env["COMPOSE_PROJECT_NAME"],
        expected_compose_project_name,
    )
    assert env["SITECTL_PLUGIN"] == expected_plugin
    assert expected_package in env["SITECTL_PACKAGES"].split()
    assert project["docker_compose_repo"] == expected_repo
    assert project["project_dir"] == expected_project_dir
    assert project["compose_project_name"] == expected_compose_project_name, (
        project["compose_project_name"],
        expected_compose_project_name,
    )
    assert project["sitectl_plugin"] == expected_plugin
    assert project["ingress"]["domain"] == expected_domain
    assert Path(expected_project_dir).is_dir()

    if expected_name == "wp-prod":
        assert env["CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED"] == "false"
        assert (
            env["CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER"]
            == "/etc/cloud-compose/libexec/salt-offhost"
        )
        assert json.loads(env["SITECTL_PACKAGE_VERSIONS"]) == {
            "sitectl": "v1.8.2",
            "sitectl-wp": "v2.0.0",
        }
        assert "BASH_ENV" not in env
        assert "LD_PRELOAD" not in env
        assert "PORT" not in env
        assert application_env["BASH_ENV"] == (
            "/tmp/cloud-compose-salt-untrusted-bash-env"
        )
        assert application_env["LD_PRELOAD"] == (
            "/tmp/cloud-compose-salt-untrusted-preload.so"
        )
        assert application_env["PORT"] == "9999"
        assert application_env["CONTRACT_BACKTICKS"] == (
            "`touch /tmp/cloud-compose-salt-backtick-injection`"
        )
        assert application_env["CONTRACT_BACKSLASH"] == "a\\path\\ends\\"
        assert application_env["CONTRACT_COMMAND_SUB"] == (
            "$(touch /tmp/cloud-compose-salt-command-injection)"
        )
        assert application_env["CONTRACT_DOLLARS"] == "$HOME ${HOME}"
        assert application_env["CONTRACT_QUOTES"] == (
            'a "double" and a single quote: O\'Reilly'
        )
        assert application_env["CONTRACT_WHITESPACE"] == "  leading and trailing  "
        assert application_env["CONTRACT_MULTILINE"] == "line one\nline two"
        assert env["LIBOPS_MANAGED_RUNTIME_ENABLED"] == "false"
        assert env["LIBOPS_INTERNAL_SERVICES_ENABLED"] == "false"
        assert env["LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE"] == "false"
        assert project["init_commands"] == []
        assert project["up_commands"] == []
        assert project["down_commands"] == ["app-down-command"]
        assert project["rollout_commands"] == ["global-rollout-command"]
        assert (
            "contract-agent\thttps://example.invalid/contract-agent\t"
            in artifact_manifest
        )
        assert (
            "\t/usr/local/bin/contract-agent\t0750\troot\troot\t"
            "cloud-compose.service"
            in artifact_manifest
        )
        assert not Path("/tmp/cloud-compose-salt-backtick-injection").exists()
        assert not Path("/tmp/cloud-compose-salt-command-injection").exists()
    elif expected_name == "drupal-prod":
        assert json.loads(env["SITECTL_PACKAGE_VERSIONS"]) == {
            "sitectl": "v1.8.2",
            "sitectl-drupal": "v1.3.0",
        }

    assert_runtime_files()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("ansible-runtime")
    subparsers.add_parser("salt-noop")

    salt_runtime = subparsers.add_parser("salt-runtime")
    salt_runtime.add_argument("expected_name")
    salt_runtime.add_argument("expected_repo")
    salt_runtime.add_argument("expected_plugin")
    salt_runtime.add_argument("expected_package")
    salt_runtime.add_argument("expected_domain")
    salt_runtime.add_argument("expected_project_dir")
    salt_runtime.add_argument("expected_compose_project_name")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "ansible-runtime":
        assert_ansible_runtime()
    elif args.command == "salt-noop":
        assert_salt_noop()
    else:
        assert_salt_runtime(
            args.expected_name,
            args.expected_repo,
            args.expected_plugin,
            args.expected_package,
            args.expected_domain,
            args.expected_project_dir,
            args.expected_compose_project_name,
        )


if __name__ == "__main__":
    main()
