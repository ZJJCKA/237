#!/usr/bin/env python3
"""Build a deterministic compiler-ready source archive."""

from __future__ import annotations

import gzip
import hashlib
import io
import os
import tarfile
from pathlib import Path, PurePosixPath

from build_at_webserver_ipk import DEFAULT_EPOCH, VERSION


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
ARCHIVE_ROOT = "mt5700webui-openwrt-server"
OUTPUT = WORKSPACE / f"mt5700webui-openwrt-server-{VERSION}-source.tar.gz"
EXCLUDED_PARTS = {"dist", "__pycache__"}
EXECUTABLE_FILES = {
    "at-webserver/files/etc/init.d/at-webserver",
    "at-webserver/files/usr/bin/at-server.py",
    "at-webserver/files/www/cgi-bin/at-ws-info",
    "tools/build_at_webserver_ipk.py",
    "tools/build_luci_at_webserver_ipk.py",
    "tools/build_source_archive.py",
}


def source_files() -> dict[str, tuple[bytes, int]]:
    result: dict[str, tuple[bytes, int]] = {}
    for path in sorted(ROOT.rglob("*")):
        relative_path = path.relative_to(ROOT)
        if any(part in EXCLUDED_PARTS for part in relative_path.parts):
            continue
        if path.is_symlink():
            raise RuntimeError(f"source symlink is not allowed: {relative_path}")
        if not path.is_file() or path.suffix == ".pyc":
            continue
        relative = relative_path.as_posix()
        mode = 0o755 if relative in EXECUTABLE_FILES else 0o644
        result[relative] = (path.read_bytes(), mode)
    missing = EXECUTABLE_FILES.difference(result)
    if missing:
        raise RuntimeError(f"missing executable source files: {sorted(missing)}")
    return result


def parent_directories(files: dict[str, tuple[bytes, int]]) -> set[str]:
    directories = {ARCHIVE_ROOT}
    for relative in files:
        current = PurePosixPath(ARCHIVE_ROOT, relative).parent
        while str(current) not in ("", "."):
            directories.add(current.as_posix())
            if current.as_posix() == ARCHIVE_ROOT:
                break
            current = current.parent
    return directories


def archive_info(name: str, mode: int, size: int = 0) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = DEFAULT_EPOCH
    info.size = size
    return info


def build_archive(files: dict[str, tuple[bytes, int]]) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=DEFAULT_EPOCH, filename="") as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for directory in sorted(parent_directories(files)):
                info = archive_info(directory + "/", 0o755)
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            for relative, (content, mode) in sorted(files.items()):
                name = f"{ARCHIVE_ROOT}/{relative}"
                archive.addfile(archive_info(name, mode, len(content)), io.BytesIO(content))
    return output.getvalue()


def verify_archive(payload: bytes, files: dict[str, tuple[bytes, int]]) -> None:
    expected = {f"{ARCHIVE_ROOT}/{name}": value for name, value in files.items()}
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        actual_files: dict[str, tuple[bytes, int]] = {}
        roots = set()
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError(f"unsafe source member: {member.name}")
            if path.parts:
                roots.add(path.parts[0])
            if member.isdir():
                if member.mode & 0o777 != 0o755:
                    raise RuntimeError(f"invalid directory mode: {member.name}")
                continue
            if not member.isfile():
                raise RuntimeError(f"unsupported source member: {member.name}")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise RuntimeError(f"cannot read source member: {member.name}")
            actual_files[member.name] = (extracted.read(), member.mode & 0o777)
    if roots != {ARCHIVE_ROOT}:
        raise RuntimeError(f"invalid archive roots: {sorted(roots)}")
    if actual_files != expected:
        raise RuntimeError("source archive content or mode mismatch")


def main() -> None:
    files = source_files()
    payload = build_archive(files)
    verify_archive(payload, files)
    temporary = OUTPUT.with_name(OUTPUT.name + ".new")
    temporary.write_bytes(payload)
    os.replace(temporary, OUTPUT)
    print(OUTPUT)
    print(f"files={len(files)}")
    print(f"size={len(payload)}")
    print(f"sha256={hashlib.sha256(payload).hexdigest()}")


if __name__ == "__main__":
    main()
