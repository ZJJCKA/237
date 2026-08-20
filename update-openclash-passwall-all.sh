#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export MAKEFLAGS=

ONECLICK_SCRIPT_VERSION='20260814.1'
ROOT='/home/ht/237'
SOURCE_UPDATER="$ROOT/update-openclash-passwall-sources.sh"
EXPECTED_SOURCE_UPDATER_SHA='9342eb0d9e480f5542ebc0ca146b05288f53c5e649acda924ce33363eb856aba'
PKG_DIR="$ROOT/package/local/openclash-core-meta"
MAKEFILE="$PKG_DIR/Makefile"
CORE="$PKG_DIR/files/clash_meta"
BIN_DIR="$ROOT/bin/packages/aarch64_cortex-a53/base"

CORE_ONLY=0
RECOVER_ONLY=0
[ "$#" -le 1 ] || {
    echo 'ERROR=TOO_MANY_ARGUMENTS' >&2
    exit 2
}
case "${1-}" in
    '') ;;
    --core-only) CORE_ONLY=1 ;;
    --recover) RECOVER_ONLY=1 ;;
    --help|-h)
        echo "Usage: $0 [--core-only|--recover]"
        exit 0
        ;;
    *)
        echo "ERROR=UNSUPPORTED_ARGUMENT:${1-}" >&2
        exit 2
        ;;
esac

[ "$(pwd -P)" = "$ROOT" ] || {
    echo "ERROR=RUN_FROM:$ROOT"
    exit 1
}

for C in awk bash chmod cmp cp curl date file find flock git grep install make mkdir \
         mktemp mv python3 readlink rm sed sha256sum sort stat tar tee; do
    command -v "$C" >/dev/null 2>&1 || {
        echo "ERROR=MISSING_COMMAND:$C"
        exit 1
    }
done

[ -f "$SOURCE_UPDATER" ] && [ ! -L "$SOURCE_UPDATER" ]
bash -n "$SOURCE_UPDATER"
printf '%s  %s\n' "$EXPECTED_SOURCE_UPDATER_SHA" "$SOURCE_UPDATER" | sha256sum -c -

exec 201>"$ROOT/.openclash-passwall-core-oneclick.lock"
flock -n 201 || {
    echo 'ERROR=ANOTHER_ONECLICK_UPDATE_IS_RUNNING' >&2
    exit 1
}

if [ "$RECOVER_ONLY" -eq 1 ]; then
    exec bash "$SOURCE_UPDATER" --recover "$ROOT"
fi

[ -f "$MAKEFILE" ] && [ ! -L "$MAKEFILE" ]
[ -f "$CORE" ] && [ ! -L "$CORE" ]
grep -Fxq 'CONFIG_PACKAGE_openclash-core-meta=y' "$ROOT/.config"
grep -Fxq 'PKG_NAME:=openclash-core-meta' "$MAKEFILE"
grep -Fxq 'RSTRIP:=:' "$MAKEFILE"
grep -Fq '$(CORE_SHA256)' "$MAKEFILE"
[ "$(grep -c '^CORE_SHA256:=' "$MAKEFILE")" -eq 1 ]
DECLARED_CORE_SHA="$(sed -n 's/^CORE_SHA256:=//p' "$MAKEFILE")"
CURRENT_CORE_SHA="$(sha256sum "$CORE" | awk '{print $1}')"
[[ "$DECLARED_CORE_SHA" =~ ^[0-9a-f]{64}$ ]]
[ "$DECLARED_CORE_SHA" = "$CURRENT_CORE_SHA" ] || {
    echo 'ERROR=CORE_SOURCE_AND_MAKEFILE_SHA_MISMATCH' >&2
    exit 1
}

STAGE=''
PROOF=''
BACKUP=''
MUTATED=0
CORE_COMMITTED=0

rollback_core()
{
    local CLEAN_RC COMPILE_RC OLD_VERSION OLD_RELEASE F
    local -a SAVED_IPKS
    set +e
    echo 'OPENCLASH_CORE_ROLLBACK=START'
    cp -p "$BACKUP/Makefile.before" "$MAKEFILE"
    cp -p "$BACKUP/clash_meta.before" "$CORE"
    cp -p "$BACKUP/config.before" "$ROOT/.config"

    make -C "$ROOT" -j1 package/local/openclash-core-meta/clean V=s \
        >"$BACKUP/rollback-clean.log" 2>&1
    CLEAN_RC=$?
    make -C "$ROOT" -j1 package/local/openclash-core-meta/compile V=s \
        >"$BACKUP/rollback-compile.log" 2>&1
    COMPILE_RC=$?

    mkdir -p "$BACKUP/rejected-ipks"
    mapfile -d '' -t SAVED_IPKS < <(
        find "$BACKUP/old-ipks" -maxdepth 1 -type f \
            -name 'openclash-core-meta_*.ipk' -print0
    )
    if [ "${#SAVED_IPKS[@]}" -gt 0 ]; then
        for F in "$BIN_DIR"/openclash-core-meta_*.ipk; do
            [ -f "$F" ] || continue
            mv -f "$F" "$BACKUP/rejected-ipks/"
        done
        for F in "${SAVED_IPKS[@]}"; do
            cp -p "$F" "$BIN_DIR/"
        done
    else
        OLD_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$BACKUP/Makefile.before")"
        OLD_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$BACKUP/Makefile.before")"
        for F in "$BIN_DIR"/openclash-core-meta_*.ipk; do
            [ -f "$F" ] || continue
            case "${F##*/}" in
                openclash-core-meta_"$OLD_VERSION"-"$OLD_RELEASE"_*.ipk) ;;
                *) mv -f "$F" "$BACKUP/rejected-ipks/" ;;
            esac
        done
    fi

    echo "OPENCLASH_CORE_ROLLBACK_CLEAN_RC=$CLEAN_RC"
    echo "OPENCLASH_CORE_ROLLBACK_COMPILE_RC=$COMPILE_RC"
    if [ "$CLEAN_RC" -eq 0 ] && [ "$COMPILE_RC" -eq 0 ]; then
        echo 'OPENCLASH_CORE_ROLLBACK=PASS'
    else
        echo 'OPENCLASH_CORE_ROLLBACK=SOURCE_RESTORED_DERIVED_REBUILD_FAILED'
    fi
}

finish()
{
    RC=$?
    trap - EXIT INT TERM
    set +e

    if [ "$MUTATED" -eq 1 ] && [ "$CORE_COMMITTED" -ne 1 ]; then
        rollback_core
    fi

    case "$PROOF" in
        "$ROOT"/.openclash-core-proof.*)
            [ ! -e "$PROOF" ] || rm -rf -- "$PROOF"
            ;;
    esac
    case "$STAGE" in
        /tmp/r3mini-openclash-core-auto.*)
            [ ! -e "$STAGE" ] || rm -rf -- "$STAGE"
            ;;
    esac
    exit "$RC"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_ipk()
{
    local IPK="$1" EXPECTED_VERSION="$2" EXPECTED_SHA="$3"
    local IPK_ABS CONTAINER CONTROL_TAR DATA_TAR CONTROL IPK_CORE INFO
    local -a CONTROL_TARS DATA_TARS

    PROOF="$(mktemp -d "$ROOT/.openclash-core-proof.XXXXXX")"
    mkdir "$PROOF/outer" "$PROOF/control" "$PROOF/data"
    IPK_ABS="$(readlink -f "$IPK")"

    if tar -tf "$IPK_ABS" >/dev/null 2>&1; then
        tar -xf "$IPK_ABS" -C "$PROOF/outer"
        CONTAINER=tar
    elif command -v ar >/dev/null 2>&1 && ar t "$IPK_ABS" >/dev/null 2>&1; then
        (
            cd "$PROOF/outer"
            ar x "$IPK_ABS"
        )
        CONTAINER=ar
    else
        echo "ERROR=UNSUPPORTED_IPK_CONTAINER:$IPK"
        return 1
    fi

    mapfile -t CONTROL_TARS < <(
        find "$PROOF/outer" -maxdepth 1 -type f -name 'control.tar.*' -print | sort
    )
    mapfile -t DATA_TARS < <(
        find "$PROOF/outer" -maxdepth 1 -type f -name 'data.tar.*' -print | sort
    )
    [ "${#CONTROL_TARS[@]}" -eq 1 ]
    [ "${#DATA_TARS[@]}" -eq 1 ]
    CONTROL_TAR="${CONTROL_TARS[0]}"
    DATA_TAR="${DATA_TARS[0]}"

    tar -xf "$CONTROL_TAR" -C "$PROOF/control"
    tar -xf "$DATA_TAR" -C "$PROOF/data"
    CONTROL="$PROOF/control/control"
    IPK_CORE="$PROOF/data/etc/openclash/core/clash_meta"

    [ -f "$CONTROL" ] && [ ! -L "$CONTROL" ]
    [ -f "$IPK_CORE" ] && [ ! -L "$IPK_CORE" ]
    grep -Fxq 'Package: openclash-core-meta' "$CONTROL"
    grep -Fxq "Version: $EXPECTED_VERSION" "$CONTROL"
    grep -Fxq 'Architecture: aarch64_cortex-a53' "$CONTROL"
    printf '%s  %s\n' "$EXPECTED_SHA" "$IPK_CORE" | sha256sum -c -
    cmp -s "$CORE" "$IPK_CORE"
    [ "$(stat -c '%a' "$IPK_CORE")" = 755 ]

    INFO="$(file -L "$IPK_CORE")"
    printf '%s\n' "$INFO" | grep -Fq 'ELF 64-bit LSB executable'
    printf '%s\n' "$INFO" | grep -Fq 'ARM aarch64'
    printf '%s\n' "$INFO" | grep -Fq 'statically linked'
    echo "OPENCLASH_CORE_IPK_CONTAINER=$CONTAINER"

    rm -rf -- "$PROOF"
    PROOF=''
}

echo '===== OPENCLASH CORE CHECK ====='
mapfile -t REMOTE < <(
    git ls-remote --exit-code \
        https://github.com/vernesong/OpenClash.git refs/heads/core
)
[ "${#REMOTE[@]}" -eq 1 ] || {
    echo "ERROR=CORE_BRANCH_RESULT_COUNT:${#REMOTE[@]}"
    exit 1
}
read -r CORE_COMMIT CORE_REF <<<"${REMOTE[0]}"
[[ "$CORE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[ "$CORE_REF" = refs/heads/core ]

STAGE="$(mktemp -d /tmp/r3mini-openclash-core-auto.XXXXXX)"
chmod 700 "$STAGE"
VERSION_FILE="$STAGE/core_version"
ARCHIVE="$STAGE/clash-linux-arm64.tar.gz"
NEW_CORE="$STAGE/clash_meta"
RAW_BASE="https://raw.githubusercontent.com/vernesong/OpenClash/$CORE_COMMIT/master"
CORE_URL="$RAW_BASE/meta/clash-linux-arm64.tar.gz"

curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 20 --max-time 120 \
    "$RAW_BASE/core_version" -o "$VERSION_FILE"
curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 20 --max-time 600 \
    "$CORE_URL" -o "$ARCHIVE"

CORE_VERSION="$(sed -n '1{s/\r$//;p;q}' "$VERSION_FILE")"
[[ "$CORE_VERSION" =~ ^alpha-g[0-9a-f]{7,40}$ ]] || {
    echo "ERROR=UNEXPECTED_META_CORE_VERSION:$CORE_VERSION" >&2
    exit 1
}

python3 - "$ARCHIVE" "$NEW_CORE" <<'PY_EXTRACT'
import os
import shutil
import sys
import tarfile

archive, output = sys.argv[1:]
with tarfile.open(archive, "r:gz") as tf:
    members = tf.getmembers()
    if len(members) != 1:
        raise SystemExit(f"archive member count is {len(members)}, expected 1")
    member = members[0]
    if member.name != "clash" or not member.isfile():
        raise SystemExit("archive must contain exactly one regular file named clash")
    source = tf.extractfile(member)
    if source is None:
        raise SystemExit("cannot read clash from archive")
    with source, open(output, "xb") as target:
        shutil.copyfileobj(source, target)
if os.path.getsize(output) == 0:
    raise SystemExit("extracted core is empty")
PY_EXTRACT

chmod 0755 "$NEW_CORE"
ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
NEW_CORE_SHA="$(sha256sum "$NEW_CORE" | awk '{print $1}')"
INFO="$(file -L "$NEW_CORE")"
printf '%s\n' "$INFO" | grep -Fq 'ELF 64-bit LSB executable'
printf '%s\n' "$INFO" | grep -Fq 'ARM aarch64'
printf '%s\n' "$INFO" | grep -Fq 'statically linked'

echo "CORE_UPSTREAM_VERSION=$CORE_VERSION"
echo "CORE_UPSTREAM_COMMIT=$CORE_COMMIT"
echo "CORE_UPSTREAM_ARCHIVE_SHA256=$ARCHIVE_SHA"
echo "CORE_UPSTREAM_BINARY_SHA256=$NEW_CORE_SHA"

if [ "$NEW_CORE_SHA" = "$CURRENT_CORE_SHA" ]; then
    echo 'OPENCLASH_CORE_UPDATE=SKIP_SAME_BINARY'
else
    CURRENT_PKG_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE")"
    CURRENT_PKG_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$MAKEFILE")"
    [[ "$CURRENT_PKG_VERSION" =~ ^[0-9]{8}$ ]]
    [[ "$CURRENT_PKG_RELEASE" =~ ^[0-9]+$ ]]
    [ "$(grep -c '^PKG_VERSION:=' "$MAKEFILE")" -eq 1 ]
    [ "$(grep -c '^PKG_RELEASE:=' "$MAKEFILE")" -eq 1 ]
    [ "$(grep -c '^CORE_SHA256:=' "$MAKEFILE")" -eq 1 ]

    TODAY="$(date +%Y%m%d)"
    [[ "$TODAY" =~ ^[0-9]{8}$ ]]
    if ((10#$TODAY > 10#$CURRENT_PKG_VERSION)); then
        NEW_PKG_VERSION="$TODAY"
        NEW_PKG_RELEASE=1
    else
        NEW_PKG_VERSION="$CURRENT_PKG_VERSION"
        NEW_PKG_RELEASE=$((10#$CURRENT_PKG_RELEASE + 1))
    fi
    NEW_FULL_VERSION="$NEW_PKG_VERSION-$NEW_PKG_RELEASE"

    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_ROOT='/home/ht/237-backups'
    mkdir -p "$BACKUP_ROOT"
    BACKUP="$(mktemp -d "$BACKUP_ROOT/openclash-core-auto-$STAMP.XXXXXX")"
    LOGDIR="$ROOT/build-logs/openclash-core-auto-$NEW_FULL_VERSION-$STAMP"
    mkdir -p "$BACKUP/old-ipks" "$LOGDIR"
    cp -p "$MAKEFILE" "$BACKUP/Makefile.before"
    cp -p "$CORE" "$BACKUP/clash_meta.before"
    cp -p "$ROOT/.config" "$BACKUP/config.before"
    cp -p "$VERSION_FILE" "$BACKUP/upstream-core_version"
    cp -p "$ARCHIVE" "$BACKUP/upstream-clash-linux-arm64.tar.gz"
    cp -p "$NEW_CORE" "$BACKUP/clash_meta.new"
    for F in "$BIN_DIR"/openclash-core-meta_*.ipk; do
        [ -f "$F" ] || continue
        cp -p "$F" "$BACKUP/old-ipks/"
    done

    MAKE_TMP="$(mktemp "$PKG_DIR/.Makefile.auto.XXXXXX")"
    python3 - "$MAKEFILE" "$MAKE_TMP" \
        "$NEW_PKG_VERSION" "$NEW_PKG_RELEASE" "$NEW_CORE_SHA" \
        "$CORE_VERSION" "$CORE_COMMIT" "$ARCHIVE_SHA" "$CORE_URL" <<'PY_MAKEFILE'
from pathlib import Path
import sys

(src, dst, pkg_version, pkg_release, core_sha, upstream_version,
 upstream_commit, archive_sha, upstream_url) = sys.argv[1:]
lines = Path(src).read_text(encoding="utf-8").splitlines()
out = []
counts = {"version": 0, "release": 0, "core": 0}

for line in lines:
    if line.startswith("CORE_UPSTREAM_"):
        continue
    if line.startswith("PKG_VERSION:="):
        out.append(f"PKG_VERSION:={pkg_version}")
        counts["version"] += 1
    elif line.startswith("PKG_RELEASE:="):
        out.append(f"PKG_RELEASE:={pkg_release}")
        counts["release"] += 1
    elif line.startswith("CORE_SHA256:="):
        out.extend([
            f"CORE_SHA256:={core_sha}",
            f"CORE_UPSTREAM_VERSION:={upstream_version}",
            f"CORE_UPSTREAM_COMMIT:={upstream_commit}",
            f"CORE_UPSTREAM_ARCHIVE_SHA256:={archive_sha}",
            f"CORE_UPSTREAM_URL:={upstream_url}",
        ])
        counts["core"] += 1
    else:
        out.append(line)

if counts != {"version": 1, "release": 1, "core": 1}:
    raise SystemExit(f"Makefile anchor contract failed: {counts}")
Path(dst).write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
PY_MAKEFILE

    chmod "$(stat -c '%a' "$MAKEFILE")" "$MAKE_TMP"
    CORE_TMP="$(mktemp "$PKG_DIR/files/.clash_meta.auto.XXXXXX")"
    install -m 0755 "$NEW_CORE" "$CORE_TMP"
    printf '%s  %s\n' "$NEW_CORE_SHA" "$CORE_TMP" | sha256sum -c -

    MUTATED=1
    mv -f "$MAKE_TMP" "$MAKEFILE"
    mv -f "$CORE_TMP" "$CORE"

    make -C "$ROOT" -j1 defconfig 2>&1 | tee "$LOGDIR/defconfig.log"
    grep -Fxq 'CONFIG_PACKAGE_openclash-core-meta=y' "$ROOT/.config"
    make -C "$ROOT" -j1 package/local/openclash-core-meta/clean V=s \
        2>&1 | tee "$LOGDIR/clean.log"
    make -C "$ROOT" -j1 package/local/openclash-core-meta/compile V=s \
        2>&1 | tee "$LOGDIR/compile.log"

    mapfile -d '' -t NEW_IPKS < <(
        find "$BIN_DIR" -maxdepth 1 -type f \
            -name "openclash-core-meta_${NEW_FULL_VERSION}_*.ipk" -print0
    )
    [ "${#NEW_IPKS[@]}" -eq 1 ] || {
        echo "ERROR=NEW_CORE_IPK_COUNT:${#NEW_IPKS[@]}"
        exit 1
    }
    NEW_IPK="${NEW_IPKS[0]}"
    verify_ipk "$NEW_IPK" "$NEW_FULL_VERSION" "$NEW_CORE_SHA"

    NEW_IPK_ABS="$(readlink -f "$NEW_IPK")"
    for F in "$BIN_DIR"/openclash-core-meta_*.ipk; do
        [ -f "$F" ] || continue
        [ "$(readlink -f "$F")" = "$NEW_IPK_ABS" ] && continue
        mv -f "$F" "$BACKUP/old-ipks/"
    done

    echo "OPENCLASH_CORE_PACKAGE_VERSION=$NEW_FULL_VERSION"
    echo "OPENCLASH_CORE_IPK=$NEW_IPK_ABS"
    echo "OPENCLASH_CORE_IPK_SHA256=$(sha256sum "$NEW_IPK" | awk '{print $1}')"
    echo "OPENCLASH_CORE_BACKUP=$BACKUP"
    echo "OPENCLASH_CORE_BUILD_LOG=$LOGDIR"
    echo 'OPENCLASH_CORE_UPDATE=PASS'
fi

if [ "$CORE_ONLY" -eq 1 ]; then
    CORE_COMMITTED=1
    echo 'R3MINI_ONECLICK_UPDATE=CORE_ONLY_PASS'
    echo 'AUTO_FLASH=NO'
    exit 0
fi

CORE_MAKEFILE_SHA_BEFORE_SOURCE_UPDATER="$(sha256sum "$MAKEFILE" | awk '{print $1}')"
CORE_BINARY_SHA_BEFORE_SOURCE_UPDATER="$(sha256sum "$CORE" | awk '{print $1}')"

echo '===== OPENCLASH / PASSWALL SOURCE UPDATE ====='
bash "$SOURCE_UPDATER" "$ROOT"

[ "$(sha256sum "$MAKEFILE" | awk '{print $1}')" = \
  "$CORE_MAKEFILE_SHA_BEFORE_SOURCE_UPDATER" ] || {
    echo 'ERROR=SOURCE_UPDATER_CHANGED_CORE_MAKEFILE' >&2
    exit 1
}
[ "$(sha256sum "$CORE" | awk '{print $1}')" = \
  "$CORE_BINARY_SHA_BEFORE_SOURCE_UPDATER" ] || {
    echo 'ERROR=SOURCE_UPDATER_CHANGED_CORE_BINARY' >&2
    exit 1
}

CORE_COMMITTED=1
echo 'R3MINI_OPENCLASH_PASSWALL_CORE_ONECLICK=PASS'
echo 'AUTO_FLASH=NO'
