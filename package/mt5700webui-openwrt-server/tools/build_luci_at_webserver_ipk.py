#!/usr/bin/env python3
"""Build and verify the architecture-independent LuCI package."""

import argparse
import hashlib
import os
from pathlib import Path
from typing import Dict, Tuple

from build_at_webserver_ipk import (
    DEFAULT_EPOCH,
    archive_members,
    make_tar_gz,
    normalized_name,
    parent_directories,
    read_unix_text,
)


PACKAGE = "luci-app-at-webserver"
VERSION = "1.0-31"
ARCHITECTURE = "all"


def collect_data_files(repo_root: Path) -> Dict[str, Tuple[bytes, int]]:
    package_root = repo_root / "luci-app-at-webserver"
    files: Dict[str, Tuple[bytes, int]] = {}

    htdocs = package_root / "htdocs"
    for source in sorted(path for path in htdocs.rglob("*") if path.is_file()):
        relative = source.relative_to(htdocs).as_posix()
        files["./www/{}".format(relative)] = (read_unix_text(source), 0o644)

    root = package_root / "root"
    for source in sorted(path for path in root.rglob("*") if path.is_file()):
        relative = source.relative_to(root).as_posix()
        files["./{}".format(relative)] = (read_unix_text(source), 0o644)
    return files


def make_control(data_size: int, epoch: int) -> bytes:
    fields = [
        "Package: {}".format(PACKAGE),
        "Version: {}".format(VERSION),
        "Depends: libc, luci-base, at-webserver",
        "Source: package/{}".format(PACKAGE),
        "SourceName: {}".format(PACKAGE),
        "Section: luci",
        "SourceDateEpoch: {}".format(epoch),
        "Architecture: {}".format(ARCHITECTURE),
        "Installed-Size: {}".format(data_size),
        "Description:  LuCI support for AT WebServer",
        "",
    ]
    return "\n".join(fields).encode("utf-8")


def build_ipk(repo_root: Path, destination: Path, epoch: int) -> None:
    data_files = collect_data_files(repo_root)
    data_archive = make_tar_gz(data_files, parent_directories(data_files), epoch)
    control_archive = make_tar_gz(
        {"./control": (make_control(len(data_archive), epoch), 0o644)},
        {"./"},
        epoch,
    )
    outer = {
        "./debian-binary": (b"2.0\n", 0o644),
        "./data.tar.gz": (data_archive, 0o644),
        "./control.tar.gz": (control_archive, 0o644),
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(make_tar_gz(outer, (), epoch, sort_files=False))


def verify_ipk(repo_root: Path, destination: Path) -> str:
    package_payload = destination.read_bytes()
    outer = archive_members(package_payload)
    if list(outer) != ["debian-binary", "data.tar.gz", "control.tar.gz"]:
        raise ValueError("invalid outer IPK members")
    if outer["debian-binary"][0] != b"2.0\n":
        raise ValueError("invalid debian-binary marker")

    control = archive_members(outer["control.tar.gz"][0])
    control_text = control["control"][0].decode("utf-8")
    for field in (
        "Package: {}".format(PACKAGE),
        "Version: {}".format(VERSION),
        "Architecture: {}".format(ARCHITECTURE),
        "Depends: libc, luci-base, at-webserver",
    ):
        if field not in control_text:
            raise ValueError("control metadata is incomplete")

    data = archive_members(outer["data.tar.gz"][0])
    source_files = collect_data_files(repo_root)
    if "Installed-Size: {}".format(len(outer["data.tar.gz"][0])) not in control_text:
        raise ValueError("Installed-Size does not match data.tar.gz")
    if set(data) != {normalized_name(name) for name in source_files}:
        raise ValueError("packaged file list does not match the source tree")
    for source_name, expected in source_files.items():
        actual = data[normalized_name(source_name)]
        if actual != expected:
            raise ValueError("packaged data mismatch: {}".format(source_name))

    menu = data[
        "usr/share/luci/menu.d/luci-app-at-webserver.json"
    ][0].decode("utf-8")
    if '"order": -10' not in menu:
        raise ValueError("LuCI service menu priority is missing")
    return hashlib.sha256(package_payload).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--epoch", type=int)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    destination = args.output or (
        repo_root / "dist" / "{}_{}_{}.ipk".format(PACKAGE, VERSION, ARCHITECTURE)
    )
    epoch = (
        args.epoch
        if args.epoch is not None
        else int(os.environ.get("SOURCE_DATE_EPOCH", str(DEFAULT_EPOCH)))
    )
    if epoch < 0:
        parser.error("--epoch must be non-negative")
    build_ipk(repo_root, destination, epoch)
    digest = verify_ipk(repo_root, destination)
    print(destination.resolve())
    print("size={}".format(destination.stat().st_size))
    print("sha256={}".format(digest))


if __name__ == "__main__":
    main()
