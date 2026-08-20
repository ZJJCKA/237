#!/usr/bin/env python3
"""Build and verify the architecture-independent at-webserver OpenWrt IPK."""

import argparse
import gzip
import hashlib
import io
import os
import tarfile
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, Tuple


PACKAGE = "at-webserver"
VERSION = "1.0-33"
ARCHITECTURE = "all"
DEFAULT_EPOCH = 1786320000  # 2026-08-10 00:00:00 UTC
DEPENDENCIES = (
    "libc",
    "python3",
    "python3-asyncio",
    "python3-websockets",
    "python3-pyserial",
    "python3-aiohttp",
    "ca-bundle",
    "luci-app-modem",
)


def normalized_name(name: str) -> str:
    return name[2:] if name.startswith("./") else name


def tar_info(name: str, mode: int, epoch: int, size: int = 0) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = epoch
    info.size = size
    return info


def make_tar_gz(
    files: Dict[str, Tuple[bytes, int]],
    directories: Iterable[str],
    epoch: int,
    sort_files: bool = True,
) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(
        filename="", fileobj=output, mode="wb", compresslevel=9, mtime=0
    ) as compressed:
        with tarfile.open(
            fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT
        ) as archive:
            for directory in sorted(
                directories,
                key=lambda item: (len(PurePosixPath(item).parts), item),
            ):
                name = directory if directory.endswith("/") else directory + "/"
                info = tar_info(name, 0o755, epoch)
                info.type = tarfile.DIRTYPE
                archive.addfile(info)

            file_names = sorted(files) if sort_files else files
            for name in file_names:
                content, mode = files[name]
                archive.addfile(tar_info(name, mode, epoch, len(content)), io.BytesIO(content))
    return output.getvalue()


def parent_directories(names: Iterable[str]) -> set:
    directories = {"./"}
    for name in names:
        path = PurePosixPath(normalized_name(name))
        for parent in path.parents:
            if str(parent) == ".":
                continue
            directories.add("./{}/".format(parent.as_posix()))
    return directories


def read_unix_text(path: Path) -> bytes:
    """Return router-side text with Unix line endings, even on Windows hosts."""
    return path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def collect_data_files(repo_root: Path) -> Dict[str, Tuple[bytes, int]]:
    source_root = repo_root / "at-webserver" / "files"
    files: Dict[str, Tuple[bytes, int]] = {
        "./usr/bin/at-server.py": (
            read_unix_text(source_root / "usr/bin/at-server.py"),
            0o755,
        ),
        "./usr/bin/traffic_stats.py": (
            read_unix_text(source_root / "usr/bin/traffic_stats.py"),
            0o644,
        ),
        "./etc/init.d/at-webserver": (
            read_unix_text(source_root / "etc/init.d/at-webserver"),
            0o755,
        ),
        "./etc/config/at-webserver": (
            read_unix_text(source_root / "etc/config/at-webserver"),
            0o600,
        ),
        "./www/cgi-bin/at-ws-info": (
            read_unix_text(source_root / "www/cgi-bin/at-ws-info"),
            0o755,
        ),
    }

    web_root = source_root / "www" / "5700"
    for source in sorted(path for path in web_root.rglob("*") if path.is_file()):
        relative = source.relative_to(web_root).as_posix()
        files["./www/5700/{}".format(relative)] = (source.read_bytes(), 0o644)
    return files


def make_control(data_size: int, epoch: int) -> bytes:
    fields = [
        "Package: {}".format(PACKAGE),
        "Version: {}".format(VERSION),
        "Depends: {}".format(", ".join(DEPENDENCIES)),
        "Source: package/{}".format(PACKAGE),
        "SourceName: {}".format(PACKAGE),
        "Section: net",
        "SourceDateEpoch: {}".format(epoch),
        "Architecture: {}".format(ARCHITECTURE),
        "Installed-Size: {}".format(data_size),
        "Description:  WebSocket server for AT command communication with web interface",
        "",
    ]
    return "\n".join(fields).encode("utf-8")


def build_ipk(repo_root: Path, destination: Path, epoch: int) -> None:
    data_files = collect_data_files(repo_root)
    data_archive = make_tar_gz(data_files, parent_directories(data_files), epoch)

    control_files = {
        "./control": (make_control(len(data_archive), epoch), 0o644),
        "./conffiles": (b"/etc/config/at-webserver\n", 0o644),
    }
    control_archive = make_tar_gz(control_files, {"./"}, epoch)

    outer_files = {
        "./debian-binary": (b"2.0\n", 0o644),
        "./data.tar.gz": (data_archive, 0o644),
        "./control.tar.gz": (control_archive, 0o644),
    }
    # ImmortalWrt 23.05 packages use a gzip-compressed tar as the outer IPK.
    ordered_outer = {
        name: outer_files[name]
        for name in ("./debian-binary", "./data.tar.gz", "./control.tar.gz")
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(
        make_tar_gz(ordered_outer, (), epoch, sort_files=False)
    )


def archive_members(payload: bytes) -> Dict[str, Tuple[bytes, int]]:
    members: Dict[str, Tuple[bytes, int]] = {}
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        for member in archive.getmembers():
            if not member.isfile():
                continue
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ValueError("cannot read {}".format(member.name))
            members[normalized_name(member.name)] = (extracted.read(), member.mode)
    return members


def verify_ipk(repo_root: Path, destination: Path) -> str:
    package_payload = destination.read_bytes()
    outer = archive_members(package_payload)
    expected_outer = {"debian-binary", "data.tar.gz", "control.tar.gz"}
    if set(outer) != expected_outer:
        raise ValueError("invalid outer IPK members: {}".format(sorted(outer)))
    if outer["debian-binary"][0] != b"2.0\n":
        raise ValueError("invalid debian-binary marker")

    control = archive_members(outer["control.tar.gz"][0])
    control_text = control["control"][0].decode("utf-8")
    required_fields = (
        "Package: {}".format(PACKAGE),
        "Version: {}".format(VERSION),
        "Architecture: {}".format(ARCHITECTURE),
        "Depends: {}".format(", ".join(DEPENDENCIES)),
    )
    if any(field not in control_text for field in required_fields):
        raise ValueError("control metadata is incomplete")
    if control.get("conffiles", (b"", 0))[0] != b"/etc/config/at-webserver\n":
        raise ValueError("conffiles metadata is invalid")

    data = archive_members(outer["data.tar.gz"][0])
    source_files = collect_data_files(repo_root)
    if "Installed-Size: {}".format(len(outer["data.tar.gz"][0])) not in control_text:
        raise ValueError("Installed-Size does not match data.tar.gz")
    if set(data) != {normalized_name(name) for name in source_files}:
        raise ValueError("packaged file list does not match the source tree")
    for source_name, (source_content, source_mode) in source_files.items():
        packaged_content, packaged_mode = data[normalized_name(source_name)]
        if packaged_content != source_content:
            raise ValueError("content mismatch: {}".format(source_name))
        if packaged_mode != source_mode:
            raise ValueError("mode mismatch: {}".format(source_name))

    router_text = (
        "etc/init.d/at-webserver",
        "usr/bin/at-server.py",
        "usr/bin/traffic_stats.py",
        "www/cgi-bin/at-ws-info",
    )
    for name in router_text:
        if b"\r" in data[name][0]:
            raise ValueError("non-Unix line endings: {}".format(name))

    digest = hashlib.sha256(package_payload).hexdigest()
    return digest


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
