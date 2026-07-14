#!/usr/bin/env python3

"""Validate host-mutating cloud-compose inputs before an adapter applies them."""

import argparse
import base64
import json
import os
import re
import sys


PRODUCTION_DATA_ROOT = "/mnt/disks/data"
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")
ARTIFACT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HTTPS_URL = re.compile(r"^https://[^\s]+$")
LOWER_SHA256 = re.compile(r"^[0-9a-f]{64}$")
FILE_MODE = re.compile(r"^0?[0-7]{3}$")
ACCOUNT_NAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}\$?$")
SERVICE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]*\.service$")


def normalized_absolute_path(value):
    if not isinstance(value, str) or not value.startswith("/") or value == "/":
        return False
    if CONTROL_CHARACTERS.search(value):
        return False
    segments = value[1:].split("/")
    return all(segment not in ("", ".", "..") for segment in segments)


def validate_project_paths(projects, data_root):
    errors = []
    if not isinstance(projects, list):
        return ["Compose projects must be a list after adapter normalization."]

    for index, project in enumerate(projects):
        label = f"project[{index}]"
        if not isinstance(project, dict):
            errors.append(f"{label} must be an object.")
            continue
        if isinstance(project.get("name"), str) and project["name"]:
            label = f"project {project['name']!r}"
        path = project.get("project_dir")
        if not normalized_absolute_path(path):
            errors.append(
                f"{label} project_dir must be a normalized non-root absolute path "
                "without empty, dot, or control-character segments."
            )
            continue
        if not path.startswith(f"{data_root}/"):
            errors.append(
                f"{label} project_dir must be a non-root descendant of {data_root}."
            )
            continue

        resolved = os.path.realpath(path)
        try:
            within_data_root = os.path.commonpath((data_root, resolved)) == data_root
        except ValueError:
            within_data_root = False
        if not within_data_root or resolved == data_root:
            errors.append(
                f"{label} project_dir resolves outside the fixed {data_root} boundary: "
                f"{path!r} -> {resolved!r}."
            )
    return errors


def validate_artifacts(artifacts):
    errors = []
    if not isinstance(artifacts, list):
        return ["Managed artifacts must be a list."]

    names = []
    paths = []
    required_fields = {"name", "url", "sha256", "path"}

    for index, artifact in enumerate(artifacts):
        label = f"artifact[{index}]"
        if not isinstance(artifact, dict):
            errors.append(f"{label} must be an object.")
            continue

        missing = sorted(required_fields - artifact.keys())
        if missing:
            errors.append(f"{label} is missing required fields: {', '.join(missing)}.")

        name = artifact.get("name")
        if not isinstance(name, str) or ARTIFACT_NAME.fullmatch(name) is None:
            errors.append(f"{label} name must be a safe basename.")
        else:
            names.append(name)

        url = artifact.get("url")
        if not isinstance(url, str) or HTTPS_URL.fullmatch(url) is None:
            errors.append(f"{label} url must be a non-whitespace HTTPS URL.")

        sha256 = artifact.get("sha256")
        if not isinstance(sha256, str) or LOWER_SHA256.fullmatch(sha256) is None:
            errors.append(f"{label} sha256 must contain exactly 64 lowercase hex characters.")

        path = artifact.get("path")
        if not normalized_absolute_path(path):
            errors.append(
                f"{label} path must be a non-root absolute path without empty, dot, "
                "or control-character segments."
            )
        else:
            paths.append(path)

        mode = artifact.get("mode", "0755")
        if not isinstance(mode, str) or FILE_MODE.fullmatch(mode) is None:
            errors.append(f"{label} mode must match 0?[0-7]{{3}}.")

        for field in ("owner", "group"):
            value = artifact.get(field, "root")
            if not isinstance(value, str) or ACCOUNT_NAME.fullmatch(value) is None:
                errors.append(f"{label} {field} must be a safe Linux account name.")

        restart = artifact.get("restart", "")
        if not isinstance(restart, str) or (
            restart and SERVICE_NAME.fullmatch(restart) is None
        ):
            errors.append(f"{label} restart must be empty or a safe .service unit name.")

    if len(set(names)) != len(names):
        errors.append("Managed artifact names must be unique.")
    if len(set(paths)) != len(paths):
        errors.append("Managed artifact target paths must be unique.")
    return errors


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--data-root",
        default=PRODUCTION_DATA_ROOT,
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if not normalized_absolute_path(args.data_root):
        print("The validation data root itself is unsafe.", file=sys.stderr)
        return 2

    raw_payload = os.environ.get("CLOUD_COMPOSE_VALIDATION_PAYLOAD", "")
    encoded_payload = os.environ.get("CLOUD_COMPOSE_VALIDATION_PAYLOAD_B64", "")
    if encoded_payload:
        try:
            raw_payload = base64.b64decode(encoded_payload, validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            print(f"Could not decode base64 cloud-compose validation payload: {exc}", file=sys.stderr)
            return 2
    try:
        payload = json.loads(raw_payload)
    except json.JSONDecodeError as exc:
        print(f"Could not decode cloud-compose validation payload: {exc}", file=sys.stderr)
        return 2
    if not isinstance(payload, dict):
        print("Cloud-compose validation payload must be an object.", file=sys.stderr)
        return 2

    errors = validate_project_paths(payload.get("projects"), args.data_root)
    errors.extend(validate_artifacts(payload.get("artifacts")))
    if errors:
        print("Cloud-compose host input validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 2

    print(json.dumps({"changed": False, "comment": "Cloud-compose host inputs are valid."}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
