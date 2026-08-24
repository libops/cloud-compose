#!/usr/bin/env python3

import json
import os
import pathlib
import pwd
import re
import stat
import sys
import tempfile

SAFE_PATH = re.compile(r"^[A-Za-z0-9._/+@:-]+$")
SAFE_MODES = {"0644", "0755"}


def fail(message):
    raise SystemExit(f"rootfs bundle: {message}")


def destination(relative):
    if not relative or relative.startswith("/") or not SAFE_PATH.fullmatch(relative):
        fail(f"unsafe path: {relative!r}")
    normalized = pathlib.PurePosixPath(relative)
    parts = normalized.parts
    if str(normalized) != relative:
        fail(f"non-canonical path: {relative!r}")
    if any(part in ("", ".", "..") for part in parts):
        fail(f"unsafe path: {relative!r}")
    prefix = "/var/lib/cloud-compose/mounted-rootfs" if relative.startswith("mnt/disks/") else ""
    return pathlib.Path(prefix + "/" + relative)


def ensure_parent(path):
    current = pathlib.Path("/")
    for part in path.parent.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            current.mkdir(mode=0o755)
            metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            fail(f"unsafe parent: {current}")
        if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) & 0o022:
            fail(f"untrusted parent: {current}")


def secure_runtime_home():
    path = pathlib.Path("/home/cloud-compose")
    try:
        account = pwd.getpwnam("cloud-compose")
    except KeyError:
        fail("cloud-compose account is missing")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        fail(f"unsafe runtime home: {error}")
    try:
        metadata = os.fstat(descriptor)
        if (
            metadata.st_uid not in (0, account.pw_uid)
            or metadata.st_gid not in (0, account.pw_gid)
            or stat.S_IMODE(metadata.st_mode) & 0o022
        ):
            fail("untrusted runtime home ownership or mode")
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, 0o755)
    finally:
        os.close(descriptor)


def install(path, mode, content):
    if mode not in SAFE_MODES:
        fail(f"unsupported mode for {path}: {mode}")
    if not isinstance(content, str):
        fail(f"invalid content for {path}")
    decoded = content.encode("utf-8")
    ensure_parent(path)
    if path.exists() or path.is_symlink():
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            fail(f"unsafe destination: {path}")
    descriptor, temporary = tempfile.mkstemp(prefix=".cloud-compose-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(decoded)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), int(mode, 8))
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main():
    if os.geteuid() != 0 or len(sys.argv) != 2:
        fail("usage: install-rootfs.py BUNDLE")
    with open(sys.argv[1], "r", encoding="utf-8") as source:
        payload = json.load(source)
    if set(payload) != {"version", "files"} or payload["version"] != 1 or not isinstance(payload["files"], dict):
        fail("invalid bundle schema")
    secure_runtime_home()
    for relative in sorted(payload["files"]):
        entry = payload["files"][relative]
        if not isinstance(entry, dict) or set(entry) != {"mode", "content"}:
            fail(f"invalid entry: {relative}")
        install(destination(relative), entry["mode"], entry["content"])


if __name__ == "__main__":
    main()
