#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export MAKEFLAGS=

ROOT54='/home/ht/237'
ROOT612='/home/ht/237-6.12'
MODE="${1:---apply}"
ROLLBACK_ARG="${2:-}"

EEPROM_SHA='a66c08a45ee87f1125cd45f9cfdbbb82d43f26391e6c6de9c58db2b96f6af3c9'
DONOR_BACKEND_SHA='688994de022125d05c3e53c5d250c9ec0a2b3637caa1409dac8d396b84506154'
DONOR_CONN_PATCH_SHA='ac83d31e6954d53484b065763035bf293eec552962244d98049b80798cc7335d'
PORTED_BACKEND_SHA='a59d1632b693e02f356c0b81e45eb73404d34aea3325d28f9ff5a24187276bc2'
MTWIFI_SOURCE_ARCHIVE_SHA='15f277f23751a7801dd729576d3aeb3cc63e84f2cd736a6be5dbc42d745e9892'
MTWIFI_EE_FLASH_SOURCE_SHA='f6dd796a7875c7145b5372e01e8d4e46237d476d874e704af8ed5ce6e51d5a63'
MTWIFI_PATCH_PRISTINE_SHA='6e9eb711d9b437cc7783da3de7598fa287d8a28162f6b9a8f6462f421eb65106'
MTWIFI_PATCH_APPLIED_SHA='e857d11a30eba1dff7f4c9799b2ed55b18015ba81574d56bf46c00e05dd5c337'

DTS54_REL='target/linux/mediatek/files-5.4/arch/arm64/boot/dts/mediatek/mt7986a-bananapi-bpi-r3mini-emmc.dts'
DTS54_NAND_REL='target/linux/mediatek/files-5.4/arch/arm64/boot/dts/mediatek/mt7986a-bananapi-bpi-r3mini-nand.dts'
MTWIFI_REL='package/mtk/drivers/mt_wifi/files/eeprom-flash-api.patch'
CONN_REL='package/mtk/drivers/conninfra/src/base/osal.c'
BACKEND_REL='target/linux/mediatek/patches-5.4/999-zzz-5203-mtk-wifi_utility-add-universal-eeprom-read-write-backend.patch'
MTWIFI_SOURCE_ARCHIVE_REL='dl/mt798x-7.6.6.1-src.tar.xz'

DTS54="$ROOT54/$DTS54_REL"
DTS54_NAND="$ROOT54/$DTS54_NAND_REL"
MTWIFI="$ROOT54/$MTWIFI_REL"
CONN="$ROOT54/$CONN_REL"
BACKEND54="$ROOT54/$BACKEND_REL"
MTWIFI_SOURCE_ARCHIVE="$ROOT54/$MTWIFI_SOURCE_ARCHIVE_REL"

DTS612="$ROOT612/target/linux/mediatek/dts/mt7986a-bananapi-bpi-r3-mini-common.dtsi"
BACKEND612="$ROOT612/target/linux/mediatek/patches-6.12/999-zzz-5203-mtk-wifi_utility-add-universal-eeprom-read-write-backend.patch"
CONN_PATCH612="$ROOT612/package/mtk/drivers/conninfra/patches/010-use-wifi-utility-eeprom-backend.patch"
WIFI54_DIR="$ROOT54/target/linux/mediatek/files-5.4/drivers/net/wireless/wifi_utility"

LOCK="$ROOT54/.r3mini-eeprom-612-to-54.lock"
STATE_FILE="$ROOT54/.r3mini-eeprom-612-to-54.state"
STATE_TMP=''
PROOF=''
BACKUP=''
MUTATED=0
ROLLBACK_MUTATED=0
REJECTED_DIR=''
OUTPUT_HOLD=''
SUCCESS=0

die()
{
    echo "ERROR=$*" >&2
    exit 1
}

safe_regular()
{
    local path="$1"
    [ -f "$path" ] && [ ! -L "$path" ] || die "UNSAFE_OR_MISSING_FILE:$path"
}

safe_regular_under()
{
    local root="$1"
    local path="$2"
    local resolved
    local lexical
    safe_regular "$path"
    resolved="$(readlink -f -- "$path")" || die "CANNOT_RESOLVE_FILE:$path"
    lexical="$(readlink -m -- "$path")" || die "CANNOT_NORMALIZE_FILE:$path"
    [ "$resolved" = "$lexical" ] || die "FILE_HAS_SYMLINK_ANCESTOR:$path:$resolved"
    case "$resolved" in
        "$root"/*) ;;
        *) die "FILE_ESCAPES_ROOT:$path:$resolved" ;;
    esac
}

safe_directory_under()
{
    local root="$1"
    local path="$2"
    local resolved
    local lexical
    [ -d "$path" ] && [ ! -L "$path" ] || die "UNSAFE_OR_MISSING_DIRECTORY:$path"
    resolved="$(readlink -f -- "$path")" || die "CANNOT_RESOLVE_DIRECTORY:$path"
    lexical="$(readlink -m -- "$path")" || die "CANNOT_NORMALIZE_DIRECTORY:$path"
    [ "$resolved" = "$lexical" ] || die "DIRECTORY_HAS_SYMLINK_ANCESTOR:$path:$resolved"
    case "$resolved" in
        "$root"|"$root"/*) ;;
        *) die "DIRECTORY_ESCAPES_ROOT:$path:$resolved" ;;
    esac
}

cleanup()
{
    local rc=$?
    trap - ERR EXIT
    trap '' INT TERM HUP
    set +e

    if [ "$SUCCESS" -ne 1 ] && [ "$ROLLBACK_MUTATED" -eq 1 ]; then
        rollback_restore_current
        ROLLBACK_MUTATED=0
    fi

    if [ "$SUCCESS" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -n "$BACKUP" ]; then
        echo '===== AUTOMATIC SOURCE ROLLBACK ====='
        rollback_rc=0
        auto_stage="$(mktemp -d "$ROOT54/.r3mini-eeprom-auto-rollback.XXXXXX")" || rollback_rc=1
        if [ "$rollback_rc" -eq 0 ]; then
            tar -C "$auto_stage" -xpf "$BACKUP/source-before.tar" || rollback_rc=1
        fi
        if [ "$rollback_rc" -eq 0 ]; then
            (
                cd "$auto_stage" && sha256sum -c "$BACKUP/source-before.sha256"
            ) || rollback_rc=1
        fi
        if [ "$rollback_rc" -eq 0 ]; then
            install -m "$(stat -c '%a' "$auto_stage/$DTS54_REL")" "$auto_stage/$DTS54_REL" "$DTS54" || rollback_rc=1
            install -m "$(stat -c '%a' "$auto_stage/$MTWIFI_REL")" "$auto_stage/$MTWIFI_REL" "$MTWIFI" || rollback_rc=1
            install -m "$(stat -c '%a' "$auto_stage/$CONN_REL")" "$auto_stage/$CONN_REL" "$CONN" || rollback_rc=1
            rm -f -- "$BACKEND54" || rollback_rc=1
        fi
        [ -z "$auto_stage" ] || rm -rf -- "$auto_stage"
        if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] && grep -Fxq "BACKUP=$BACKUP" "$STATE_FILE"; then
            rm -f -- "$STATE_FILE" || rollback_rc=1
        fi
        if [ "$rollback_rc" -eq 0 ]; then
            echo 'R3MINI_EEPROM_54_SOURCE_ROLLBACK=PASS'
        else
            echo 'R3MINI_EEPROM_54_SOURCE_ROLLBACK=FAIL'
        fi
    fi

    case "$PROOF" in
        "$ROOT54"/.r3mini-eeprom-proof.*|"$ROOT54"/.r3mini-eeprom-rollback-stage.*)
            [ ! -e "$PROOF" ] || rm -rf -- "$PROOF"
            ;;
    esac
    case "$STATE_TMP" in
        "$ROOT54"/.r3mini-eeprom-state.*)
            [ ! -e "$STATE_TMP" ] || rm -f -- "$STATE_TMP"
            ;;
    esac

    exit "$rc"
}

signal_exit()
{
    local rc="$1"
    trap '' INT TERM HUP
    exit "$rc"
}

trap cleanup EXIT
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

for command_name in awk bash cmp cp date find flock git grep install make mkdir mktemp mv patch python3 readelf readlink rm sed sha256sum sort stat tar tee xargs; do
    command -v "$command_name" >/dev/null 2>&1 || die "MISSING_COMMAND:$command_name"
done

[ "$(pwd -P)" = "$ROOT54" ] || die "WRONG_DIRECTORY:$(pwd -P)"
[ ! -L "$ROOT54" ] && [ ! -L "$ROOT612" ] || die 'ROOT_IS_SYMLINK'
[ "$(readlink -m "$ROOT54")" = "$ROOT54" ] || die 'BAD_5_4_ROOT'
[ "$(readlink -m "$ROOT612")" = "$ROOT612" ] || die 'BAD_6_12_ROOT'

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
    safe_regular_under "$ROOT54" "$LOCK"
fi
exec 9>>"$LOCK"
flock -n 9 || die 'ANOTHER_EEPROM_PORT_IS_RUNNING'

for source_parent in "$(dirname "$DTS54")" "$(dirname "$DTS54_NAND")" "$(dirname "$MTWIFI")" "$(dirname "$CONN")" "$(dirname "$BACKEND54")"; do
    safe_directory_under "$ROOT54" "$source_parent"
done
for output_parent in "$ROOT54/bin" "$ROOT54/bin/targets" "$ROOT54/bin/targets/mediatek"; do
    [ ! -e "$output_parent" ] && [ ! -L "$output_parent" ] || safe_directory_under "$ROOT54" "$output_parent"
done
if [ -e "$BACKEND54" ] || [ -L "$BACKEND54" ]; then
    safe_regular_under "$ROOT54" "$BACKEND54"
fi

if [ "$MODE" = '--rollback' ]; then
    [ -n "$ROLLBACK_ARG" ] || die 'ROLLBACK_BACKUP_ARGUMENT_REQUIRED'
    [ -d "$ROLLBACK_ARG" ] && [ ! -L "$ROLLBACK_ARG" ] || die "UNSAFE_ROLLBACK_INPUT:$ROLLBACK_ARG"
    BACKUP_PATH="$(readlink -f -- "$ROLLBACK_ARG")" || die 'ROLLBACK_PATH_CANNOT_RESOLVE'
    case "$BACKUP_PATH" in
        /home/ht/237-backups/r3mini-eeprom-612-to-54-*) ;;
        *) die "UNSAFE_ROLLBACK_PATH:$BACKUP_PATH" ;;
    esac
    safe_directory_under "/home/ht" /home/ht/237-backups
    [ -d "$BACKUP_PATH" ] && [ ! -L "$BACKUP_PATH" ] || die "UNSAFE_ROLLBACK_DIRECTORY:$BACKUP_PATH"
    safe_regular "$BACKUP_PATH/source-before.tar"
    safe_regular "$BACKUP_PATH/source-before.tar.sha256"
    safe_regular "$BACKUP_PATH/source-before.sha256"
    printf '%s  %s\n' "$(awk '{print $1}' "$BACKUP_PATH/source-before.tar.sha256")" "$BACKUP_PATH/source-before.tar" | sha256sum -c -
    SOURCE_LIST="$(tar -tf "$BACKUP_PATH/source-before.tar")" || die 'SOURCE_BACKUP_LIST_FAILED'
    mapfile -t SOURCE_MEMBERS < <(printf '%s\n' "$SOURCE_LIST" | sort)
    mapfile -t EXPECTED_SOURCE_MEMBERS < <(printf '%s\n' "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL" | sort)
    [ "${#SOURCE_MEMBERS[@]}" -eq 3 ] || die "SOURCE_BACKUP_MEMBER_COUNT:${#SOURCE_MEMBERS[@]}"
    [ "${SOURCE_MEMBERS[*]}" = "${EXPECTED_SOURCE_MEMBERS[*]}" ] || die 'SOURCE_BACKUP_MEMBER_ALLOWLIST_MISMATCH'
    mapfile -t SOURCE_HASH_PATHS < <(awk 'length($1)==64 { print substr($0, 67) }' "$BACKUP_PATH/source-before.sha256" | sort)
    [ "${#SOURCE_HASH_PATHS[@]}" -eq 3 ] || die "SOURCE_HASH_PATH_COUNT:${#SOURCE_HASH_PATHS[@]}"
    [ "${SOURCE_HASH_PATHS[*]}" = "${EXPECTED_SOURCE_MEMBERS[*]}" ] || die 'SOURCE_HASH_PATH_ALLOWLIST_MISMATCH'
    safe_regular "$BACKUP_PATH/target-output-before.state"
    OUTPUT_STATE="$(sed -n '1p' "$BACKUP_PATH/target-output-before.state")"
    case "$OUTPUT_STATE" in
        PRESENT)
            safe_regular "$BACKUP_PATH/target-output-before.tar"
            safe_regular "$BACKUP_PATH/target-output-before.tar.sha256"
            safe_regular "$BACKUP_PATH/target-output-before.files.sha256"
            [ "$(awk 'END{print NR+0}' "$BACKUP_PATH/target-output-before.files.sha256")" -gt 0 ] || die 'TARGET_OUTPUT_HASH_MANIFEST_EMPTY'
            if awk '
                length($1) != 64 { bad=1; next }
                { path=substr($0, 67) }
                path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/ || path !~ /^bin\/targets\/mediatek\/mt7986\// { bad=1 }
                END { exit bad ? 0 : 1 }
            ' "$BACKUP_PATH/target-output-before.files.sha256"; then
                die 'TARGET_OUTPUT_HASH_PATH_ALLOWLIST_MISMATCH'
            fi
            printf '%s  %s\n' "$(awk '{print $1}' "$BACKUP_PATH/target-output-before.tar.sha256")" "$BACKUP_PATH/target-output-before.tar" | sha256sum -c -
            TARGET_LIST="$(tar -tf "$BACKUP_PATH/target-output-before.tar")" || die 'TARGET_OUTPUT_BACKUP_LIST_FAILED'
            if printf '%s\n' "$TARGET_LIST" | awk '
                /^\// || /(^|\/)\.\.($|\/)/ || $0 !~ /^bin\/targets\/mediatek\/mt7986(\/|$)/ { bad=1 }
                END { exit bad ? 0 : 1 }
            '; then
                die 'TARGET_OUTPUT_BACKUP_MEMBER_ALLOWLIST_MISMATCH'
            fi
            ;;
        ABSENT) ;;
        *) die "BAD_TARGET_OUTPUT_STATE:$OUTPUT_STATE" ;;
    esac

    ROLLBACK_STAGE="$(mktemp -d "$ROOT54/.r3mini-eeprom-rollback-stage.XXXXXX")"
    PROOF="$ROLLBACK_STAGE"
    REJECTED_DIR="$BACKUP_PATH/rejected-before-rollback-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir "$REJECTED_DIR"
    tar -C "$ROLLBACK_STAGE" -xpf "$BACKUP_PATH/source-before.tar"
    (
        cd "$ROLLBACK_STAGE"
        sha256sum -c "$BACKUP_PATH/source-before.sha256"
    )
    if [ "$OUTPUT_STATE" = PRESENT ]; then
        mkdir "$ROLLBACK_STAGE/target-output"
        tar -C "$ROLLBACK_STAGE/target-output" -xpf "$BACKUP_PATH/target-output-before.tar"
        if find "$ROLLBACK_STAGE/target-output/bin/targets/mediatek/mt7986" -xdev \( -type l -o \( ! -type f ! -type d \) \) -print -quit | grep -q .; then
            die 'UNSAFE_ENTRY_IN_STAGED_TARGET_OUTPUT'
        fi
        (
            cd "$ROLLBACK_STAGE/target-output"
            sha256sum -c "$BACKUP_PATH/target-output-before.files.sha256"
        )
    fi

    (
        cd "$ROOT54"
        present=()
        : > "$REJECTED_DIR/source-current.present"
        for rel in "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL" "$BACKEND_REL"; do
            if [ -e "$rel" ] || [ -L "$rel" ]; then
                safe_regular_under "$ROOT54" "$ROOT54/$rel"
                present+=("$rel")
                printf '%s\n' "$rel" >> "$REJECTED_DIR/source-current.present"
            fi
        done
        [ "${#present[@]}" -eq 0 ] || tar -cpf "$REJECTED_DIR/source-current.tar" "${present[@]}"
    )
    if [ -f "$REJECTED_DIR/source-current.tar" ]; then
        sha256sum "$REJECTED_DIR/source-current.tar" > "$REJECTED_DIR/source-current.tar.sha256"
    fi
    if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
        safe_regular_under "$ROOT54" "$STATE_FILE"
        cp -p "$STATE_FILE" "$REJECTED_DIR/state-current"
        printf '%s\n' PRESENT > "$REJECTED_DIR/state-current.state"
    else
        printf '%s\n' ABSENT > "$REJECTED_DIR/state-current.state"
    fi
    if [ -d "$ROOT54/bin/targets/mediatek/mt7986" ] && [ ! -L "$ROOT54/bin/targets/mediatek/mt7986" ]; then
        safe_directory_under "$ROOT54" "$ROOT54/bin/targets/mediatek/mt7986"
        if find "$ROOT54/bin/targets/mediatek/mt7986" -xdev \( -type l -o \( ! -type f ! -type d \) \) -print -quit | grep -q .; then
            die 'UNSAFE_ENTRY_IN_CURRENT_TARGET_OUTPUT'
        fi
        tar -C "$ROOT54" -cpf "$REJECTED_DIR/target-output-current.tar" bin/targets/mediatek/mt7986
        sha256sum "$REJECTED_DIR/target-output-current.tar" > "$REJECTED_DIR/target-output-current.tar.sha256"
        printf '%s\n' PRESENT > "$REJECTED_DIR/target-output-current.state"
    elif [ ! -e "$ROOT54/bin/targets/mediatek/mt7986" ] && [ ! -L "$ROOT54/bin/targets/mediatek/mt7986" ]; then
        printf '%s\n' ABSENT > "$REJECTED_DIR/target-output-current.state"
    else
        die 'UNSAFE_CURRENT_TARGET_OUTPUT'
    fi

    ROLLBACK_MUTATED=0
    rollback_restore_current()
    {
        local recovery_rc=0
        set +e
        echo '===== ROLLBACK TRANSACTION RECOVERY ====='
        rm -f -- "$DTS54" "$MTWIFI" "$CONN" "$BACKEND54" || recovery_rc=1
        if [ -f "$REJECTED_DIR/source-current.tar" ]; then
            tar -C "$ROOT54" -xpf "$REJECTED_DIR/source-current.tar" || recovery_rc=1
        fi
        rm -rf -- "$ROOT54/bin/targets/mediatek/mt7986" || recovery_rc=1
        if [ -n "$OUTPUT_HOLD" ] && [ -d "$OUTPUT_HOLD" ] && [ ! -L "$OUTPUT_HOLD" ]; then
            mv -fT -- "$OUTPUT_HOLD" "$ROOT54/bin/targets/mediatek/mt7986" || recovery_rc=1
        elif [ "$(sed -n '1p' "$REJECTED_DIR/target-output-current.state")" = PRESENT ]; then
            tar -C "$ROOT54" -xpf "$REJECTED_DIR/target-output-current.tar" || recovery_rc=1
        fi
        rm -f -- "$STATE_FILE" || recovery_rc=1
        if [ "$(sed -n '1p' "$REJECTED_DIR/state-current.state")" = PRESENT ]; then
            install -m 0600 "$REJECTED_DIR/state-current" "$STATE_FILE" || recovery_rc=1
        fi
        if [ "$recovery_rc" -eq 0 ]; then
            echo 'R3MINI_EEPROM_54_ROLLBACK_TRANSACTION_RECOVERY=PASS'
        else
            echo 'R3MINI_EEPROM_54_ROLLBACK_TRANSACTION_RECOVERY=FAIL'
        fi
        return "$recovery_rc"
    }
    OUTPUT_HOLD="$ROOT54/bin/targets/mediatek/.mt7986.eeprom-rollback-hold.$$"
    [ ! -e "$OUTPUT_HOLD" ] && [ ! -L "$OUTPUT_HOLD" ] || die "OUTPUT_HOLD_COLLISION:$OUTPUT_HOLD"
    ROLLBACK_MUTATED=1
    install -m "$(stat -c '%a' "$ROLLBACK_STAGE/$DTS54_REL")" "$ROLLBACK_STAGE/$DTS54_REL" "$DTS54"
    install -m "$(stat -c '%a' "$ROLLBACK_STAGE/$MTWIFI_REL")" "$ROLLBACK_STAGE/$MTWIFI_REL" "$MTWIFI"
    install -m "$(stat -c '%a' "$ROLLBACK_STAGE/$CONN_REL")" "$ROLLBACK_STAGE/$CONN_REL" "$CONN"
    rm -f -- "$BACKEND54"
    if [ -d "$ROOT54/bin/targets/mediatek/mt7986" ]; then
        mv -T -- "$ROOT54/bin/targets/mediatek/mt7986" "$OUTPUT_HOLD"
    fi
    if [ "$OUTPUT_STATE" = PRESENT ]; then
        mv -T -- "$ROLLBACK_STAGE/target-output/bin/targets/mediatek/mt7986" "$ROOT54/bin/targets/mediatek/mt7986"
    fi
    (
        cd "$ROOT54"
        sha256sum -c "$BACKUP_PATH/source-before.sha256"
    )
    [ ! -e "$BACKEND54" ] && [ ! -L "$BACKEND54" ] || die 'BACKEND_PATCH_REMAINS_AFTER_ROLLBACK'
    if [ "$OUTPUT_STATE" = PRESENT ]; then
        [ -d "$ROOT54/bin/targets/mediatek/mt7986" ] && [ ! -L "$ROOT54/bin/targets/mediatek/mt7986" ] || die 'TARGET_OUTPUT_RESTORE_FAILED'
        (
            cd "$ROOT54"
            sha256sum -c "$BACKUP_PATH/target-output-before.files.sha256"
        )
    else
        [ ! -e "$ROOT54/bin/targets/mediatek/mt7986" ] && [ ! -L "$ROOT54/bin/targets/mediatek/mt7986" ] || die 'TARGET_OUTPUT_ABSENT_RESTORE_FAILED'
    fi
    rm -f -- "$STATE_FILE"
    ROLLBACK_MUTATED=0
    if [ -n "$OUTPUT_HOLD" ] && [ -d "$OUTPUT_HOLD" ]; then
        rm -rf -- "$OUTPUT_HOLD"
    fi
    rm -rf -- "$ROLLBACK_STAGE"
    PROOF=''

    echo "ROLLBACK_REJECTED_STATE=$REJECTED_DIR"
    echo "ROLLBACK_RESTORED_FROM=$BACKUP_PATH"
    echo 'R3MINI_EEPROM_612_TO_54_ROLLBACK=PASS'
    echo 'NOTE=AFFECTED_BUILD_CACHES_REMAIN; CLEAN BEFORE THE NEXT REBUILD'
    SUCCESS=1
    exit 0
fi

safe_regular_under "$ROOT54" "$DTS54"
safe_regular_under "$ROOT54" "$DTS54_NAND"
safe_regular_under "$ROOT54" "$MTWIFI"
safe_regular_under "$ROOT54" "$CONN"
safe_regular "$MTWIFI_SOURCE_ARCHIVE"
safe_regular_under "$ROOT612" "$DTS612"
safe_regular_under "$ROOT612" "$BACKEND612"
safe_regular_under "$ROOT612" "$CONN_PATCH612"
safe_directory_under "$ROOT54" "$WIFI54_DIR"
safe_regular_under "$ROOT54" "$WIFI54_DIR/Makefile"
safe_regular_under "$ROOT54" "$WIFI54_DIR/mt_wifi_mtd.c"
safe_regular_under "$ROOT54" "$WIFI54_DIR/pci_mediatek_rbus.c"

grep -Fxq 'KERNEL_PATCHVER:=5.4' "$ROOT54/target/linux/mediatek/Makefile" || die 'TARGET_5_4_CONTRACT_FAILED'
grep -Fxq 'KERNEL_PATCHVER:=6.12' "$ROOT612/target/linux/mediatek/Makefile" || die 'DONOR_6_12_CONTRACT_FAILED'
! grep -Fq 'mediatek,eeprom-data' "$DTS54_NAND" || die 'NAND_DTS_MUST_KEEP_ITS_OWN_FACTORY_EEPROM'
printf '%s  %s\n' "$DONOR_BACKEND_SHA" "$BACKEND612" | sha256sum -c -
printf '%s  %s\n' "$DONOR_CONN_PATCH_SHA" "$CONN_PATCH612" | sha256sum -c -
printf '%s  %s\n' "$MTWIFI_SOURCE_ARCHIVE_SHA" "$MTWIFI_SOURCE_ARCHIVE" | sha256sum -c -

PROOF="$(mktemp -d "$ROOT54/.r3mini-eeprom-proof.XXXXXX")"
mkdir -p "$PROOF/candidates" "$PROOF/kernel/drivers/net/wireless" "$PROOF/conn/base" \
    "$PROOF/mtwifi/mt_wifi/embedded/common"

python3 - "$DTS612" "$PROOF/eeprom.bin" <<'PY_EXTRACT'
import hashlib
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
match = re.search(r'mediatek,eeprom-data\s*=\s*<(.*?)>\s*;', source, re.S)
if not match:
    raise SystemExit('donor eeprom-data property is missing')
values = re.findall(r'0x[0-9a-fA-F]+', match.group(1))
if len(values) != 1024:
    raise SystemExit(f'donor EEPROM cell count is {len(values)}, expected 1024')
payload = b''.join(int(value, 16).to_bytes(4, 'big') for value in values)
if len(payload) != 4096:
    raise SystemExit('donor EEPROM length is not 4096')
pathlib.Path(sys.argv[2]).write_bytes(payload)
print(f'DONOR_EEPROM_WORDS={len(values)}')
print(f'DONOR_EEPROM_SHA256={hashlib.sha256(payload).hexdigest()}')
PY_EXTRACT

printf '%s  %s\n' "$EEPROM_SHA" "$PROOF/eeprom.bin" | sha256sum -c -

python3 - "$BACKEND612" "$PROOF/candidates/backend.patch" <<'PY_BACKEND'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
old = '#include <linux/unaligned.h>'
new = '#include <asm/unaligned.h>'
if source.count(old) != 1:
    raise SystemExit('unexpected donor unaligned include count')
source = source.replace(old, new, 1)
pathlib.Path(sys.argv[2]).write_text(source, encoding='utf-8', newline='\n')
PY_BACKEND

printf '%s  %s\n' "$PORTED_BACKEND_SHA" "$PROOF/candidates/backend.patch" | sha256sum -c -

state_count=0
if [ -e "$BACKEND54" ]; then
    safe_regular "$BACKEND54"
    state_count=$((state_count + 1))
fi
grep -Fq 'mediatek,eeprom-data' "$DTS54" && state_count=$((state_count + 1)) || true
grep -Fq 'mt_eeprom_read_wifi(_offset' "$MTWIFI" && state_count=$((state_count + 1)) || true
grep -Fq 'mt_eeprom_read_wifi(offset, size, value);' "$CONN" && state_count=$((state_count + 1)) || true

case "$state_count" in
    0) SOURCE_STATE='PRISTINE' ;;
    4) SOURCE_STATE='APPLIED' ;;
    *) die "PARTIAL_EEPROM_PORT_STATE:$state_count/4" ;;
esac
echo "SOURCE_STATE=$SOURCE_STATE"
case "$SOURCE_STATE" in
    PRISTINE) MTWIFI_PATCH_EXPECTED_SHA="$MTWIFI_PATCH_PRISTINE_SHA" ;;
    APPLIED) MTWIFI_PATCH_EXPECTED_SHA="$MTWIFI_PATCH_APPLIED_SHA" ;;
    *) die "UNKNOWN_SOURCE_STATE:$SOURCE_STATE" ;;
esac
printf '%s  %s\n' "$MTWIFI_PATCH_EXPECTED_SHA" "$MTWIFI" | sha256sum -c -

cp -a "$WIFI54_DIR" "$PROOF/kernel/drivers/net/wireless/wifi_utility"
patch --batch --fuzz=0 -p1 -d "$PROOF/kernel" < "$PROOF/candidates/backend.patch"
grep -Fq '#include <asm/unaligned.h>' "$PROOF/kernel/drivers/net/wireless/wifi_utility/mt_wifi_of.c" || die 'BACKEND_5_4_HEADER_FIX_FAILED'
grep -Fq 'EXPORT_SYMBOL(mt_eeprom_read_wifi);' "$PROOF/kernel/drivers/net/wireless/wifi_utility/mt_wifi_eeprom.c" || die 'BACKEND_EXPORT_MISSING'

MTWIFI_PATCH_PROOF="$MTWIFI"
if [ "$SOURCE_STATE" = 'PRISTINE' ]; then

python3 - "$MTWIFI" "$PROOF/candidates/eeprom-flash-api.patch" <<'PY_MTWIFI'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding='utf-8')
old = '\n'.join((
    ' int mt_mtd_write_nm_wifi(char *name, loff_t to, size_t len, const u_char *buf);',
    ' int mt_mtd_read_nm_wifi(char *name, loff_t from, size_t len, u_char *buf);',
    ' ',
    ' #define flash_read(_ctrl, _ptr, _offset, _len) mt_mtd_read_nm_wifi("Factory", _offset, (size_t)_len, _ptr)',
    ' #define flash_write(_ctrl, _ptr, _offset, _len) mt_mtd_write_nm_wifi("Factory", _offset, (size_t)_len, _ptr)',
    '',
))
new = '\n'.join((
    ' int mt_mtd_write_nm_wifi(char *name, loff_t to, size_t len, const u_char *buf);',
    '-int mt_mtd_read_nm_wifi(char *name, loff_t from, size_t len, u_char *buf);',
    '+int mt_eeprom_read_wifi(loff_t from, size_t len, u_char *buf);',
    ' ',
    '-#define flash_read(_ctrl, _ptr, _offset, _len) mt_mtd_read_nm_wifi("Factory", _offset, (size_t)_len, _ptr)',
    '+#define flash_read(_ctrl, _ptr, _offset, _len) mt_eeprom_read_wifi(_offset, (size_t)_len, _ptr)',
    ' #define flash_write(_ctrl, _ptr, _offset, _len) mt_mtd_write_nm_wifi("Factory", _offset, (size_t)_len, _ptr)',
    '',
))
if source.count(old) != 1:
    raise SystemExit('unexpected mt_wifi EEPROM patch state')
pathlib.Path(sys.argv[2]).write_text(source.replace(old, new, 1), encoding='utf-8', newline='\n')
PY_MTWIFI
printf '%s  %s\n' "$MTWIFI_PATCH_APPLIED_SHA" "$PROOF/candidates/eeprom-flash-api.patch" | sha256sum -c -
MTWIFI_PATCH_PROOF="$PROOF/candidates/eeprom-flash-api.patch"

cp -p "$CONN" "$PROOF/conn/base/osal.c"
patch --batch --fuzz=0 -p1 -d "$PROOF/conn" < "$CONN_PATCH612"
cp -p "$PROOF/conn/base/osal.c" "$PROOF/candidates/osal.c"
grep -Fq 'mt_eeprom_read_wifi(offset, size, value);' "$PROOF/candidates/osal.c" || die 'CONNINFRA_BACKEND_CALL_MISSING'

python3 - "$DTS612" "$DTS54" "$PROOF/candidates/r3mini-emmc.dts" <<'PY_DTS'
import pathlib
import re
import sys

donor = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
target = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
target = re.sub(r'[ \t]+(?=\n|\Z)', '', target)
match = re.search(r'mediatek,eeprom-data\s*=\s*<(.*?)>\s*;', donor, re.S)
if not match:
    raise SystemExit('donor eeprom-data missing')
values = re.findall(r'0x[0-9a-fA-F]+', match.group(1))
if len(values) != 1024:
    raise SystemExit('donor EEPROM cell count changed')
if 'mediatek,eeprom-data' in target:
    raise SystemExit('target DTS already contains eeprom-data')
anchor = '\n/*\n&wbsys {'
if target.count(anchor) != 1:
    raise SystemExit('5.4 wbsys comment anchor changed')
lines = []
for index in range(0, len(values), 8):
    prefix = '\tmediatek,eeprom-data = <' if index == 0 else '\t\t'
    suffix = '>;' if index + 8 >= len(values) else ''
    lines.append(prefix + ' '.join(values[index:index + 8]) + suffix)
block = '\n&wbsys {\n\tstatus = "okay";\n' + '\n'.join(lines) + '\n};\n'
target = target.replace(anchor, block + anchor, 1)
if re.search(r'[ \t]+(?=\n|\Z)', target):
    raise SystemExit('generated 5.4 DTS contains trailing whitespace')
pathlib.Path(sys.argv[3]).write_text(target, encoding='utf-8', newline='\n')
PY_DTS

fi

tar -xJOf "$MTWIFI_SOURCE_ARCHIVE" mt_wifi/embedded/common/ee_flash.c \
    > "$PROOF/mtwifi/mt_wifi/embedded/common/ee_flash.c"
printf '%s  %s\n' "$MTWIFI_EE_FLASH_SOURCE_SHA" \
    "$PROOF/mtwifi/mt_wifi/embedded/common/ee_flash.c" | sha256sum -c -
patch --dry-run --batch --fuzz=0 -p1 -d "$PROOF/mtwifi" < "$MTWIFI_PATCH_PROOF"
echo 'MT_WIFI_EEPROM_PATCH_DRY_RUN=PASS'
patch --batch --fuzz=0 -p1 -d "$PROOF/mtwifi" < "$MTWIFI_PATCH_PROOF"
grep -Fxq 'int mt_eeprom_read_wifi(loff_t from, size_t len, u_char *buf);' \
    "$PROOF/mtwifi/mt_wifi/embedded/common/ee_flash.c" || die 'MT_WIFI_PATCH_PROOF_DECLARATION_MISSING'
grep -Fxq '#define flash_read(_ctrl, _ptr, _offset, _len) mt_eeprom_read_wifi(_offset, (size_t)_len, _ptr)' \
    "$PROOF/mtwifi/mt_wifi/embedded/common/ee_flash.c" || die 'MT_WIFI_PATCH_PROOF_READ_PATH_MISSING'
! grep -Fxq '#define flash_read(_ctrl, _ptr, _offset, _len) mt_mtd_read_nm_wifi("Factory", _offset, (size_t)_len, _ptr)' \
    "$PROOF/mtwifi/mt_wifi/embedded/common/ee_flash.c" || die 'MT_WIFI_PATCH_PROOF_OLD_READ_PATH_REMAINS'
grep -Fxq '#define flash_write(_ctrl, _ptr, _offset, _len) mt_mtd_write_nm_wifi("Factory", _offset, (size_t)_len, _ptr)' \
    "$PROOF/mtwifi/mt_wifi/embedded/common/ee_flash.c" || die 'MT_WIFI_PATCH_PROOF_WRITE_PATH_CHANGED'
echo 'MT_WIFI_EEPROM_PATCH_PROOF=PASS'

verify_source_contract()
{
    local expected_backend="$1"
    python3 - "$DTS54" "$MTWIFI" "$CONN" "$EEPROM_SHA" <<'PY_VERIFY_DTS'
import hashlib
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
matches = re.findall(r'mediatek,eeprom-data\s*=\s*<(.*?)>\s*;', source, re.S)
if len(matches) != 1:
    raise SystemExit(f'5.4 EEPROM property count is {len(matches)}, expected 1')
values = re.findall(r'0x[0-9a-fA-F]+', matches[0])
payload = b''.join(int(value, 16).to_bytes(4, 'big') for value in values)
digest = hashlib.sha256(payload).hexdigest()
if len(values) != 1024 or len(payload) != 4096 or digest != sys.argv[4]:
    raise SystemExit(f'5.4 EEPROM contract failed words={len(values)} bytes={len(payload)} sha={digest}')
active = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
wbsys = list(re.finditer(r'(?m)^&wbsys\s*\{', active))
if len(wbsys) != 1:
    raise SystemExit(f'active &wbsys block count is {len(wbsys)}, expected 1')
start = wbsys[0].start()
depth = 0
end = None
for index in range(active.find('{', start), len(active)):
    if active[index] == '{':
        depth += 1
    elif active[index] == '}':
        depth -= 1
        if depth == 0:
            end = index + 1
            break
if end is None or 'mediatek,eeprom-data' not in active[start:end]:
    raise SystemExit('EEPROM property is not directly contained by the active &wbsys block')

mtwifi = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
patch_lines = mtwifi.splitlines()
for label, needle, count in (
    ('hunk header', '@@ -27,113 +27,12 @@', 1),
    ('deleted old declaration', '-int mt_mtd_read_nm_wifi(char *name, loff_t from, size_t len, u_char *buf);', 1),
    ('added new declaration', '+int mt_eeprom_read_wifi(loff_t from, size_t len, u_char *buf);', 1),
    ('deleted old read macro', '-#define flash_read(_ctrl, _ptr, _offset, _len) mt_mtd_read_nm_wifi("Factory", _offset, (size_t)_len, _ptr)', 1),
    ('added new read macro', '+#define flash_read(_ctrl, _ptr, _offset, _len) mt_eeprom_read_wifi(_offset, (size_t)_len, _ptr)', 1),
    ('unchanged write context', ' #define flash_write(_ctrl, _ptr, _offset, _len) mt_mtd_write_nm_wifi("Factory", _offset, (size_t)_len, _ptr)', 1),
    ('invalid new declaration context', ' int mt_eeprom_read_wifi(loff_t from, size_t len, u_char *buf);', 0),
    ('invalid new read context', ' #define flash_read(_ctrl, _ptr, _offset, _len) mt_eeprom_read_wifi(_offset, (size_t)_len, _ptr)', 0),
):
    actual = patch_lines.count(needle)
    if actual != count:
        raise SystemExit(f'mt_wifi {label} count is {actual}, expected {count}')

conn = pathlib.Path(sys.argv[3]).read_text(encoding='utf-8')
if conn.count('int mt_eeprom_read_wifi(loff_t from, size_t len, unsigned char *buf);') != 1:
    raise SystemExit('conninfra EEPROM backend declaration count mismatch')
if conn.count('mt_eeprom_read_wifi(offset, size, value);') != 1:
    raise SystemExit('conninfra EEPROM backend call count mismatch')
if 'get_mtd_device_nm(name)' in conn or 'mtd_read(mtd, offset, size' in conn:
    raise SystemExit('conninfra still contains the direct Factory MTD read body')
print(f'EEPROM_5_4_WORDS={len(values)}')
print(f'EEPROM_5_4_SHA256={digest}')
PY_VERIFY_DTS
    cmp -s "$BACKEND54" "$expected_backend" || die 'INSTALLED_BACKEND_DIFFERS_FROM_DONOR_PORT'
    grep -Fq 'int mt_eeprom_read_wifi(loff_t from, size_t len, u_char *buf);' "$MTWIFI" || die 'MT_WIFI_READ_BACKEND_NOT_CONNECTED'
    grep -Fq '#define flash_read(_ctrl, _ptr, _offset, _len) mt_eeprom_read_wifi(_offset, (size_t)_len, _ptr)' "$MTWIFI" || die 'MT_WIFI_READ_MACRO_NOT_CONNECTED'
    grep -Fq '#define flash_write(_ctrl, _ptr, _offset, _len) mt_mtd_write_nm_wifi("Factory", _offset, (size_t)_len, _ptr)' "$MTWIFI" || die 'MT_WIFI_WRITE_PATH_CHANGED'
    grep -Fq 'mt_eeprom_read_wifi(offset, size, value);' "$CONN" || die 'CONNINFRA_READ_BACKEND_NOT_CONNECTED'
}

load_applied_state()
{
    safe_regular_under "$ROOT54" "$STATE_FILE"
    STATE_BACKUP="$(sed -n 's/^BACKUP=//p' "$STATE_FILE")"
    STATE_DIGESTS="$(sed -n 's/^SOURCE_DIGESTS=//p' "$STATE_FILE")"
    [ "$(awk '/^BACKUP=/{n++} END{print n+0}' "$STATE_FILE")" -eq 1 ] || die 'STATE_BACKUP_FIELD_COUNT'
    [ "$(awk '/^SOURCE_DIGESTS=/{n++} END{print n+0}' "$STATE_FILE")" -eq 1 ] || die 'STATE_DIGEST_FIELD_COUNT'
    [ -d "$STATE_BACKUP" ] && [ ! -L "$STATE_BACKUP" ] || die "UNSAFE_STATE_BACKUP_INPUT:$STATE_BACKUP"
    STATE_BACKUP="$(readlink -f -- "$STATE_BACKUP")" || die 'STATE_BACKUP_CANNOT_RESOLVE'
    [ -d "$STATE_BACKUP" ] && [ ! -L "$STATE_BACKUP" ] || die "UNSAFE_STATE_BACKUP_DIRECTORY:$STATE_BACKUP"
    [[ "$STATE_BACKUP" =~ ^/home/ht/237-backups/r3mini-eeprom-612-to-54-[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || die "UNSAFE_STATE_BACKUP:$STATE_BACKUP"
    [ "$STATE_DIGESTS" = "$STATE_BACKUP/source-applied.sha256" ] || die "STATE_DIGEST_PATH_MISMATCH:$STATE_DIGESTS"
    safe_regular_under "/home/ht/237-backups" "$STATE_DIGESTS"
    mapfile -t STATE_HASH_PATHS < <(awk 'length($1)==64 { print substr($0, 67) }' "$STATE_DIGESTS" | sort)
    mapfile -t EXPECTED_STATE_HASH_PATHS < <(printf '%s\n' "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL" "$BACKEND_REL" | sort)
    [ "${#STATE_HASH_PATHS[@]}" -eq 4 ] || die "STATE_HASH_PATH_COUNT:${#STATE_HASH_PATHS[@]}"
    [ "${STATE_HASH_PATHS[*]}" = "${EXPECTED_STATE_HASH_PATHS[*]}" ] || die 'STATE_HASH_PATH_ALLOWLIST_MISMATCH'
    (
        cd "$ROOT54"
        sha256sum -c "$STATE_DIGESTS"
    )
}

if [ "$SOURCE_STATE" = 'APPLIED' ]; then
    verify_source_contract "$PROOF/candidates/backend.patch"
fi

if [ "$MODE" = '--apply' ]; then
    if [ "$SOURCE_STATE" = 'APPLIED' ]; then
        load_applied_state
        echo "EEPROM_PORT_BACKUP=$STATE_BACKUP"
        echo "ROLLBACK_COMMAND=cd $ROOT54 && ./port-r3mini-eeprom-6.12-to-5.4.sh --rollback $STATE_BACKUP"
        echo 'R3MINI_EEPROM_612_TO_54_APPLY=ALREADY_APPLIED'
        SUCCESS=1
        exit 0
    fi

    [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || die "STALE_OR_UNSAFE_STATE_FILE:$STATE_FILE"

    STAMP="$(date +%Y%m%d-%H%M%S)-$$"
    BACKUP="/home/ht/237-backups/r3mini-eeprom-612-to-54-$STAMP"
    mkdir -p /home/ht/237-backups
    safe_directory_under "/home/ht" /home/ht/237-backups
    mkdir "$BACKUP"
    (
        cd "$ROOT54"
        tar -cpf "$BACKUP/source-before.tar" "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL"
        sha256sum "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL" > "$BACKUP/source-before.sha256"
        [ ! -f .config ] || cp -p .config "$BACKUP/config.reference"
        git diff -- "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL" > "$BACKUP/relevant-diff-before.patch" || true
    )
    if [ -d "$ROOT54/bin/targets/mediatek/mt7986" ] && [ ! -L "$ROOT54/bin/targets/mediatek/mt7986" ]; then
        if find "$ROOT54/bin/targets/mediatek/mt7986" -xdev \( -type l -o \( ! -type f ! -type d \) \) -print -quit | grep -q .; then
            die 'UNSAFE_ENTRY_IN_TARGET_OUTPUT_BEFORE_APPLY'
        fi
        printf '%s\n' PRESENT > "$BACKUP/target-output-before.state"
        tar -C "$ROOT54" -cpf "$BACKUP/target-output-before.tar" bin/targets/mediatek/mt7986
        sha256sum "$BACKUP/target-output-before.tar" > "$BACKUP/target-output-before.tar.sha256"
        (
            cd "$ROOT54"
            find bin/targets/mediatek/mt7986 -type f -print0 | sort -z | xargs -0 -r sha256sum
        ) > "$BACKUP/target-output-before.files.sha256"
    elif [ ! -e "$ROOT54/bin/targets/mediatek/mt7986" ] && [ ! -L "$ROOT54/bin/targets/mediatek/mt7986" ]; then
        printf '%s\n' ABSENT > "$BACKUP/target-output-before.state"
    else
        die 'UNSAFE_TARGET_OUTPUT_BEFORE_APPLY'
    fi
    sha256sum "$BACKUP/source-before.tar" > "$BACKUP/source-before.tar.sha256"
    cp -p "$PROOF/eeprom.bin" "$BACKUP/r3mini-eeprom-4096.bin"
    cp -p "$PROOF/candidates/backend.patch" "$BACKUP/backend-5.4.patch"

    MUTATED=1
    install -m "$(stat -c '%a' "$DTS54")" "$PROOF/candidates/r3mini-emmc.dts" "$DTS54"
    install -m "$(stat -c '%a' "$MTWIFI")" "$PROOF/candidates/eeprom-flash-api.patch" "$MTWIFI"
    install -m "$(stat -c '%a' "$CONN")" "$PROOF/candidates/osal.c" "$CONN"
    install -m 0644 "$PROOF/candidates/backend.patch" "$BACKEND54"

    verify_source_contract "$PROOF/candidates/backend.patch"
    git diff --check -- "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL" "$BACKEND_REL"

    SOURCE_DIGESTS="$BACKUP/source-applied.sha256"
    (
        cd "$ROOT54"
        sha256sum "$DTS54_REL" "$MTWIFI_REL" "$CONN_REL" "$BACKEND_REL" > "$SOURCE_DIGESTS"
    )
    STATE_TMP="$(mktemp "$ROOT54/.r3mini-eeprom-state.XXXXXX")"
    {
        printf 'BACKUP=%s\n' "$BACKUP"
        printf 'SOURCE_DIGESTS=%s\n' "$SOURCE_DIGESTS"
    } > "$STATE_TMP"
    chmod 0600 "$STATE_TMP"
    mv -fT -- "$STATE_TMP" "$STATE_FILE"
    STATE_TMP=''

    echo "EEPROM_PORT_BACKUP=$BACKUP"
    echo "ROLLBACK_COMMAND=cd $ROOT54 && ./port-r3mini-eeprom-6.12-to-5.4.sh --rollback $BACKUP"
    echo 'FACTORY_OR_EFUSE_WRITTEN=NO'
    echo 'BUILD_RUN=NO'
    echo 'R3MINI_EEPROM_612_TO_54_APPLY=PASS'
    SUCCESS=1
    exit 0
fi

[ "$MODE" = '--build' ] || [ "$MODE" = '--verify' ] || die "UNKNOWN_MODE:$MODE"
[ "$SOURCE_STATE" = 'APPLIED' ] || die 'RUN_APPLY_FIRST'
load_applied_state

verify_config_contract()
{
    safe_regular_under "$ROOT54" "$ROOT54/.config"
    grep -Fxq 'CONFIG_TARGET_mediatek_mt7986_DEVICE_BPI-R3MINI-EMMC=y' "$ROOT54/.config" || die 'R3MINI_EMMC_TARGET_NOT_SELECTED'
    grep -Fxq 'CONFIG_MTK_MT7986_NEW_FW=y' "$ROOT54/.config" || die 'MT7986_NEW_FW_NOT_SELECTED'
    grep -Fxq 'CONFIG_PACKAGE_kmod-mt_wifi=y' "$ROOT54/.config" || die 'MT_WIFI_NOT_SELECTED'
    grep -Fxq 'CONFIG_PACKAGE_kmod-conninfra=y' "$ROOT54/.config" || die 'CONNINFRA_NOT_SELECTED'
    if grep -Eq '^CONFIG_PACKAGE_kmod-mt7915e=(y|m)$' "$ROOT54/.config"; then
        die 'CONFLICTING_MT7915E_SELECTED'
    fi
}

verify_config_contract

verify_built_artifacts()
{
    local minimum_epoch="${1:-0}"
    mapfile -d '' -t kernel_dirs < <(find "$ROOT54/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7986" -maxdepth 1 -type d -name 'linux-5.4.*' -print0 2>/dev/null)
    [ "${#kernel_dirs[@]}" -eq 1 ] || die "KERNEL_DIRECTORY_COUNT:${#kernel_dirs[@]}"
    KERNEL_DIR="${kernel_dirs[0]}"
    SYMVERS="$KERNEL_DIR/Module.symvers"
    IMAGE_DTB="$(dirname "$KERNEL_DIR")/image-mt7986a-bananapi-bpi-r3mini-emmc.dtb"
    KDIR_FIT="$(dirname "$KERNEL_DIR")/BPI-R3MINI-EMMC-kernel.bin"
    safe_regular_under "$ROOT54" "$SYMVERS"
    safe_regular_under "$ROOT54" "$IMAGE_DTB"
    safe_regular_under "$ROOT54" "$KDIR_FIT"
    read -r SYM_TOTAL SYM_GOOD < <(awk -F '\t' '
        $2 == "mt_eeprom_read_wifi" {
            total++
            if (NF == 5 && length($1) == 10 && substr($1,1,2) == "0x" && substr($1,3) !~ /[^0-9a-fA-F]/ && $3 == "vmlinux" && $4 == "EXPORT_SYMBOL" && $5 == "")
                good++
        }
        END { print total+0, good+0 }
    ' "$SYMVERS")
    [ "$SYM_TOTAL" -eq 1 ] && [ "$SYM_GOOD" -eq 1 ] || die "EEPROM_BACKEND_EXPORT_CONTRACT:TOTAL=$SYM_TOTAL:GOOD=$SYM_GOOD"

    python3 - "$IMAGE_DTB" "$EEPROM_SHA" <<'PY_DTB'
import hashlib
import pathlib
import struct
import sys

dtb = pathlib.Path(sys.argv[1]).read_bytes()
if len(dtb) < 40:
    raise SystemExit('DTB header is truncated')
(magic, total_size, struct_offset, strings_offset, _reserve_offset,
 _version, _last_compatible, _boot_cpu, strings_size,
 struct_size) = struct.unpack_from('>10I', dtb)
if magic != 0xD00DFEED or total_size > len(dtb):
    raise SystemExit('invalid DTB header')
structure = dtb[struct_offset:struct_offset + struct_size]
strings = dtb[strings_offset:strings_offset + strings_size]

def align4(value):
    return (value + 3) & ~3

def cstring(blob, offset):
    end = blob.find(b'\0', offset)
    if end < 0:
        raise SystemExit('unterminated DTB string')
    return blob[offset:end], end + 1

def path_for(stack):
    return '/' + '/'.join(item for item in stack if item)

nodes = {}
stack = []
offset = 0
while offset + 4 <= len(structure):
    token = struct.unpack_from('>I', structure, offset)[0]
    offset += 4
    if token == 1:
        name, offset = cstring(structure, offset)
        offset = align4(offset)
        stack.append(name.decode('ascii'))
        nodes.setdefault(path_for(stack), {})
    elif token == 2:
        if not stack:
            raise SystemExit('DTB node stack underflow')
        stack.pop()
    elif token == 3:
        if offset + 8 > len(structure) or not stack:
            raise SystemExit('invalid DTB property header')
        length, name_offset = struct.unpack_from('>II', structure, offset)
        offset += 8
        if offset + length > len(structure) or name_offset >= len(strings):
            raise SystemExit('invalid DTB property bounds')
        name, _ = cstring(strings, name_offset)
        value = structure[offset:offset + length]
        offset = align4(offset + length)
        nodes[path_for(stack)][name.decode('ascii')] = value
    elif token == 4:
        continue
    elif token == 9:
        break
    else:
        raise SystemExit(f'unknown DTB token {token}')
else:
    raise SystemExit('DTB structure has no end token')

def strings_of(value, label):
    if not value or value[-1:] != b'\0':
        raise SystemExit(f'invalid DTB string-list property {label}')
    try:
        return [part.decode('ascii') for part in value[:-1].split(b'\0')]
    except UnicodeDecodeError as exc:
        raise SystemExit(f'non-ASCII DTB string-list property {label}') from exc

wbsys_nodes = []
for node_path, node_properties in nodes.items():
    raw_compatible = node_properties.get('compatible')
    if raw_compatible is None:
        continue
    node_compatible = strings_of(raw_compatible, f'{node_path}/compatible')
    if 'mediatek,wbsys' in node_compatible:
        wbsys_nodes.append((node_path, node_properties, node_compatible))
if len(wbsys_nodes) != 1:
    paths = ','.join(item[0] for item in wbsys_nodes) or 'NONE'
    raise SystemExit(f'mediatek,wbsys DTB node count is {len(wbsys_nodes)}, paths={paths}')
path, properties, compatible = wbsys_nodes[0]
if compatible != ['mediatek,wbsys', 'mediatek,mt7986-wmac']:
    raise SystemExit('wbsys compatible mismatch: ' + ' '.join(compatible))
status = strings_of(properties.get('status', b''), f'{path}/status')
if status != ['okay']:
    raise SystemExit('wbsys status mismatch: ' + ' '.join(status))
payload = properties.get('mediatek,eeprom-data', b'')
digest = hashlib.sha256(payload).hexdigest()
if len(payload) != 4096 or digest != sys.argv[2]:
    raise SystemExit(f'EEPROM DTB contract failed bytes={len(payload)} sha={digest}')
print(f'EEPROM_DTB_NODE={path}')
print(f'EEPROM_DTB_BYTES={len(payload)}')
print(f'EEPROM_DTB_SHA256={digest}')
PY_DTB

    mapfile -d '' -t conn_modules < <(find "$ROOT54/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7986" -type f -name 'conninfra.ko' -print0)
    mapfile -d '' -t wifi_modules < <(find "$ROOT54/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7986" -type f -name 'mt_wifi.ko' -print0)
    [ "${#conn_modules[@]}" -ge 1 ] || die 'CONNINFRA_MODULE_MISSING'
    [ "${#wifi_modules[@]}" -ge 1 ] || die 'MT_WIFI_MODULE_MISSING'
    module_index=0
    for module in "${conn_modules[@]}"; do
        safe_regular_under "$ROOT54" "$module"
        symbol_dump="$PROOF/readelf-build-conninfra-$module_index.txt"
        readelf -Ws "$module" > "$symbol_dump" || die "CONNINFRA_READELF_FAILED:$module"
        grep -E '[[:space:]]UND[[:space:]]+mt_eeprom_read_wifi$' "$symbol_dump" >/dev/null || die "CONNINFRA_MODULE_NOT_USING_BACKEND:$module"
        [ "$minimum_epoch" -eq 0 ] || [ "$(stat -c '%Y' "$module")" -ge "$minimum_epoch" ] || die "STALE_CONNINFRA_MODULE:$module"
        module_index=$((module_index + 1))
    done
    module_index=0
    for module in "${wifi_modules[@]}"; do
        safe_regular_under "$ROOT54" "$module"
        symbol_dump="$PROOF/readelf-build-mt-wifi-$module_index.txt"
        readelf -Ws "$module" > "$symbol_dump" || die "MT_WIFI_READELF_FAILED:$module"
        grep -E '[[:space:]]UND[[:space:]]+mt_eeprom_read_wifi$' "$symbol_dump" >/dev/null || die "MT_WIFI_MODULE_NOT_USING_BACKEND:$module"
        grep -E '[[:space:]]UND[[:space:]]+mt_mtd_write_nm_wifi$' "$symbol_dump" >/dev/null || die "MT_WIFI_MODULE_WRITE_PATH_NOT_RAW_MTD:$module"
        [ "$minimum_epoch" -eq 0 ] || [ "$(stat -c '%Y' "$module")" -ge "$minimum_epoch" ] || die "STALE_MT_WIFI_MODULE:$module"
        module_index=$((module_index + 1))
    done

    ROOTFS="$ROOT54/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
    safe_directory_under "$ROOT54" "$ROOTFS"
    mapfile -d '' -t root_conn_modules < <(find "$ROOTFS/lib/modules" -type f -name 'conninfra.ko' -print0 2>/dev/null)
    mapfile -d '' -t root_wifi_modules < <(find "$ROOTFS/lib/modules" -type f -name 'mt_wifi.ko' -print0 2>/dev/null)
    [ "${#root_conn_modules[@]}" -ge 1 ] || die 'ROOTFS_CONNINFRA_MODULE_MISSING'
    [ "${#root_wifi_modules[@]}" -ge 1 ] || die 'ROOTFS_MT_WIFI_MODULE_MISSING'
    module_index=0
    for module in "${root_conn_modules[@]}"; do
        safe_regular_under "$ROOT54" "$module"
        symbol_dump="$PROOF/readelf-rootfs-conninfra-$module_index.txt"
        readelf -Ws "$module" > "$symbol_dump" || die "ROOTFS_CONNINFRA_READELF_FAILED:$module"
        grep -E '[[:space:]]UND[[:space:]]+mt_eeprom_read_wifi$' "$symbol_dump" >/dev/null || die "ROOTFS_CONNINFRA_MODULE_NOT_USING_BACKEND:$module"
        module_index=$((module_index + 1))
    done
    module_index=0
    for module in "${root_wifi_modules[@]}"; do
        safe_regular_under "$ROOT54" "$module"
        symbol_dump="$PROOF/readelf-rootfs-mt-wifi-$module_index.txt"
        readelf -Ws "$module" > "$symbol_dump" || die "ROOTFS_MT_WIFI_READELF_FAILED:$module"
        grep -E '[[:space:]]UND[[:space:]]+mt_eeprom_read_wifi$' "$symbol_dump" >/dev/null || die "ROOTFS_MT_WIFI_MODULE_NOT_USING_BACKEND:$module"
        grep -E '[[:space:]]UND[[:space:]]+mt_mtd_write_nm_wifi$' "$symbol_dump" >/dev/null || die "ROOTFS_MT_WIFI_MODULE_WRITE_PATH_NOT_RAW_MTD:$module"
        module_index=$((module_index + 1))
    done

    verify_config_contract

    OUT="$ROOT54/bin/targets/mediatek/mt7986"
    safe_directory_under "$ROOT54" "$OUT"
    IMAGE="$OUT/immortalwrt-mediatek-mt7986-BPI-R3MINI-EMMC-squashfs-sysupgrade.bin"
    MANIFEST="$OUT/immortalwrt-mediatek-mt7986-bpi-r3mini-emmc.manifest"
    safe_regular_under "$ROOT54" "$IMAGE"
    safe_regular_under "$ROOT54" "$MANIFEST"
    safe_regular_under "$ROOT54" "$OUT/sha256sums"
    FINAL_IMAGE_LIST="$(tar -tf "$IMAGE")" || die 'FINAL_IMAGE_LIST_FAILED'
    mapfile -t FINAL_KERNEL_MEMBERS < <(printf '%s\n' "$FINAL_IMAGE_LIST" | awk '/\/kernel$/{print}')
    [ "${#FINAL_KERNEL_MEMBERS[@]}" -eq 1 ] || die "FINAL_KERNEL_MEMBER_COUNT:${#FINAL_KERNEL_MEMBERS[@]}"
    FINAL_KERNEL_MEMBER='sysupgrade-BPI-R3MINI-EMMC/kernel'
    [ "${FINAL_KERNEL_MEMBERS[0]}" = "$FINAL_KERNEL_MEMBER" ] || \
        die "FINAL_KERNEL_MEMBER_NAME:${FINAL_KERNEL_MEMBERS[0]}"
    tar -xOf "$IMAGE" "$FINAL_KERNEL_MEMBER" > "$PROOF/final-kernel.fit"
    cmp -s "$PROOF/final-kernel.fit" "$KDIR_FIT" || die 'FINAL_KERNEL_DIFFERS_FROM_KDIR_FIT'
    echo 'FINAL_KERNEL_EQUALS_KDIR_FIT=PASS'
    echo "FINAL_KERNEL_FIT_SHA256=$(sha256sum "$KDIR_FIT" | awk '{print $1}')"
    python3 - "$PROOF/final-kernel.fit" "$IMAGE_DTB" <<'PY_FINAL_DTB'
import hashlib
import pathlib
import struct
import sys

fit = pathlib.Path(sys.argv[1]).read_bytes()
dtb = pathlib.Path(sys.argv[2]).read_bytes()
if len(fit) < 40:
    raise SystemExit('final kernel FIT header is truncated')
(magic, total_size, struct_offset, strings_offset, _reserve_offset,
 _version, _last_compatible, _boot_cpu, strings_size,
 struct_size) = struct.unpack_from('>10I', fit)
if magic != 0xD00DFEED:
    raise SystemExit('final kernel is not an FDT/FIT image')
if total_size < 40 or total_size > len(fit):
    raise SystemExit('invalid final kernel FIT total size')
if struct_offset > total_size or struct_size > total_size - struct_offset:
    raise SystemExit('invalid final kernel FIT structure bounds')
if strings_offset > total_size or strings_size > total_size - strings_offset:
    raise SystemExit('invalid final kernel FIT strings bounds')
structure = fit[struct_offset:struct_offset + struct_size]
strings = fit[strings_offset:strings_offset + strings_size]

def align4(value):
    return (value + 3) & ~3

def cstring(blob, offset, label):
    if offset < 0 or offset >= len(blob):
        raise SystemExit(f'invalid {label} string offset')
    end = blob.find(b'\0', offset)
    if end < 0:
        raise SystemExit(f'unterminated {label} string')
    try:
        value = blob[offset:end].decode('ascii')
    except UnicodeDecodeError as exc:
        raise SystemExit(f'non-ASCII {label} string') from exc
    return value, end + 1

def path_for(stack):
    return '/' + '/'.join(item for item in stack if item)

nodes = {}
stack = []
offset = 0
ended = False
while offset + 4 <= len(structure):
    token = struct.unpack_from('>I', structure, offset)[0]
    offset += 4
    if token == 1:
        name, offset = cstring(structure, offset, 'FIT node')
        offset = align4(offset)
        if offset > len(structure):
            raise SystemExit('FIT node name exceeds structure bounds')
        stack.append(name)
        path = path_for(stack)
        if path in nodes:
            raise SystemExit(f'duplicate FIT node {path}')
        nodes[path] = {}
    elif token == 2:
        if not stack:
            raise SystemExit('FIT node stack underflow')
        stack.pop()
    elif token == 3:
        if offset + 8 > len(structure) or not stack:
            raise SystemExit('invalid FIT property header')
        length, name_offset = struct.unpack_from('>II', structure, offset)
        offset += 8
        if length > len(structure) - offset:
            raise SystemExit('invalid FIT property bounds')
        name, _ = cstring(strings, name_offset, 'FIT property name')
        value = structure[offset:offset + length]
        offset = align4(offset + length)
        if offset > len(structure):
            raise SystemExit('FIT property alignment exceeds structure bounds')
        properties = nodes[path_for(stack)]
        if name in properties:
            raise SystemExit(f'duplicate FIT property {path_for(stack)}/{name}')
        properties[name] = value
    elif token == 4:
        continue
    elif token == 9:
        if stack:
            raise SystemExit('FIT ended with unclosed nodes')
        ended = True
        break
    else:
        raise SystemExit(f'unknown FIT token {token}')
if not ended:
    raise SystemExit('FIT structure has no end token')

def one_string(properties, name, owner):
    value = properties.get(name)
    if value is None:
        raise SystemExit(f'missing FIT property {owner}/{name}')
    if not value or value[-1:] != b'\0':
        raise SystemExit(f'invalid FIT string property {owner}/{name}')
    parts = value[:-1].split(b'\0')
    if len(parts) != 1 or not parts[0]:
        raise SystemExit(f'FIT property {owner}/{name} is not one non-empty string')
    try:
        return parts[0].decode('ascii')
    except UnicodeDecodeError as exc:
        raise SystemExit(f'non-ASCII FIT property {owner}/{name}') from exc

configurations_path = '/configurations'
if configurations_path not in nodes:
    raise SystemExit('missing FIT /configurations node')
default_config = one_string(nodes[configurations_path], 'default', configurations_path)
if '/' in default_config or default_config in ('.', '..'):
    raise SystemExit(f'invalid FIT default configuration reference {default_config}')
config_path = f'{configurations_path}/{default_config}'
if config_path not in nodes:
    raise SystemExit(f'FIT default references missing configuration {config_path}')
fdt_reference = one_string(nodes[config_path], 'fdt', config_path)
if '/' in fdt_reference or fdt_reference in ('.', '..'):
    raise SystemExit(f'invalid FIT FDT image reference {fdt_reference}')
fdt_path = f'/images/{fdt_reference}'
if fdt_path not in nodes:
    raise SystemExit(f'FIT configuration references missing FDT image {fdt_path}')
fdt_properties = nodes[fdt_path]
fdt_type = one_string(fdt_properties, 'type', fdt_path)
if fdt_type != 'flat_dt':
    raise SystemExit(f'FIT FDT image type is {fdt_type}, expected flat_dt')
compression = one_string(fdt_properties, 'compression', fdt_path)
if compression != 'none':
    raise SystemExit(f'FIT FDT compression is {compression}, expected none')
embedded_dtb = fdt_properties.get('data')
if embedded_dtb is None:
    raise SystemExit(f'missing FIT property {fdt_path}/data')
if embedded_dtb != dtb:
    raise SystemExit(
        'FIT FDT data does not exactly match authoritative image DTB: '
        f'fit={hashlib.sha256(embedded_dtb).hexdigest()} '
        f'image={hashlib.sha256(dtb).hexdigest()}'
    )
digest = hashlib.sha256(embedded_dtb).hexdigest()
print(f'FINAL_FIT_DEFAULT_CONFIG={default_config}')
print(f'FINAL_FIT_FDT_IMAGE={fdt_reference}')
print(f'FINAL_FIT_FDT_BYTES={len(embedded_dtb)}')
print(f'FINAL_FIT_FDT_SHA256={digest}')
print('FINAL_FIT_FDT_SEMANTICS=PASS')
PY_FINAL_DTB
    if [ "$minimum_epoch" -ne 0 ]; then
        [ "$(stat -c '%Y' "$SYMVERS")" -ge "$minimum_epoch" ] || die 'STALE_MODULE_SYMVERS'
        [ "$(stat -c '%Y' "$IMAGE_DTB")" -ge "$minimum_epoch" ] || die 'STALE_R3MINI_IMAGE_DTB'
        [ "$(stat -c '%Y' "$KDIR_FIT")" -ge "$minimum_epoch" ] || die 'STALE_R3MINI_KDIR_FIT'
        [ "$(stat -c '%Y' "$IMAGE")" -ge "$minimum_epoch" ] || die 'STALE_R3MINI_IMAGE'
        [ "$(stat -c '%Y' "$MANIFEST")" -ge "$minimum_epoch" ] || die 'STALE_R3MINI_MANIFEST'
    fi
    grep -Eq '^kmod-mt_wifi - ' "$MANIFEST" || die 'MT_WIFI_MISSING_FROM_MANIFEST'
    grep -Eq '^kmod-conninfra - ' "$MANIFEST" || die 'CONNINFRA_MISSING_FROM_MANIFEST'
    (
        cd "$OUT"
        sha256sum -c sha256sums
    )
    echo "R3MINI_5_4_IMAGE_SHA256=$(sha256sum "$IMAGE" | awk '{print $1}')"
}

if [ "$MODE" = '--verify' ]; then
    verify_built_artifacts 0
    echo 'R3MINI_EEPROM_612_TO_54_VERIFY=PASS'
    SUCCESS=1
    exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
BUILD_START_EPOCH="$(date +%s)"
LOG_DIR="$ROOT54/build-logs/r3mini-eeprom-612-to-54-$STAMP"
if [ -e "$ROOT54/build-logs" ] || [ -L "$ROOT54/build-logs" ]; then
    safe_directory_under "$ROOT54" "$ROOT54/build-logs"
fi
mkdir -p "$LOG_DIR"
safe_directory_under "$ROOT54" "$LOG_DIR"

echo '===== CLEAN AFFECTED 5.4 KERNEL AND VENDOR MODULES ====='
make -j1 package/mtk/drivers/conninfra/clean V=s 2>&1 | tee "$LOG_DIR/conninfra-clean.log"
make -j1 package/mtk/drivers/mt_wifi/clean V=s 2>&1 | tee "$LOG_DIR/mt-wifi-clean.log"
make -j1 target/linux/clean V=s 2>&1 | tee "$LOG_DIR/target-linux-clean.log"

echo '===== FULL 5.4 J1 BUILD ====='
set +e
make -j12 V=s 2>&1 | tee "$LOG_DIR/full-build.log"
pipeline_rc=("${PIPESTATUS[@]}")
set -e
make_rc="${pipeline_rc[0]:-125}"
tee_rc="${pipeline_rc[1]:-125}"
echo "FIRMWARE_BUILD_RC=$make_rc"
echo "BUILD_LOG_WRITE_RC=$tee_rc"
[ "$make_rc" -eq 0 ] || die "FIRMWARE_BUILD_FAILED:$make_rc"
[ "$tee_rc" -eq 0 ] || die "BUILD_LOG_WRITE_FAILED:$tee_rc"

verify_built_artifacts "$BUILD_START_EPOCH"
echo "FULL_BUILD_LOG=$LOG_DIR/full-build.log"
echo 'FACTORY_OR_EFUSE_WRITTEN=NO'
echo 'R3MINI_EEPROM_612_TO_54_BUILD=PASS'
SUCCESS=1
