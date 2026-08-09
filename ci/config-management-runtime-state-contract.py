#!/usr/bin/env python3

import json
import os
import subprocess
from pathlib import Path


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


name = os.environ["SMOKE_NAME"]
template = os.environ["SMOKE_TEMPLATE"]
project_dir = os.environ["SMOKE_PROJECT_DIR"]
runtime_env = load_runtime_env(Path("/home/cloud-compose/.env"))
projects = json.loads(Path("/home/cloud-compose/compose-projects.json").read_text())
project = projects[name]

assert runtime_env["CLOUD_COMPOSE_PROVIDER"] == "onprem"
assert runtime_env["CLOUD_COMPOSE_APPS"] == name
assert runtime_env["CLOUD_COMPOSE_PRIMARY_APP"] == name
assert runtime_env["SITECTL_PLUGIN"] == template
assert runtime_env["DOCKER_COMPOSE_DIR"] == project_dir
assert f"sitectl-{template}" in runtime_env["SITECTL_PACKAGES"].split()
assert project["docker_compose_repo"] == f"https://github.com/libops/{template}.git"
assert project["project_dir"] == project_dir
assert project["sitectl_plugin"] == template
