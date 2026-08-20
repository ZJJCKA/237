#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || {
	echo 'ERROR: this updater must be run with bash, not sh' >&2
	exit 2
}
set -Eeuo pipefail

umask 022

SCRIPT_NAME=${0##*/}
MODE=update
ROOT_ARG=/home/ht/237
MAKE_JOBS=${MAKE_JOBS:-12}

case "$MAKE_JOBS" in
	*[!0-9]*|'')
		echo "ERROR: MAKE_JOBS must be a positive integer" >&2
		exit 2
		;;
	0)
		echo "ERROR: MAKE_JOBS must be greater than zero" >&2
		exit 2
		;;
esac

usage() {
	cat <<EOF
用法：
  bash $SCRIPT_NAME [OPENWRT_ROOT]
  bash $SCRIPT_NAME --recover [OPENWRT_ROOT]

默认 OpenWrt 源码目录：/home/ht/237

脚本会以可恢复事务更新以下官方源码，将 OpenClash 菜单排序固定为 -5，
对已确认哈希的 Passwall CBI、Socks 防火墙及循环定时回归应用兼容修复，
再使用当前 .config
同步软件包选择并执行 make -j1 V=s：
  package/luci-app-openclash
  package/passwall-luci
  package/passwall-packages
EOF
}

case ${1:-} in
	-h|--help)
		usage
		exit 0
		;;
	--recover)
		MODE=recover
		ROOT_ARG=${2:-/home/ht/237}
		[ "$#" -le 2 ] || { usage >&2; exit 2; }
		;;
	'') ;;
	*)
		ROOT_ARG=$1
		[ "$#" -eq 1 ] || { usage >&2; exit 2; }
		;;
esac

fail() {
	printf '错误：%s\n' "$*" >&2
	exit 1
}

section() {
	printf '\n===== %s =====\n' "$*"
}

need_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

for command_name in \
	bash sh make git curl tar find sort sed awk grep head tail wc readlink cat \
	mktemp mv cp mkdir rm rmdir ln stat flock tee date tac sha256sum cmp chmod
do
	need_command "$command_name"
done

[ -d "$ROOT_ARG" ] || fail "OpenWrt root does not exist: $ROOT_ARG"
ROOT=$(cd "$ROOT_ARG" && pwd -P)
[ "$ROOT" != / ] || fail 'refusing to use / as OpenWrt root'
[ -f "$ROOT/rules.mk" ] || fail "rules.mk is missing under $ROOT"
[ -f "$ROOT/include/toplevel.mk" ] || fail "include/toplevel.mk is missing under $ROOT"
[ -d "$ROOT/package" ] || fail "package/ is missing under $ROOT"
[ ! -L "$ROOT/package" ] || fail "package/ must not be a symlink: $ROOT/package"
[ "$(readlink -f "$ROOT/package")" = "$ROOT/package" ] || \
	fail "package/ resolves outside the OpenWrt root: $ROOT/package"
[ -x "$ROOT/scripts/feeds" ] || fail "scripts/feeds is missing or not executable under $ROOT"
[ ! -L "$ROOT/.config" ] || fail '.config must not be a symlink'

case "$ROOT" in
	*$'\n'*|*'|'*) fail 'OpenWrt root contains an unsupported newline or | character' ;;
esac

BACKUP_BASE=${PROXY_UPDATE_BACKUP_ROOT:-"${ROOT}-backups"}
mkdir -p "$BACKUP_BASE"
BACKUP_BASE=$(cd "$BACKUP_BASE" && pwd -P)
case "$BACKUP_BASE" in
	*$'\n'*|*'|'*) fail 'backup root contains an unsupported newline or | character' ;;
esac
case "$BACKUP_BASE" in
	/|"$ROOT"|"$ROOT"/*) fail "unsafe backup root: $BACKUP_BASE" ;;
esac

TARGET_OC="$ROOT/package/luci-app-openclash"
TARGET_PW_LUCI="$ROOT/package/passwall-luci"
TARGET_PW_PACKAGES="$ROOT/package/passwall-packages"

PASSWALL_DEPENDENCIES=(
	chinadns-ng dns2socks geoview hysteria ipt2socks microsocks naiveproxy
	shadow-tls shadowsocks-rust shadowsocksr-libev simple-obfs sing-box tcping
	v2ray-geodata v2ray-plugin xray-core xray-plugin
)

# Keep the kernel driver, user-space library, and management CLI together.
NVME_CONFIG_SYMBOLS=(
	CONFIG_PACKAGE_kmod-nvme
	CONFIG_PACKAGE_libnvme
	CONFIG_PACKAGE_nvme-cli
)
LUCIMOUNT_CONFIG_SYMBOL='CONFIG_PACKAGE_luci-app-mount'
LUCIMOUNT_MENU="$ROOT/feeds/luci/modules/luci-mod-system/root/usr/share/luci/menu.d/luci-mod-system.json"
LUCIMOUNT_ACL="$ROOT/feeds/luci/modules/luci-mod-system/root/usr/share/rpcd/acl.d/luci-mod-system.json"
LUCIMOUNT_PAGE="$ROOT/feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/mounts.js"
UPNP_HOTPLUG_FILE="$ROOT/package/mtk/applications/miniupnpd-mtk-adjust/files/miniupnpd.hotplug"
MODEM_NETWORK_TASK="$ROOT/package/mtk/applications/5g-modem/luci-app-modem/root/usr/share/modem/modem_network_task.sh"
MODEM_CFUN_INIT="$ROOT/package/mtk/applications/5g-modem/luci-app-modem/root/etc/init.d/sendat-cfun"
RUST_MAKEFILE="$ROOT/feeds/packages/lang/rust/Makefile"
RUST_VERSION='1.96.0'
RUST_SOURCE_HASH='e90a9eb153b2948afac840dbe9d77b64e376706f2864387ee7717f7450043b44'
# Keep the R3 Mini image default LAN address deterministic across updates.
R3MINI_LAN_DEFAULT_FILE="$ROOT/target/linux/mediatek/mt7986/base-files/etc/uci-defaults/99-r3mini-network-dhcp-defaults"
R3MINI_LAN_TEST_IP='192.168.66.1'

LOCK_FILE="$ROOT/.thirdparty-source-update.lock"
[ ! -L "$LOCK_FILE" ] || fail "lock path must not be a symlink: $LOCK_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "another updater is already running; lock=$LOCK_FILE"

POINTER="$ROOT/.thirdparty-source-update-active"
TRANSACTION_ACTIVE=0
COMMITTED=0
LIVE_MUTATION_STARTED=0
BUILD_PHASE_ACTIVE=0
BACKUP_DIR=
STATE_FILE=
STAGE_ROOT=

safe_cleanup_stage() {
	local resolved_stage stage_parent stage_name
	[ -n "${STAGE_ROOT:-}" ] || return 0
	case "$STAGE_ROOT" in *'/../'*|*/..|../*|..) return 1 ;; esac
	[ ! -L "$STAGE_ROOT" ] || return 1
	resolved_stage=$(readlink -f -- "$STAGE_ROOT" 2>/dev/null || true)
	[ -n "$resolved_stage" ] || return 0
	stage_parent=${resolved_stage%/*}
	stage_name=${resolved_stage##*/}
	if [ "$stage_parent" = "$ROOT" ]; then
		case "$stage_name" in .thirdparty-stage.*) ;; *) stage_name= ;; esac
	else
		stage_name=
	fi
	case "$stage_name" in
		.thirdparty-stage.*)
			[ -d "$resolved_stage" ] || return 0
			rm -rf -- "$resolved_stage"
			;;
		*)
			printf 'ERROR: refusing unsafe stage cleanup: %s\n' "$resolved_stage" >&2
			return 1
			;;
	esac
}

move_current_to_failed() {
	local kind=$1 name=$2 target=$3
	local failed="$BACKUP_DIR/failed-new/$kind/$name"
	if [ -e "$target" ] || [ -L "$target" ]; then
		mkdir -p "${failed%/*}"
		if [ -e "$failed" ] || [ -L "$failed" ]; then
			failed="${failed}.$(date +%s).$$"
		fi
		mv -T -- "$target" "$failed" || return 1
		printf 'rollback_saved_new=%s\n' "$failed"
	fi
}

restore_config() {
	local failed_config
	if [ -f "$BACKUP_DIR/config.was-present" ]; then
		[ -e "$BACKUP_DIR/config.before" ] || return 1
		if [ -e "$ROOT/.config" ] || [ -L "$ROOT/.config" ]; then
			mkdir -p "$BACKUP_DIR/failed-new/config"
			failed_config="$BACKUP_DIR/failed-new/config/.config.after-failure"
			if [ -e "$failed_config" ] || [ -L "$failed_config" ]; then
				failed_config="${failed_config}.$(date +%s).$$"
			fi
			mv -T -- "$ROOT/.config" \
				"$failed_config" || return 1
		fi
		cp -a -- "$BACKUP_DIR/config.before" "$ROOT/.config" || return 1
	elif [ -f "$BACKUP_DIR/config.was-absent" ]; then
		if [ -e "$ROOT/.config" ] || [ -L "$ROOT/.config" ]; then
			mkdir -p "$BACKUP_DIR/failed-new/config"
			failed_config="$BACKUP_DIR/failed-new/config/.config.after-failure"
			if [ -e "$failed_config" ] || [ -L "$failed_config" ]; then
				failed_config="${failed_config}.$(date +%s).$$"
			fi
			mv -T -- "$ROOT/.config" \
				"$failed_config" || return 1
		fi
	fi
}

restore_config_for_build() {
	local saved_config
	[ -f "$BACKUP_DIR/config.for-build" ] && \
		[ ! -L "$BACKUP_DIR/config.for-build" ] || return 1
	if [ -e "$ROOT/.config" ] || [ -L "$ROOT/.config" ]; then
		mkdir -p "$BACKUP_DIR/failed-new/config"
		saved_config="$BACKUP_DIR/failed-new/config/.config.after-build"
		if [ -e "$saved_config" ] || [ -L "$saved_config" ]; then
			saved_config="${saved_config}.$(date +%s).$$"
		fi
		mv -T -- "$ROOT/.config" "$saved_config" || return 1
	fi
	cp -a -- "$BACKUP_DIR/config.for-build" "$ROOT/.config" || return 1
}

restore_r3mini_lan_default() {
	local saved_default="$BACKUP_DIR/r3mini-lan-default.before"
	[ -f "$saved_default" ] && [ ! -L "$saved_default" ] || return 1
	[ -f "$R3MINI_LAN_DEFAULT_FILE" ] && [ ! -L "$R3MINI_LAN_DEFAULT_FILE" ] || return 1
	cp -a -- "$saved_default" "$R3MINI_LAN_DEFAULT_FILE" || return 1
	printf 'restored=%s\n' "$R3MINI_LAN_DEFAULT_FILE"
}

restore_rust_makefile() {
	local saved_makefile="$BACKUP_DIR/rust-makefile.before"
	[ -f "$saved_makefile" ] && [ ! -L "$saved_makefile" ] || return 1
	[ -f "$RUST_MAKEFILE" ] && [ ! -L "$RUST_MAKEFILE" ] || return 1
	cp -a -- "$saved_makefile" "$RUST_MAKEFILE" || return 1
	printf 'restored=%s\n' "$RUST_MAKEFILE"
}

is_allowed_duplicate_package() {
	local candidate=$1 package_name
	case "$candidate" in luci-app-openclash|luci-app-passwall) return 0 ;; esac
	for package_name in "${PASSWALL_DEPENDENCIES[@]}"; do
		[ "$candidate" = "$package_name" ] && return 0
	done
	return 1
}

validate_state_line() {
	local line=$1 kind name target old_path had_old relative feed_name package_name
	[[ "$line" =~ ^[^\|]+\|[^\|]+\|[^\|]+\|[^\|]+\|[01]$ ]] || return 1
	IFS='|' read -r kind name target old_path had_old <<<"$line"
	case "$target$old_path" in *'/../'*|*/..|../*) return 1 ;; esac

	case "$kind:$name" in
		source:openclash)
			[ "$target" = "$TARGET_OC" ] && \
				[ "$old_path" = "$BACKUP_DIR/old/source/openclash" ]
			;;
		source:passwall-luci)
			[ "$target" = "$TARGET_PW_LUCI" ] && \
				[ "$old_path" = "$BACKUP_DIR/old/source/passwall-luci" ]
			;;
		source:passwall-packages)
			[ "$target" = "$TARGET_PW_PACKAGES" ] && \
				[ "$old_path" = "$BACKUP_DIR/old/source/passwall-packages" ]
			;;
		duplicate:*)
			[[ "$name" =~ ^[0-9]{4}$ ]] || return 1
			[ "$old_path" = "$BACKUP_DIR/old/duplicate/$((10#$name))" ] || return 1
			case "$target" in "$ROOT"/package/feeds/*/*) ;; *) return 1 ;; esac
			relative=${target#"$ROOT/package/feeds/"}
			feed_name=${relative%%/*}
			package_name=${relative#*/}
			[ -n "$feed_name" ] && [ -n "$package_name" ] || return 1
			case "$package_name" in */*) return 1 ;; esac
			[ ! -L "$ROOT/package/feeds" ] || return 1
			[ ! -L "$ROOT/package/feeds/$feed_name" ] || return 1
			[ "$(readlink -f "$ROOT/package/feeds/$feed_name" 2>/dev/null || true)" = \
				"$ROOT/package/feeds/$feed_name" ] || return 1
			is_allowed_duplicate_package "$package_name"
			;;
		*) return 1 ;;
	esac
}

validate_state_file() {
	local line
	[ -f "$STATE_FILE" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		validate_state_line "$line" || {
			printf 'ERROR: refusing invalid transaction state line: %s\n' "$line" >&2
			return 1
		}
	done < "$STATE_FILE"
}

rollback_transaction() {
	local rollback_failed=0
	local line kind name target old_path had_old
	local -a state_lines=()

	validate_state_file || return 1
	section '自动回滚'
	set +e
	if [ -f "$STATE_FILE" ]; then
		mapfile -t state_lines < "$STATE_FILE"
		for ((index=${#state_lines[@]}-1; index>=0; index--)); do
			line=${state_lines[$index]}
			IFS='|' read -r kind name target old_path had_old <<<"$line"
			[ -n "$kind" ] && [ -n "$name" ] && [ -n "$target" ] || {
				rollback_failed=1
				continue
			}

			if [ "$had_old" = 1 ]; then
				if [ -e "$old_path" ] || [ -L "$old_path" ]; then
					move_current_to_failed "$kind" "$name" "$target" || rollback_failed=1
					mkdir -p "${target%/*}"
					mv -T -- "$old_path" "$target" || rollback_failed=1
					printf 'restored=%s\n' "$target"
				fi
			else
				move_current_to_failed "$kind" "$name" "$target" || rollback_failed=1
			fi
		done
	fi

	if [ "$LIVE_MUTATION_STARTED" -eq 1 ]; then
		restore_config || rollback_failed=1
		if [ -f "$BACKUP_DIR/r3mini-lan-default.before" ]; then
			restore_r3mini_lan_default || rollback_failed=1
		fi
		if [ -f "$BACKUP_DIR/rust-makefile.before" ]; then
			restore_rust_makefile || rollback_failed=1
		fi
	fi

	if [ "$rollback_failed" -eq 0 ]; then
		printf 'ROLLED_BACK %s\n' "$(date -Is)" > "$BACKUP_DIR/ROLLED_BACK"
		if ! safe_cleanup_stage; then
			printf 'WARNING: rollback succeeded but stage cleanup was skipped: %s\n' \
				"$STAGE_ROOT" >&2
		fi
		rm -f -- "$POINTER"
		TRANSACTION_ACTIVE=0
	fi

	set -e
	[ "$rollback_failed" -eq 0 ]
}

on_exit() {
	local rc=$?
	local rollback_rc=0
	trap - EXIT INT TERM HUP
	set +e
	if [ "$BUILD_PHASE_ACTIVE" -eq 1 ] && \
		[ -f "$BACKUP_DIR/config.for-build" ]; then
		if [ ! -f "$ROOT/.config" ] || [ -L "$ROOT/.config" ] || \
			! cmp -s "$BACKUP_DIR/config.for-build" "$ROOT/.config"; then
			if restore_config_for_build; then
				printf '警告：异常退出时发现 .config 被改动，已恢复编译前配置。\n' >&2
			else
				rollback_rc=1
				printf '错误：异常退出后无法恢复编译前配置。\n' >&2
			fi
		fi
		BUILD_PHASE_ACTIVE=0
	fi

	if [ "$TRANSACTION_ACTIVE" -eq 1 ]; then
		if [ -n "${BACKUP_DIR:-}" ] && [ -f "$BACKUP_DIR/COMMITTED" ]; then
			COMMITTED=1
			rm -f -- "$POINTER"
			TRANSACTION_ACTIVE=0
			safe_cleanup_stage
		elif ! rollback_transaction; then
			rollback_rc=1
			printf 'ERROR: automatic rollback was incomplete\n' >&2
			printf 'Recovery pointer retained: %s\n' "$POINTER" >&2
		fi
	elif [ "$COMMITTED" -eq 0 ]; then
		safe_cleanup_stage
	fi

	flock -u 9 >/dev/null 2>&1
	if [ "$rollback_rc" -ne 0 ]; then
		rc=90
	fi
	exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

check_no_active_build() {
	local proc comm pid cwd
	for proc in /proc/[0-9]*/comm; do
		[ -r "$proc" ] || continue
		comm=$(cat "$proc" 2>/dev/null || true)
		case "$comm" in make|ninja|ninja-build) ;; *) continue ;; esac
		pid=${proc#/proc/}
		pid=${pid%/comm}
		cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
		case "$cwd" in
			"$ROOT"|"$ROOT"/*)
				fail "an OpenWrt build is active: pid=$pid command=$comm cwd=$cwd"
				;;
		esac
	done
}

validate_pointer_backup() {
	local candidate=$1 resolved_candidate candidate_parent candidate_name
	case "$candidate" in *'/../'*|*/..|../*|..) fail "unsafe recovery backup path: $candidate" ;; esac
	[ -d "$candidate" ] || fail "recovery backup is missing: $candidate"
	[ ! -L "$candidate" ] || fail "recovery backup must not be a symlink: $candidate"
	resolved_candidate=$(cd "$candidate" && pwd -P)
	candidate_parent=${resolved_candidate%/*}
	candidate_name=${resolved_candidate##*/}
	[ "$candidate_parent" = "$BACKUP_BASE" ] || \
		fail "recovery backup is not a direct child of $BACKUP_BASE: $resolved_candidate"
	case "$candidate_name" in
		thirdparty-update-*) ;;
		*) fail "unsafe recovery backup name: $candidate_name" ;;
	esac
	BACKUP_DIR=$resolved_candidate
}

recover_existing_transaction() {
	[ -f "$POINTER" ] || fail "no unfinished transaction pointer: $POINTER"
	BACKUP_DIR=$(sed -n '1p' "$POINTER")
	validate_pointer_backup "$BACKUP_DIR"
	STATE_FILE="$BACKUP_DIR/state.tsv"
	STAGE_ROOT=$(sed -n '1p' "$BACKUP_DIR/stage-path" 2>/dev/null || true)
	TRANSACTION_ACTIVE=1

	if [ -f "$BACKUP_DIR/COMMITTED" ]; then
		printf 'Committed transaction only needed final cleanup: %s\n' "$BACKUP_DIR"
		rm -f -- "$POINTER"
		TRANSACTION_ACTIVE=0
		COMMITTED=1
		safe_cleanup_stage
		return 0
	fi

	LIVE_MUTATION_STARTED=1
	rollback_transaction || fail '恢复回滚不完整'
	printf 'FINAL: 未完成的更新事务已成功回滚\n'
	printf '恢复证据目录：%s\n' "$BACKUP_DIR"
}

check_no_active_build

if [ "$MODE" = recover ]; then
	recover_existing_transaction
	exit 0
fi

[ -f "$ROOT/.config" ] && [ -r "$ROOT/.config" ] && [ -s "$ROOT/.config" ] || \
	fail "未找到当前固件配置：$ROOT/.config；为避免编译错误机型，脚本不会自动生成新配置"

if [ -e "$POINTER" ] || [ -L "$POINTER" ]; then
	fail "unfinished transaction detected; run: bash $SCRIPT_NAME --recover '$ROOT'"
fi

for feeds_file in "$ROOT/feeds.conf" "$ROOT/feeds.conf.default"; do
	[ -f "$feeds_file" ] || continue
	if grep -Eq \
		'^[[:space:]]*src-git(-full)?[[:space:]]+passwall_(packages|luci)[[:space:]]' \
		"$feeds_file"; then
		fail "Passwall feed method is configured in $feeds_file; do not mix it with package/passwall-*"
	fi
done

STAMP=$(date +%Y%m%d-%H%M%S)
ID="$STAMP-$$"
BACKUP_DIR="$BACKUP_BASE/thirdparty-update-$ID"
STAGE_ROOT="$ROOT/.thirdparty-stage.$ID"
STATE_FILE="$BACKUP_DIR/state.tsv"

[ ! -e "$BACKUP_DIR" ] || fail "backup directory already exists: $BACKUP_DIR"
[ ! -e "$STAGE_ROOT" ] || fail "stage directory already exists: $STAGE_ROOT"
mkdir -p "$BACKUP_DIR" "$STAGE_ROOT/repos" "$STAGE_ROOT/payloads"
: > "$STATE_FILE"
printf '%s\n' "$STAGE_ROOT" > "$BACKUP_DIR/stage-path"
POINTER_NEW="$ROOT/.thirdparty-source-update-active.new.$$"
[ ! -e "$POINTER_NEW" ] && [ ! -L "$POINTER_NEW" ] || \
	fail "temporary transaction pointer already exists: $POINTER_NEW"
printf '%s\n' "$BACKUP_DIR" > "$POINTER_NEW"
if ! ln -- "$POINTER_NEW" "$POINTER"; then
	rm -f -- "$POINTER_NEW"
	fail "cannot create transaction pointer: $POINTER"
fi
rm -f -- "$POINTER_NEW"
TRANSACTION_ACTIVE=1

LOG_FILE="$BACKUP_DIR/update.log"
exec > >(tee -a "$LOG_FILE") 2>&1

printf 'OpenWrtRoot=%s\n' "$ROOT"
printf 'Backup=%s\n' "$BACKUP_DIR"
printf 'Log=%s\n' "$LOG_FILE"

[ "$(stat -c '%d' "$ROOT")" = "$(stat -c '%d' "$BACKUP_BASE")" ] || \
	fail 'OpenWrt root and backup root are on different filesystems; atomic backup moves are unavailable'

if [ -e "$ROOT/.config" ] || [ -L "$ROOT/.config" ]; then
	cp -a -- "$ROOT/.config" "$BACKUP_DIR/config.before"
	: > "$BACKUP_DIR/config.was-present"
else
	: > "$BACKUP_DIR/config.was-absent"
fi
[ -f "$BACKUP_DIR/config.before" ] || fail '当前 .config 备份失败，停止更新'
CONFIG_BEFORE_SHA=$(sha256sum "$BACKUP_DIR/config.before" | awk '{print $1}')
printf '当前配置备份=%s\n' "$BACKUP_DIR/config.before"
printf '当前配置SHA256=%s\n' "$CONFIG_BEFORE_SHA"

[ -f "$R3MINI_LAN_DEFAULT_FILE" ] && [ ! -L "$R3MINI_LAN_DEFAULT_FILE" ] || \
	fail "R3 Mini LAN 默认配置不存在或不是普通文件：$R3MINI_LAN_DEFAULT_FILE"
cp -a -- "$R3MINI_LAN_DEFAULT_FILE" "$BACKUP_DIR/r3mini-lan-default.before"
printf 'R3 Mini LAN 默认配置备份=%s\n' "$BACKUP_DIR/r3mini-lan-default.before"

[ -f "$RUST_MAKEFILE" ] && [ ! -L "$RUST_MAKEFILE" ] || \
	fail "Rust 配方不存在或不是普通文件：$RUST_MAKEFILE"
cp -a -- "$RUST_MAKEFILE" "$BACKUP_DIR/rust-makefile.before"
printf 'Rust 配方备份=%s\n' "$BACKUP_DIR/rust-makefile.before"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git -C "$ROOT" status --short -- \
		package/luci-app-openclash package/passwall-luci package/passwall-packages \
		feeds/luci/applications/luci-app-openclash \
		feeds/luci/applications/luci-app-passwall \
		> "$BACKUP_DIR/root-git-status-before.txt" || true
fi

OPENCLASH_URL=https://github.com/vernesong/OpenClash.git
PASSWALL_LUCI_URL=https://github.com/Openwrt-Passwall/openwrt-passwall.git
PASSWALL_PACKAGES_URL=https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git

section '1. 获取三个官方仓库的最新版本'
RELEASE_JSON="$STAGE_ROOT/openclash-release.json"
OPENCLASH_TAG=
if curl -fsSL --connect-timeout 30 --retry 2 \
	'https://api.github.com/repos/vernesong/OpenClash/releases/latest' \
	-o "$RELEASE_JSON"; then
	OPENCLASH_TAG=$(sed -n \
		's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		"$RELEASE_JSON" | head -n 1)
fi

if ! [[ "$OPENCLASH_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	OPENCLASH_TAG=$(git ls-remote --refs --tags "$OPENCLASH_URL" 'refs/tags/v*' |
		sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
		sort -V | tail -n 1)
fi
[[ "$OPENCLASH_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
	fail "unable to resolve a valid OpenClash release tag: $OPENCLASH_TAG"
OPENCLASH_VERSION=${OPENCLASH_TAG#v}
printf 'OpenClashLatestTag=%s\n' "$OPENCLASH_TAG"

section '2. 下载全部新源码（此阶段不改正式目录）'
export GIT_TERMINAL_PROMPT=0
git -c advice.detachedHead=false clone --depth 1 --single-branch \
	--branch "$OPENCLASH_TAG" "$OPENCLASH_URL" "$STAGE_ROOT/repos/OpenClash"
git clone --depth 1 --single-branch --branch main \
	"$PASSWALL_LUCI_URL" "$STAGE_ROOT/repos/passwall-luci"
git clone --depth 1 --single-branch --branch main \
	"$PASSWALL_PACKAGES_URL" "$STAGE_ROOT/repos/passwall-packages"

OPENCLASH_COMMIT=$(git -C "$STAGE_ROOT/repos/OpenClash" rev-parse HEAD)
PASSWALL_LUCI_COMMIT=$(git -C "$STAGE_ROOT/repos/passwall-luci" rev-parse HEAD)
PASSWALL_PACKAGES_COMMIT=$(git -C "$STAGE_ROOT/repos/passwall-packages" rev-parse HEAD)

[ "$PASSWALL_LUCI_COMMIT" = \
	"$(git -C "$STAGE_ROOT/repos/passwall-luci" rev-parse origin/main)" ] || \
	fail 'Passwall LuCI clone is not at origin/main'
[ "$PASSWALL_PACKAGES_COMMIT" = \
	"$(git -C "$STAGE_ROOT/repos/passwall-packages" rev-parse origin/main)" ] || \
	fail 'Passwall packages clone is not at origin/main'

section '3. 检查源码身份、脚本语法、链接和权限'
mkdir -p \
	"$STAGE_ROOT/payloads/openclash" \
	"$STAGE_ROOT/payloads/passwall-luci" \
	"$STAGE_ROOT/payloads/passwall-packages"

git -C "$STAGE_ROOT/repos/OpenClash" archive --format=tar \
	HEAD:luci-app-openclash |
	tar -xf - -C "$STAGE_ROOT/payloads/openclash"
git -C "$STAGE_ROOT/repos/passwall-luci" archive --format=tar HEAD |
	tar -xf - -C "$STAGE_ROOT/payloads/passwall-luci"
git -C "$STAGE_ROOT/repos/passwall-packages" archive --format=tar HEAD |
	tar -xf - -C "$STAGE_ROOT/payloads/passwall-packages"

OC_PAYLOAD="$STAGE_ROOT/payloads/openclash"
PW_LUCI_PAYLOAD="$STAGE_ROOT/payloads/passwall-luci"
PW_PACKAGES_PAYLOAD="$STAGE_ROOT/payloads/passwall-packages"
PASSWALL_API_SOURCE="$PW_LUCI_PAYLOAD/luci-app-passwall/luasrc/passwall/api.lua"
PASSWALL_NFTABLES_SOURCE="$PW_LUCI_PAYLOAD/luci-app-passwall/root/usr/share/passwall/nftables.sh"
PASSWALL_IPTABLES_SOURCE="$PW_LUCI_PAYLOAD/luci-app-passwall/root/usr/share/passwall/iptables.sh"
PASSWALL_APP_SOURCE="$PW_LUCI_PAYLOAD/luci-app-passwall/root/usr/share/passwall/app.sh"
PASSWALL_IFUP_SOURCE="$PW_LUCI_PAYLOAD/luci-app-passwall/root/etc/hotplug.d/iface/98-passwall"
PASSWALL_MAKEFILE="$PW_LUCI_PAYLOAD/luci-app-passwall/Makefile"

grep -qx 'PKG_NAME:=luci-app-openclash' "$OC_PAYLOAD/Makefile" || \
	fail 'OpenClash package identity check failed'
[ "$(sed -n 's/^PKG_VERSION:=//p' "$OC_PAYLOAD/Makefile" | head -n 1)" = \
	"$OPENCLASH_VERSION" ] || fail 'OpenClash tag and Makefile version differ'
[ -f "$OC_PAYLOAD/root/etc/init.d/openclash" ] || \
	fail 'OpenClash init script is missing'
grep -Fq 'chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/openclash' \
	"$OC_PAYLOAD/Makefile" || \
	fail 'OpenClash Makefile does not install the init script as 0755'

PW_VERSION=$(sed -n 's/^PKG_VERSION:=//p' \
	"$PW_LUCI_PAYLOAD/luci-app-passwall/Makefile" | head -n 1)
PW_RELEASE=$(sed -n 's/^PKG_RELEASE:=//p' \
	"$PW_LUCI_PAYLOAD/luci-app-passwall/Makefile" | head -n 1)
grep -qx 'PKG_NAME:=luci-app-passwall' \
	"$PW_LUCI_PAYLOAD/luci-app-passwall/Makefile" || \
	fail 'Passwall LuCI package identity check failed'
[ -n "$PW_VERSION" ] && [ -n "$PW_RELEASE" ] || \
	fail 'Passwall LuCI version metadata is missing'
[ -x "$PW_LUCI_PAYLOAD/luci-app-passwall/root/etc/init.d/passwall" ] || \
	fail 'Passwall init script is not executable'
[ -x "$PW_LUCI_PAYLOAD/luci-app-passwall/root/etc/init.d/passwall_server" ] || \
	fail 'Passwall server init script is not executable'
[ -f "$PASSWALL_API_SOURCE" ] && [ ! -L "$PASSWALL_API_SOURCE" ] || \
	fail 'Passwall api.lua is missing or is a symlink'
PASSWALL_API_UPSTREAM_SHA=$(sha256sum "$PASSWALL_API_SOURCE" | awk '{print $1}')
PASSWALL_API_COMPAT_PATCH=not-needed
[ -f "$PASSWALL_NFTABLES_SOURCE" ] && [ ! -L "$PASSWALL_NFTABLES_SOURCE" ] || \
	fail 'Passwall nftables.sh is missing or is a symlink'
[ -f "$PASSWALL_IPTABLES_SOURCE" ] && [ ! -L "$PASSWALL_IPTABLES_SOURCE" ] || \
	fail 'Passwall iptables.sh is missing or is a symlink'
PASSWALL_NFTABLES_UPSTREAM_SHA=$(sha256sum "$PASSWALL_NFTABLES_SOURCE" | awk '{print $1}')
PASSWALL_IPTABLES_UPSTREAM_SHA=$(sha256sum "$PASSWALL_IPTABLES_SOURCE" | awk '{print $1}')
[ -f "$PASSWALL_APP_SOURCE" ] && [ ! -L "$PASSWALL_APP_SOURCE" ] || \
	fail 'Passwall app.sh is missing or is a symlink'
PASSWALL_APP_UPSTREAM_SHA=$(sha256sum "$PASSWALL_APP_SOURCE" | awk '{print $1}')
[ -f "$PASSWALL_IFUP_SOURCE" ] && [ ! -L "$PASSWALL_IFUP_SOURCE" ] || \
	fail 'Passwall iface hotplug script is missing or is a symlink'
PASSWALL_IFUP_UPSTREAM_SHA=$(sha256sum "$PASSWALL_IFUP_SOURCE" | awk '{print $1}')
PASSWALL_SOCKS_COMPAT_PATCH=not-needed
PASSWALL_LOOP_SCHEDULE_COMPAT_PATCH=not-needed
PASSWALL_IFUP_DEBOUNCE_COMPAT_PATCH=not-needed

apply_openclash_menu_priority() {
	local controller=$1 wanted prefix route_count wanted_count patched_file

	wanted='page = entry({"admin", "services", "openclash"}, alias("admin", "services", "openclash", "client"), _("OpenClash"), -5)'
	prefix='page = entry({"admin", "services", "openclash"}, alias("admin", "services", "openclash", "client"), _("OpenClash"), '

	[ -f "$controller" ] || \
		fail "OpenClash 控制器不存在：$controller"

	route_count=$(awk -v prefix="$prefix" '
		{
			line=$0
			sub(/^[[:space:]]*/, "", line)
			sub(/[[:space:]]*$/, "", line)
			if (index(line, prefix) == 1) count++
		}
		END { print count + 0 }
	' "$controller")

	[ "$route_count" -eq 1 ] || \
		fail "OpenClash 主菜单入口候选数异常：$route_count"

	patched_file="${controller}.priority.$$"
	[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
		fail "OpenClash 临时控制器已经存在：$patched_file"

	if ! awk -v prefix="$prefix" -v wanted="$wanted" '
		{
			line=$0
			sub(/^[[:space:]]*/, "", line)
			sub(/[[:space:]]*$/, "", line)

			if (index(line, prefix) == 1) {
				match($0, /^[[:space:]]*/)
				print substr($0, 1, RLENGTH) wanted
				changed++
				next
			}

			print
		}
		END {
			if (changed != 1)
				exit 42
		}
	' "$controller" > "$patched_file"; then
		rm -f -- "$patched_file"
		fail "OpenClash 主菜单优先级重写失败"
	fi

	chmod --reference="$controller" "$patched_file"
	mv -T -- "$patched_file" "$controller"

	wanted_count=$(awk -v wanted="$wanted" '
		{
			line=$0
			sub(/^[[:space:]]*/, "", line)
			sub(/[[:space:]]*$/, "", line)
			if (line == wanted) count++
		}
		END { print count + 0 }
	' "$controller")

	[ "$wanted_count" -eq 1 ] || \
		fail "OpenClash 主菜单优先级 -5 复核失败"

	printf 'OpenClash 主菜单优先级已固定为 -5\n'
}

apply_passwall_cli_compatibility() {
	local api_file=$1 eager_count exact_eager_count local_cbi_count
	local signature signature_count patched_file

	[ -f "$api_file" ] && [ ! -L "$api_file" ] || \
		fail 'Passwall api.lua compatibility target is missing or is a symlink'

	eager_count=$(grep -Ec \
		'^[[:space:]]*cbi[[:space:]]*=[[:space:]]*require[[:space:]]*"luci\.cbi"[[:space:]]*$' \
		"$api_file" || true)

	case "$eager_count" in
		0)
			PASSWALL_API_COMPAT_PATCH=not-needed
			;;
		1)
			[ "$PASSWALL_API_UPSTREAM_SHA" = \
				'467248c651b730179a5a4b8620faa506e5a84d6b78248e56e73b2f2c5394ffdc' ] || \
				fail "Passwall api.lua has an unknown eager-import revision: $PASSWALL_API_UPSTREAM_SHA"
			exact_eager_count=$(grep -Fxc 'cbi = require "luci.cbi"' \
				"$api_file" || true)
			[ "$exact_eager_count" -eq 1 ] || \
				fail 'Passwall api.lua eager luci.cbi import has an unknown form'
			local_cbi_count=$(grep -Ec \
				'^[[:space:]]*local[[:space:]]+cbi[[:space:]]*=[[:space:]]*require[[:space:]]*"luci\.cbi"[[:space:]]*$' \
				"$api_file" || true)
			[ "$local_cbi_count" -eq 0 ] || \
				fail 'Passwall api.lua mixes eager and lazy luci.cbi imports; refusing an ambiguous patch'
			for signature in \
				'function set_default_cbi()' \
				'function return_map(map)' \
				'function luci_types(id, m, s, type_name, option_prefix)'
			do
				signature_count=$(grep -Fxc "$signature" "$api_file" || true)
				[ "$signature_count" -eq 1 ] || \
					fail "Passwall api.lua compatibility anchor count is abnormal [$signature]: $signature_count"
			done

			patched_file="${api_file}.lazy-cbi.$$"
			[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
				fail "Passwall api.lua compatibility temporary file already exists: $patched_file"
			if ! awk '
				$0 == "cbi = require \"luci.cbi\"" {
					removed++
					next
				}
				{
					print
				}
				$0 == "function set_default_cbi()" ||
				$0 == "function return_map(map)" ||
				$0 == "function luci_types(id, m, s, type_name, option_prefix)" {
					print "\tlocal cbi = require \"luci.cbi\""
					inserted++
				}
				END {
					if (removed != 1 || inserted != 3)
						exit 42
				}
			' "$api_file" > "$patched_file"; then
				rm -f -- "$patched_file"
				fail 'Passwall api.lua lazy luci.cbi compatibility patch failed'
			fi
			chmod --reference="$api_file" "$patched_file"
			mv -T -- "$patched_file" "$api_file"
			PASSWALL_API_COMPAT_PATCH=lazy-cbi
			[ "$(sha256sum "$api_file" | awk '{print $1}')" = \
				'2fdc01fdea4ac9063e9e24dce0e785d01f7d0d5940c2915f2845eb7e024f1df5' ] || \
				fail 'Passwall api.lua known compatibility patch produced an unexpected SHA256'
			;;
		*)
			fail "Passwall api.lua contains $eager_count eager luci.cbi imports"
			;;
	esac

	eager_count=$(grep -Ec \
		'^[[:space:]]*cbi[[:space:]]*=[[:space:]]*require[[:space:]]*"luci\.cbi"[[:space:]]*$' \
		"$api_file" || true)
	[ "$eager_count" -eq 0 ] || \
		fail 'Passwall api.lua still eagerly imports full luci.cbi after compatibility handling'
	PASSWALL_DATATYPES_IMPORT_COUNT=$(grep -Ec \
		'^[[:space:]]*datatypes[[:space:]]*=[[:space:]]*require[[:space:]]*"luci\.cbi\.datatypes"[[:space:]]*$' \
		"$api_file" || true)
	[ "$PASSWALL_DATATYPES_IMPORT_COUNT" -eq 1 ] || \
		fail "Passwall api.lua datatypes import count is abnormal: $PASSWALL_DATATYPES_IMPORT_COUNT"

	PASSWALL_API_SHA=$(sha256sum "$api_file" | awk '{print $1}')
	printf 'Passwall api.lua upstream SHA256=%s\n' "$PASSWALL_API_UPSTREAM_SHA"
	printf 'Passwall api.lua packaged SHA256=%s compatibility=%s\n' \
		"$PASSWALL_API_SHA" "$PASSWALL_API_COMPAT_PATCH"
}

apply_passwall_socks_firewall_compatibility() {
	local firewall_file=$1 firewall_name upstream_sha call_count prefix_count
	local expected_patched_sha patched_file patched_sha type_check_count variable

	[ -f "$firewall_file" ] && [ ! -L "$firewall_file" ] || \
		fail "Passwall firewall compatibility target is missing or is a symlink: $firewall_file"
	firewall_name=${firewall_file##*/}
	case "$firewall_name" in
		nftables.sh)
			upstream_sha=$PASSWALL_NFTABLES_UPSTREAM_SHA
			;;
		iptables.sh)
			upstream_sha=$PASSWALL_IPTABLES_UPSTREAM_SHA
			;;
		*)
			fail "Unknown Passwall firewall compatibility target: $firewall_name"
			;;
	esac

	call_count=$(grep -Fc 'is_socks_wrap' "$firewall_file" || true)
	prefix_count=$(grep -Fc '#Socks_' "$firewall_file" || true)
	case "$call_count:$prefix_count" in
		0:0)
			patched_sha=$upstream_sha
			;;
		6:6)
			case "$firewall_name:$upstream_sha" in
				nftables.sh:21b44b761c58944bb5a4e3f4e871a151a7fbce0448c5ff84244053dd6e39945a)
				expected_patched_sha=ec3d1b97dbab9fd2116549e47ded53b73653e77061b18159242abb072495f37d
				;;
				iptables.sh:a0b4903467c0a0300e007137e8851bbc142c19d8d4a6d808e7421edcc803fb7c)
				expected_patched_sha=a61e608e2e750539413694e8753ac7e83cf3a2957664cc5bfeeb510d649ab5d3
				;;
				*)
					fail "Passwall $firewall_name has an unknown is_socks_wrap revision: $upstream_sha"
					;;
			esac

			patched_file="${firewall_file}.socks-compat.$$"
			[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
				fail "Passwall firewall compatibility temporary file already exists: $patched_file"
			if ! sed \
				-e 's/if is_socks_wrap "$tcp_node"; then/if [ "$(config_get_type "$tcp_node")" = "socks" ]; then/' \
				-e 's/if is_socks_wrap "$udp_node"; then/if [ "$(config_get_type "$udp_node")" = "socks" ]; then/' \
				-e 's/if is_socks_wrap "$TCP_NODE"; then/if [ "$(config_get_type "$TCP_NODE")" = "socks" ]; then/' \
				-e 's/if is_socks_wrap "$UDP_NODE"; then/if [ "$(config_get_type "$UDP_NODE")" = "socks" ]; then/' \
				-e 's/${tcp_node#Socks_}/${tcp_node}/g' \
				-e 's/${udp_node#Socks_}/${udp_node}/g' \
				-e 's/${TCP_NODE#Socks_}/${TCP_NODE}/g' \
				-e 's/${UDP_NODE#Socks_}/${UDP_NODE}/g' \
				"$firewall_file" > "$patched_file"; then
				rm -f -- "$patched_file"
				fail "Passwall $firewall_name socks compatibility rewrite failed"
			fi
			if ! sh -n "$patched_file"; then
				rm -f -- "$patched_file"
				fail "Passwall $firewall_name socks compatibility result has invalid shell syntax"
			fi
			chmod --reference="$firewall_file" "$patched_file"
			mv -T -- "$patched_file" "$firewall_file"
			patched_sha=$(sha256sum "$firewall_file" | awk '{print $1}')
			[ "$patched_sha" = "$expected_patched_sha" ] || \
				fail "Passwall $firewall_name known compatibility patch produced an unexpected SHA256"
			PASSWALL_SOCKS_COMPAT_PATCH=config-type
			;;
		*)
			fail "Passwall $firewall_name has an ambiguous socks compatibility shape: calls=$call_count prefixes=$prefix_count"
			;;
	esac

	[ "$(grep -Fc 'is_socks_wrap' "$firewall_file" || true)" -eq 0 ] || \
		fail "Passwall $firewall_name still calls removed is_socks_wrap"
	[ "$(grep -Fc '#Socks_' "$firewall_file" || true)" -eq 0 ] || \
		fail "Passwall $firewall_name still contains obsolete Socks_ prefix stripping"
	if [ "$call_count" -eq 6 ]; then
		type_check_count=0
		for variable in tcp_node udp_node TCP_NODE UDP_NODE; do
			type_check_count=$((type_check_count + $(grep -Fc \
				"if [ \"\$(config_get_type \"\$$variable\")\" = \"socks\" ]; then" \
				"$firewall_file" || true)))
		done
		[ "$type_check_count" -eq 6 ] || \
			fail "Passwall $firewall_name config-type socks check count is abnormal: $type_check_count"
	fi
	sh -n "$firewall_file" || \
		fail "Passwall $firewall_name failed shell syntax validation"

	case "$firewall_name" in
		nftables.sh) PASSWALL_NFTABLES_SHA=$patched_sha ;;
		iptables.sh) PASSWALL_IPTABLES_SHA=$patched_sha ;;
	esac
	printf 'Passwall %s upstream SHA256=%s packaged SHA256=%s compatibility=%s\n' \
		"$firewall_name" "$upstream_sha" "$patched_sha" \
		"$PASSWALL_SOCKS_COMPAT_PATCH"
}

apply_passwall_loop_schedule_compatibility() {
	local app_file=$1 patched_file patched_sha unsafe_count safe_count

	[ -f "$app_file" ] && [ ! -L "$app_file" ] || \
		fail 'Passwall app.sh loop-schedule compatibility target is missing or is a symlink'
	command -v python3 >/dev/null 2>&1 || \
		fail 'python3 is required for the Passwall loop-schedule rewrite'

	patched_file="${app_file}.loop-schedule.$$"
	[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
		fail "Passwall app.sh loop-schedule temporary file already exists: $patched_file"

	if ! python3 - "$app_file" "$patched_file" <<'PY_LOOP'
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
data = source.read_bytes()

start_marker = b"start_crontab() {\n"
end_marker = b"\nstop_crontab() {\n"
if data.count(start_marker) != 1 or data.count(end_marker) != 1:
    raise SystemExit("Passwall start_crontab boundary is not unique")
scope_start = data.index(start_marker)
scope_end = data.index(end_marker, scope_start)
scope = data[scope_start:scope_end]

guards = (
    b'\t\tif [ "$week" = "8" ]; then\n',
    b'\t\tif [ "$rules_update_week_mode" = "8" ]; then\n',
    b'\t\t\tif [ "$sub_update_week_mode" = "8" ]; then\n',
)
if scope.count(b'$(build_time ') != 3:
    raise SystemExit("Passwall start_crontab build_time call count changed")
if scope.count(b'update_loop=1\n') != 3:
    raise SystemExit("Passwall start_crontab loop assignment count changed")
if [scope.count(guard) for guard in guards] != [1, 1, 1]:
    raise SystemExit("Passwall start_crontab week-mode guard shape changed")

original_size = len(data)
original_lines = data.count(b"\n")

pairs = (
    (
        b"""\t\tlocal svr_t=$(build_time \"$week\" \"$time\")
\t\tif [ \"$week\" = \"8\" ]; then
\t\t\tupdate_loop=1
\t\telse
\t\t\techo \"$svr_t /etc/init.d/$CONFIG $action > /dev/null 2>&1 &\" >>/etc/crontabs/root
\t\tfi
""",
        b"""\t\tif [ \"$week\" = \"8\" ]; then
\t\t\tupdate_loop=1
\t\telse
\t\t\tlocal svr_t=$(build_time \"$week\" \"$time\")
\t\t\techo \"$svr_t /etc/init.d/$CONFIG $action > /dev/null 2>&1 &\" >>/etc/crontabs/root
\t\tfi
""",
    ),
    (
        b"""\t\tlocal rule_t=$(build_time \"$rules_update_week_mode\" \"$rules_update_time_mode\")
\t\tif [ \"$rules_update_week_mode\" = \"8\" ]; then
\t\t\tupdate_loop=1
\t\telse
\t\t\techo \"$rule_t lua $APP_PATH/rule_update.lua log all cron > /dev/null 2>&1 &\" >>/etc/crontabs/root
\t\tfi
""",
        b"""\t\tif [ \"$rules_update_week_mode\" = \"8\" ]; then
\t\t\tupdate_loop=1
\t\telse
\t\t\tlocal rule_t=$(build_time \"$rules_update_week_mode\" \"$rules_update_time_mode\")
\t\t\techo \"$rule_t lua $APP_PATH/rule_update.lua log all cron > /dev/null 2>&1 &\" >>/etc/crontabs/root
\t\tfi
""",
    ),
    (
        b"""\t\t\tlocal sub_t=$(build_time \"$sub_update_week_mode\" \"$sub_update_time_mode\")
\t\t\tif [ \"$sub_update_week_mode\" = \"8\" ]; then
\t\t\t\tupdate_loop=1
\t\t\telse
\t\t\t\techo \"$sub_t lua $APP_PATH/subscribe.lua start $cfgids cron > /dev/null 2>&1 &\" >>/etc/crontabs/root
\t\t\tfi
""",
        b"""\t\t\tif [ \"$sub_update_week_mode\" = \"8\" ]; then
\t\t\t\tupdate_loop=1
\t\t\telse
\t\t\t\tlocal sub_t=$(build_time \"$sub_update_week_mode\" \"$sub_update_time_mode\")
\t\t\t\techo \"$sub_t lua $APP_PATH/subscribe.lua start $cfgids cron > /dev/null 2>&1 &\" >>/etc/crontabs/root
\t\t\tfi
""",
    ),
)

old_counts = [scope.count(old) for old, _ in pairs]
new_counts = [scope.count(new) for _, new in pairs]

if old_counts == [1, 1, 1] and new_counts == [0, 0, 0]:
    expected_size = original_size + sum(len(new) - len(old) for old, new in pairs)
    for old, new in pairs:
        scope = scope.replace(old, new, 1)
elif old_counts == [0, 0, 0] and new_counts == [1, 1, 1]:
    expected_size = original_size
else:
    raise SystemExit(
        "unsupported Passwall loop-schedule structure: "
        f"old={old_counts} safe={new_counts}"
    )

if [scope.count(old) for old, _ in pairs] != [0, 0, 0]:
    raise SystemExit("unsafe Passwall loop-schedule structure remains")
if [scope.count(new) for _, new in pairs] != [1, 1, 1]:
    raise SystemExit("safe Passwall loop-schedule structure is incomplete")
data = data[:scope_start] + scope + data[scope_end:]
if len(data) != expected_size or data.count(b"\n") != original_lines:
    raise SystemExit("Passwall loop-schedule rewrite changed an unexpected byte or line count")

output.write_bytes(data)
PY_LOOP
	then
		rm -f -- "$patched_file"
		fail 'Passwall app.sh loop-schedule structure verification or rewrite failed'
	fi

	if ! sh -n "$patched_file"; then
		rm -f -- "$patched_file"
		fail 'Passwall app.sh loop-schedule result has invalid shell syntax'
	fi

	unsafe_count=$(awk '
		$0 == "\t\tlocal svr_t=$(build_time \"$week\" \"$time\")" ||
		$0 == "\t\tlocal rule_t=$(build_time \"$rules_update_week_mode\" \"$rules_update_time_mode\")" ||
		$0 == "\t\t\tlocal sub_t=$(build_time \"$sub_update_week_mode\" \"$sub_update_time_mode\")" {
			count++
		}
		END { print count + 0 }
	' "$patched_file")
	safe_count=$(awk '
		$0 == "\t\t\tlocal svr_t=$(build_time \"$week\" \"$time\")" ||
		$0 == "\t\t\tlocal rule_t=$(build_time \"$rules_update_week_mode\" \"$rules_update_time_mode\")" ||
		$0 == "\t\t\t\tlocal sub_t=$(build_time \"$sub_update_week_mode\" \"$sub_update_time_mode\")" {
			count++
		}
		END { print count + 0 }
	' "$patched_file")
	if [ "$unsafe_count" -ne 0 ] || [ "$safe_count" -ne 3 ]; then
		rm -f -- "$patched_file"
		fail "Passwall app.sh loop-schedule postcondition failed: unsafe=$unsafe_count safe=$safe_count"
	fi

	if cmp -s "$app_file" "$patched_file"; then
		rm -f -- "$patched_file"
		PASSWALL_APP_SHA=$PASSWALL_APP_UPSTREAM_SHA
	else
		chmod --reference="$app_file" "$patched_file"
		mv -T -- "$patched_file" "$app_file"
		patched_sha=$(sha256sum "$app_file" | awk '{print $1}')
		PASSWALL_APP_SHA=$patched_sha
		PASSWALL_LOOP_SCHEDULE_COMPAT_PATCH=loop-before-time
	fi

	printf 'Passwall app.sh upstream SHA256=%s packaged SHA256=%s compatibility=%s\n' \
		"$PASSWALL_APP_UPSTREAM_SHA" "$PASSWALL_APP_SHA" \
		"$PASSWALL_LOOP_SCHEDULE_COMPAT_PATCH"
}
apply_passwall_ifup_debounce_compatibility() {
	local hotplug_file=$1 makefile=$2 marker old_count marker_count
	local patched_file old_release new_release release_count

	marker='# CODEX_PASSWALL_IFUP_DEBOUNCE_V2: trailing-edge dual-stack coalescing.'
	[ -f "$hotplug_file" ] && [ ! -L "$hotplug_file" ] || \
		fail 'Passwall iface hotplug debounce target is missing or is a symlink'
	[ -f "$makefile" ] && [ ! -L "$makefile" ] || \
		fail 'Passwall Makefile debounce target is missing or is a symlink'
	command -v python3 >/dev/null 2>&1 || \
		fail 'python3 is required for the exact Passwall debounce rewrite'
	if ! grep -Fqx 'CONFIG_BUSYBOX_DEFAULT_FLOCK=y' "$ROOT/.config" &&
	   ! grep -Fqx 'CONFIG_BUSYBOX_CONFIG_FLOCK=y' "$ROOT/.config"; then
		fail 'current R3 Mini config does not select the BusyBox flock applet'
	fi

	marker_count=$(grep -Fc "$marker" "$hotplug_file" || true)
	old_count=$(grep -Ec '^[[:space:]]*LOCK_FILE="\$\{LOCK_PATH\}/\$\{CONFIG\}_ifup[.]lock"$' \
		"$hotplug_file" || true)
	case "$marker_count:$old_count" in
		0:1)
			patched_file="${hotplug_file}.ifup-debounce.$$"
			[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
				fail "Passwall debounce temporary file already exists: $patched_file"
			if ! python3 - "$hotplug_file" "$patched_file" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
data = src.read_bytes()
old = b'''\t\t[ ! -d ${LOCK_PATH} ] && mkdir -p ${LOCK_PATH}\n\t\tLOCK_FILE="${LOCK_PATH}/${CONFIG}_ifup.lock"\n\t\tif [ -s ${LOCK_FILE} ]; then\n\t\t\tSPID=$(cat ${LOCK_FILE})\n\t\t\tif [ -e /proc/${SPID}/status ]; then\n\t\t\t\texit 1\n\t\t\tfi\n\t\t\tcat /dev/null > ${LOCK_FILE}\n\t\tfi\n\t\techo $$ > ${LOCK_FILE}\n\t\t\n\t\t/etc/init.d/${CONFIG} restart >/dev/null 2>&1 &\n\t\tlogger -p notice -t network -s "${CONFIG}: restart when $INTERFACE ifup"\n\t\t\n\t\trm -rf ${LOCK_FILE}\n'''
new = b'''		# CODEX_PASSWALL_IFUP_DEBOUNCE_V2: trailing-edge dual-stack coalescing.
		[ -d "${LOCK_PATH}" ] || mkdir -p "${LOCK_PATH}"
		DEBOUNCE_EVENT="${LOCK_PATH}/${CONFIG}_ifup_debounce.event"
		DEBOUNCE_STATE_LOCK="${LOCK_PATH}/${CONFIG}_ifup_debounce.state.lock"
		DEBOUNCE_WORKER_LOCK="${LOCK_PATH}/${CONFIG}_ifup_debounce.worker.lock"

		exec 8>"${DEBOUNCE_STATE_LOCK}" || exit 0
		flock 8 || { exec 8>&-; exit 0; }
		SEQUENCE=$(cat "${DEBOUNCE_EVENT}" 2>/dev/null || true)
		case "$SEQUENCE" in
			''|*[!0-9]*) SEQUENCE=0 ;;
		esac
		SEQUENCE=$((SEQUENCE + 1))
		if ! printf '%s\n' "$SEQUENCE" >"${DEBOUNCE_EVENT}.new" ||
		   ! mv -f "${DEBOUNCE_EVENT}.new" "${DEBOUNCE_EVENT}"; then
			rm -f "${DEBOUNCE_EVENT}.new"
			flock -u 8
			exec 8>&-
			exit 0
		fi

		exec 9>"${DEBOUNCE_WORKER_LOCK}" || {
			flock -u 8
			exec 8>&-
			exit 0
		}
		if flock -n 9; then
			(
				exec 8>&-
				exec 8>"${DEBOUNCE_STATE_LOCK}" || exit 0
				while :; do
					flock 8 || exit 0
					SNAPSHOT=$(cat "${DEBOUNCE_EVENT}" 2>/dev/null || true)
					flock -u 8
					[ -n "$SNAPSHOT" ] || exit 0
					sleep 4

					flock 8 || exit 0
					CURRENT=$(cat "${DEBOUNCE_EVENT}" 2>/dev/null || true)
					if [ "$CURRENT" != "$SNAPSHOT" ]; then
						flock -u 8
						continue
					fi
					flock -u 8

					if [ "$(get_cache_var "ENABLED_DEFAULT_ACL")" = "1" ] ||
					   [ "$(get_cache_var "ENABLED_ACLS")" = "1" ]; then
						if [ -f "${LOCK_PATH}/${CONFIG}_ready.lock" ]; then
							current_device=$(ip route show default 2>/dev/null | awk -F 'dev ' '{print $2}' | awk '{print $1}' | head -n1)
							current6_device=$(ip -6 route show default 2>/dev/null | awk -F 'dev ' '{print $2}' | awk '{print $1}' | head -n1)
							if [ -n "${current_device}${current6_device}" ]; then
								if "/etc/init.d/${CONFIG}" restart 8>&- 9>&- >/dev/null 2>&1; then
									logger -p notice -t network 8>&- 9>&- \
										"${CONFIG}: debounced restart after dual-stack ifup"
								else
									logger -p err -t network 8>&- 9>&- \
										"${CONFIG}: debounced restart failed after dual-stack ifup"
								fi
							fi
						fi
					fi

					flock 8 || exit 0
					CURRENT=$(cat "${DEBOUNCE_EVENT}" 2>/dev/null || true)
					if [ "$CURRENT" = "$SNAPSHOT" ]; then
						flock -u 9
						exec 9>&-
						flock -u 8
						exec 8>&-
						exit 0
					fi
					flock -u 8
				done
			) >/dev/null 2>&1 &
		fi
		flock -u 8
		exec 8>&-
		exec 9>&-
'''
if data.count(old) != 1:
    raise SystemExit(42)
dst.write_bytes(data.replace(old, new, 1))
PY
			then
				rm -f -- "$patched_file"
				fail 'Passwall iface hotplug debounce exact rewrite failed'
			fi
			chmod --reference="$hotplug_file" "$patched_file"
			mv -T -- "$patched_file" "$hotplug_file"

			release_count=$(grep -Ec '^PKG_RELEASE:=[0-9]+$' "$makefile" || true)
			[ "$release_count" -eq 1 ] || \
				fail "Passwall Makefile has an ambiguous numeric release: $release_count"
			old_release=$(sed -n 's/^PKG_RELEASE:=\([0-9][0-9]*\)$/\1/p' "$makefile")
			new_release=$((10#$old_release + 1))
			sed -i "s/^PKG_RELEASE:=$old_release$/PKG_RELEASE:=$new_release/" "$makefile"
			PW_RELEASE=$new_release
			PASSWALL_IFUP_DEBOUNCE_COMPAT_PATCH=trailing-generation-v2
			;;
		1:0)
			fail 'Passwall upstream already contains the local V2 marker; manual compatibility review required'
			;;
		*)
			fail "Passwall iface hotplug debounce state is ambiguous: marker=$marker_count old=$old_count"
			;;
	esac

	sh -n "$hotplug_file" || \
		fail 'Passwall iface hotplug debounce result has invalid shell syntax'
	[ "$(grep -Fc "$marker" "$hotplug_file" || true)" -eq 1 ] || \
		fail 'Passwall iface hotplug debounce marker count is not one'
	[ "$(grep -Ec '^[[:space:]]*if flock -n 9; then$' "$hotplug_file" || true)" -eq 1 ] || \
		fail 'Passwall iface hotplug debounce singleton worker contract is missing'
	[ "$(grep -Ec '^[[:space:]]*sleep 4$' "$hotplug_file" || true)" -eq 1 ] || \
		fail 'Passwall iface hotplug debounce delay contract is missing'
	[ "$(grep -Fc 'restart 8>&- 9>&- >/dev/null 2>&1; then' "$hotplug_file" || true)" -eq 1 ] || \
		fail 'Passwall iface hotplug synchronous restart contract is missing'
	[ "$(grep -Fc 'restart >/dev/null 2>&1 &' "$hotplug_file" || true)" -eq 0 ] || \
		fail 'Passwall iface hotplug still contains the old unlocked background restart'
	PASSWALL_IFUP_SHA=$(sha256sum "$hotplug_file" | awk '{print $1}')
	printf 'Passwall 98-passwall upstream SHA256=%s packaged SHA256=%s compatibility=%s release=%s\n' \
		"$PASSWALL_IFUP_UPSTREAM_SHA" "$PASSWALL_IFUP_SHA" \
		"$PASSWALL_IFUP_DEBOUNCE_COMPAT_PATCH" "$PW_RELEASE"
}

apply_offline_rootfs_guard() {
	local init_file=$1 service_name=$2 anchor=$3 anchor_count guard_count
	local guard_line first_runtime_import_line patched_file
	anchor_count=$(grep -Fxc "$anchor" "$init_file" || true)
	[ "$anchor_count" -eq 1 ] || \
		fail "$service_name init 脚本缺少唯一锚点 [$anchor]，不能安全加入离线 rootfs 保护"
	if ! grep -Fq '# CODEX_OFFLINE_ROOTFS_GUARD' "$init_file"; then
		patched_file="${init_file}.guard.$$"
		[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
			fail "临时补丁文件已经存在：$patched_file"
		awk -v anchor="$anchor" '
			{ print }
			$0 == anchor {
				print ""
				print "# CODEX_OFFLINE_ROOTFS_GUARD: offline assembly only needs init metadata."
				print "if [ -n \"${IPKG_INSTROOT:-}\" ]; then"
				print "\treturn 0 2>/dev/null || exit 0"
				print "fi"
			}
		' "$init_file" > "$patched_file"
		chmod --reference="$init_file" "$patched_file"
		mv -T -- "$patched_file" "$init_file"
	fi
	guard_count=$(grep -c '^# CODEX_OFFLINE_ROOTFS_GUARD:' "$init_file" || true)
	[ "$guard_count" -eq 1 ] || \
		fail "$service_name 离线 rootfs 保护标记数量异常：$guard_count"
	grep -Fqx 'if [ -n "${IPKG_INSTROOT:-}" ]; then' "$init_file" || \
		fail "$service_name 离线 rootfs 条件检查缺失"
	grep -Fqx "$(printf '\t')return 0 2>/dev/null || exit 0" "$init_file" || \
		fail "$service_name 离线 rootfs 提前返回语句缺失"
	guard_line=$(sed -n '/^# CODEX_OFFLINE_ROOTFS_GUARD:/{=;q;}' "$init_file")
	first_runtime_import_line=$(sed -n \
		'/^[[:space:]]*\.[[:space:]]/{=;q;}' "$init_file")
	[ -n "$guard_line" ] && [ -n "$first_runtime_import_line" ] && \
		[ "$guard_line" -lt "$first_runtime_import_line" ] || \
		fail "$service_name 离线 rootfs 保护没有位于运行时脚本导入之前"
	printf '离线 rootfs 保护已应用：%s\n' "$service_name"
}

apply_openclash_menu_priority \
	"$OC_PAYLOAD/luasrc/controller/openclash.lua"
apply_passwall_cli_compatibility "$PASSWALL_API_SOURCE"
apply_passwall_socks_firewall_compatibility "$PASSWALL_NFTABLES_SOURCE"
apply_passwall_socks_firewall_compatibility "$PASSWALL_IPTABLES_SOURCE"
apply_passwall_loop_schedule_compatibility "$PASSWALL_APP_SOURCE"
apply_passwall_ifup_debounce_compatibility \
	"$PASSWALL_IFUP_SOURCE" "$PASSWALL_MAKEFILE"
apply_offline_rootfs_guard \
	"$OC_PAYLOAD/root/etc/init.d/openclash" openclash 'USE_PROCD=1'
apply_offline_rootfs_guard \
	"$PW_LUCI_PAYLOAD/luci-app-passwall/root/etc/init.d/passwall" passwall 'STOP=15'
OPENCLASH_INIT_SHA=$(sha256sum \
	"$OC_PAYLOAD/root/etc/init.d/openclash" | awk '{print $1}')
PASSWALL_INIT_SHA=$(sha256sum \
	"$PW_LUCI_PAYLOAD/luci-app-passwall/root/etc/init.d/passwall" | awk '{print $1}')
OPENCLASH_CONTROLLER_SHA=$(sha256sum \
	"$OC_PAYLOAD/luasrc/controller/openclash.lua" | awk '{print $1}')

for package_name in "${PASSWALL_DEPENDENCIES[@]}"; do
	[ -f "$PW_PACKAGES_PAYLOAD/$package_name/Makefile" ] || \
		fail "Passwall dependency Makefile is missing: $package_name"
done
DEPENDENCY_MAKEFILE_COUNT=$(find "$PW_PACKAGES_PAYLOAD" -mindepth 2 \
	-maxdepth 2 -type f -name Makefile | wc -l)
[ "$DEPENDENCY_MAKEFILE_COUNT" -ge "${#PASSWALL_DEPENDENCIES[@]}" ] || \
	fail "too few Passwall dependency Makefiles: $DEPENDENCY_MAKEFILE_COUNT"

check_shell_syntax_tree() {
	local tree=$1 file first_line count=0
	while IFS= read -r -d '' file; do
		first_line=$(head -n 1 "$file" 2>/dev/null || true)
		case "$first_line" in
			*'bash'*) bash -n "$file" ;;
			*) sh -n "$file" ;;
		esac
		count=$((count + 1))
	done < <(find "$tree" -type f \( \
		-name '*.sh' -o -path '*/etc/init.d/*' \
		-o -path '*/etc/hotplug.d/*/*' -o -path '*/etc/uci-defaults/*' \
	\) -print0)
	printf 'ShellSyntaxFiles[%s]=%s\n' "$tree" "$count"
}

check_safe_symlinks() {
	local tree=$1 link link_text resolved
	while IFS= read -r -d '' link; do
		link_text=$(readlink "$link" 2>/dev/null || true)
		case "$link_text" in /*) fail "absolute symlink in payload: $link" ;; esac
		resolved=$(readlink -f "$link" 2>/dev/null || true)
		case "$resolved" in
			"$tree"/*) ;;
			*) fail "unsafe or dangling symlink in payload: $link" ;;
		esac
	done < <(find "$tree" -type l -print0)
}

check_shell_syntax_tree "$OC_PAYLOAD"
check_shell_syntax_tree "$PW_LUCI_PAYLOAD"
check_shell_syntax_tree "$PW_PACKAGES_PAYLOAD"
check_safe_symlinks "$OC_PAYLOAD"
check_safe_symlinks "$PW_LUCI_PAYLOAD"
check_safe_symlinks "$PW_PACKAGES_PAYLOAD"

for target in "$TARGET_OC" "$TARGET_PW_LUCI" "$TARGET_PW_PACKAGES"; do
	case "$target" in "$ROOT"/package/*) ;; *) fail "unsafe source target: $target" ;; esac
	[ "$(readlink -f "${target%/*}")" = "$ROOT/package" ] || \
		fail "source target parent is not the real package directory: $target"
	[ "$(stat -c '%d' "${target%/*}")" = "$(stat -c '%d' "$ROOT")" ] || \
		fail "source target is on a different filesystem: $target"
done

record_source_state() {
	local name=$1 target=$2 had_old=0 status_file
	local old_path="$BACKUP_DIR/old/source/$name"
	if [ -e "$target" ] || [ -L "$target" ]; then
		had_old=1
		if [ -d "$target" ] && \
			git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			status_file="$BACKUP_DIR/${name}.git-status-before.txt"
			git -C "$target" status --short -- . > "$status_file" || true
			if [ -s "$status_file" ]; then
				printf 'WARNING: local changes in %s will be replaced and preserved in backup\n' \
					"$target" >&2
				cat "$status_file" >&2
			fi
		fi
	fi
	printf 'source|%s|%s|%s|%s\n' \
		"$name" "$target" "$old_path" "$had_old" >> "$STATE_FILE"
}

record_source_state openclash "$TARGET_OC"
record_source_state passwall-luci "$TARGET_PW_LUCI"
record_source_state passwall-packages "$TARGET_PW_PACKAGES"

DUPLICATE_PATHS=()
DUPLICATE_PACKAGE_NAMES=(
	luci-app-openclash luci-app-passwall "${PASSWALL_DEPENDENCIES[@]}"
)
if [ -d "$ROOT/package/feeds" ]; then
	for package_name in "${DUPLICATE_PACKAGE_NAMES[@]}"; do
		while IFS= read -r -d '' duplicate; do
			DUPLICATE_PATHS+=("$duplicate")
		done < <(find "$ROOT/package/feeds" -mindepth 2 -maxdepth 2 \
			\( -type d -o -type l \) -name "$package_name" -print0)
	done
fi

declare -a QUARANTINE_PATHS=()
declare -a QUARANTINE_BACKUPS=()
duplicate_index=0
for duplicate in "${DUPLICATE_PATHS[@]}"; do
	[ "$duplicate" != "$TARGET_OC" ] || continue
	[ "$duplicate" != "$TARGET_PW_LUCI" ] || continue
	[ "$duplicate" != "$TARGET_PW_PACKAGES" ] || continue
	if [ -e "$duplicate" ] || [ -L "$duplicate" ]; then
		case "$duplicate" in
			*$'\n'*|*'|'*) fail "unsupported character in feed conflict path: $duplicate" ;;
		esac
		[ ! -L "$ROOT/package/feeds" ] || \
			fail "package/feeds must not be a symlink: $ROOT/package/feeds"
		[ ! -L "${duplicate%/*}" ] || \
			fail "feed conflict parent must not be a symlink: ${duplicate%/*}"
		[ "$(readlink -f "${duplicate%/*}")" = "${duplicate%/*}" ] || \
			fail "feed conflict parent resolves outside package/feeds: ${duplicate%/*}"
		[ "$(stat -c '%d' "${duplicate%/*}")" = "$(stat -c '%d' "$ROOT")" ] || \
			fail "feed conflict is on a different filesystem: $duplicate"
		duplicate_index=$((duplicate_index + 1))
		backup_duplicate="$BACKUP_DIR/old/duplicate/$duplicate_index"
		printf 'duplicate|%04d|%s|%s|1\n' \
			"$duplicate_index" "$duplicate" "$backup_duplicate" >> "$STATE_FILE"
		QUARANTINE_PATHS+=("$duplicate")
		QUARANTINE_BACKUPS+=("$backup_duplicate")
	fi
done

cat > "$BACKUP_DIR/upstream-manifest.txt" <<EOF
OpenClash URL: $OPENCLASH_URL
OpenClash tag: $OPENCLASH_TAG
OpenClash version: $OPENCLASH_VERSION
OpenClash commit: $OPENCLASH_COMMIT
OpenClash LuCI menu priority: -5
OpenClash controller SHA256: $OPENCLASH_CONTROLLER_SHA
OpenClash offline-rootfs guard: enabled
OpenClash guarded init SHA256: $OPENCLASH_INIT_SHA
Passwall LuCI URL: $PASSWALL_LUCI_URL
Passwall LuCI branch: main
Passwall LuCI version: $PW_VERSION-$PW_RELEASE
Passwall LuCI commit: $PASSWALL_LUCI_COMMIT
Passwall upstream api.lua SHA256: $PASSWALL_API_UPSTREAM_SHA
Passwall packaged api.lua SHA256: $PASSWALL_API_SHA
Passwall api.lua compatibility: $PASSWALL_API_COMPAT_PATCH
Passwall upstream nftables.sh SHA256: $PASSWALL_NFTABLES_UPSTREAM_SHA
Passwall packaged nftables.sh SHA256: $PASSWALL_NFTABLES_SHA
Passwall upstream iptables.sh SHA256: $PASSWALL_IPTABLES_UPSTREAM_SHA
Passwall packaged iptables.sh SHA256: $PASSWALL_IPTABLES_SHA
Passwall socks firewall compatibility: $PASSWALL_SOCKS_COMPAT_PATCH
Passwall upstream app.sh SHA256: $PASSWALL_APP_UPSTREAM_SHA
Passwall packaged app.sh SHA256: $PASSWALL_APP_SHA
Passwall loop-schedule compatibility: $PASSWALL_LOOP_SCHEDULE_COMPAT_PATCH
Passwall upstream 98-passwall SHA256: $PASSWALL_IFUP_UPSTREAM_SHA
Passwall packaged 98-passwall SHA256: $PASSWALL_IFUP_SHA
Passwall ifup debounce compatibility: $PASSWALL_IFUP_DEBOUNCE_COMPAT_PATCH
Passwall offline-rootfs guard: enabled
Passwall guarded init SHA256: $PASSWALL_INIT_SHA
Passwall packages URL: $PASSWALL_PACKAGES_URL
Passwall packages branch: main
Passwall packages commit: $PASSWALL_PACKAGES_COMMIT
Passwall dependency Makefiles: $DEPENDENCY_MAKEFILE_COUNT
EOF

section '4. 替换三份源码并隔离重复的软件包链接'
LIVE_MUTATION_STARTED=1

swap_source() {
	local name=$1 payload=$2 target=$3
	local old_path="$BACKUP_DIR/old/source/$name"
	mkdir -p "${old_path%/*}" "${target%/*}"
	if [ -e "$target" ] || [ -L "$target" ]; then
		mv -T -- "$target" "$old_path"
	fi
	mv -T -- "$payload" "$target"
	printf 'installed=%s\n' "$target"
}

swap_source openclash "$OC_PAYLOAD" "$TARGET_OC"
swap_source passwall-luci "$PW_LUCI_PAYLOAD" "$TARGET_PW_LUCI"
swap_source passwall-packages "$PW_PACKAGES_PAYLOAD" "$TARGET_PW_PACKAGES"

for ((index=0; index<${#QUARANTINE_PATHS[@]}; index++)); do
	duplicate=${QUARANTINE_PATHS[$index]}
	backup_duplicate=${QUARANTINE_BACKUPS[$index]}
	mkdir -p "${backup_duplicate%/*}"
	mv -T -- "$duplicate" "$backup_duplicate"
	printf 'quarantined=%s\n' "$duplicate"
done

set_config_package_y() {
	local symbol=$1 config_file="$ROOT/.config" matched_count old_value patched_file
	matched_count=$(awk -v symbol="$symbol" '
		index($0, symbol "=") == 1 || $0 == "# " symbol " is not set" {
			count++
		}
		END { print count + 0 }
	' "$config_file")
	[ "$matched_count" -le 1 ] || \
		fail "$symbol 在 .config 中出现了 $matched_count 次，拒绝模糊修改"
	old_value=$(awk -v symbol="$symbol" '
		index($0, symbol "=") == 1 || $0 == "# " symbol " is not set" {
			print
		}
	' "$config_file")
	[ -n "$old_value" ] || old_value='<absent>'
	patched_file="${config_file}.plugin-sync.$$"
	[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
		fail "临时 .config 已存在：$patched_file"
	awk -v symbol="$symbol" '
		index($0, symbol "=") == 1 || $0 == "# " symbol " is not set" {
			next
		}
		{ print }
		END { print symbol "=y" }
	' "$config_file" > "$patched_file"
	chmod --reference="$config_file" "$patched_file"
	mv -T -- "$patched_file" "$config_file"
	[ "$(grep -Fxc "${symbol}=y" "$config_file" || true)" -eq 1 ] || \
		fail "$symbol 写入 y 后复核失败"
	printf '插件配置写入：%s -> %s=y\n' "$old_value" "$symbol"
}

set_config_package_disabled() {
	local symbol=$1 config_file="$ROOT/.config" matched_count old_value patched_file
	matched_count=$(awk -v symbol="$symbol" '
		index($0, symbol "=") == 1 || $0 == "# " symbol " is not set" {
			count++
		}
		END { print count + 0 }
	' "$config_file")
	[ "$matched_count" -le 1 ] || \
		fail "$symbol 在 .config 中出现了 $matched_count 次，拒绝模糊修改"
	old_value=$(awk -v symbol="$symbol" '
		index($0, symbol "=") == 1 || $0 == "# " symbol " is not set" {
			print
		}
	' "$config_file")
	[ -n "$old_value" ] || old_value='<absent>'
	patched_file="${config_file}.plugin-sync.$$"
	[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
		fail "临时 .config 已存在：$patched_file"
	awk -v symbol="$symbol" '
		index($0, symbol "=") == 1 || $0 == "# " symbol " is not set" {
			next
		}
		{ print }
	' "$config_file" > "$patched_file"
	chmod --reference="$config_file" "$patched_file"
	mv -T -- "$patched_file" "$config_file"
	if grep -Eq "^${symbol}(=|_)" "$config_file"; then
		fail "$symbol 禁用后仍在 .config 中被选择"
	fi
	printf '插件配置禁用：%s -> %s\n' "$old_value" "$symbol"
}

assert_luci_mount_disabled() {
	local phase=$1 forbidden_path
	if grep -Eq "^${LUCIMOUNT_CONFIG_SYMBOL}(=|_)" "$ROOT/.config"; then
		fail "$phase：禁止选择 $LUCIMOUNT_CONFIG_SYMBOL"
	fi
	for forbidden_path in \
		"$ROOT/package/luci-app-mount" \
		"$ROOT/package/feeds/luci/luci-app-mount" \
		"$ROOT/feeds/luci/applications/luci-app-mount" \
		"$LUCIMOUNT_PAGE"; do
		[ ! -e "$forbidden_path" ] && [ ! -L "$forbidden_path" ] || \
			fail "$phase：禁止存在 LuCI 挂载点组件：$forbidden_path"
	done
	if [ -f "$LUCIMOUNT_MENU" ] && grep -Fq '"admin/system/mounts"' "$LUCIMOUNT_MENU"; then
		fail "$phase：禁止存在 LuCI 挂载点菜单"
	fi
	if [ -f "$LUCIMOUNT_ACL" ] && grep -Fq '"luci-mod-system-mounts"' "$LUCIMOUNT_ACL"; then
		fail "$phase：禁止存在 LuCI 挂载点 ACL"
	fi
	printf 'LuCI 挂载点保持禁用：%s\n' "$phase"
}

assert_upnp_lan_rebind_hook() {
	[ -f "$UPNP_HOTPLUG_FILE" ] && [ ! -L "$UPNP_HOTPLUG_FILE" ] || \
		fail "UPnP 热插拔脚本不存在或不是普通文件：$UPNP_HOTPLUG_FILE"
	grep -Fqx 'if [ "$INTERFACE" = "lan" ] && [ "$ACTION" = "ifup" ]; then' \
		"$UPNP_HOTPLUG_FILE" || \
		fail 'UPnP 未配置 LAN ifup 自动重绑钩子'
	grep -Fqx $'\t/etc/init.d/miniupnpd restart' "$UPNP_HOTPLUG_FILE" || \
		fail 'UPnP LAN 自动重绑钩子未重启 miniupnpd'
	printf 'UPnP LAN 地址变更自动重绑钩子已启用\n'
}

assert_modem_runtime_fixes() {
	[ -f "$MODEM_NETWORK_TASK" ] && [ ! -L "$MODEM_NETWORK_TASK" ] || \
		fail "Modem 网络任务不存在或不是普通文件：$MODEM_NETWORK_TASK"
	[ -f "$MODEM_CFUN_INIT" ] && [ ! -L "$MODEM_CFUN_INIT" ] || \
		fail "Modem CFUN 初始化脚本不存在或不是普通文件：$MODEM_CFUN_INIT"
	grep -Fqx 'FM350_IPV6_REFRESH_INTERVAL=900' "$MODEM_NETWORK_TASK" || \
		fail 'FM350 RNDIS IPv6 刷新周期未配置'
	grep -Fqx '            rndis:fibocom:*fm350*)' "$MODEM_NETWORK_TASK" || \
		fail 'FM350 RNDIS IPv6 刷新未限制到广和通 FM350'
	grep -Fq 'Network reachability failed for 3 consecutive multi-target probes' \
		"$MODEM_NETWORK_TASK" || \
		fail 'Modem 多目标连续失败探测未启用'
	grep -Fq 'ping -c 1 -W 3 -I "${interface_network}" "${probe_target}"' \
		"$MODEM_NETWORK_TASK" || \
		fail 'Modem 连通性探测未绑定实际网络接口'
	grep -Fqx 'READY_FILE="/tmp/sendat-cfun.ready"' "$MODEM_CFUN_INIT" && \
		grep -Fqx $'\ttouch "${READY_FILE}"' "$MODEM_CFUN_INIT" || \
		fail 'Modem CFUN 完成标记未写入，at-server 仍可能等待超时'
	printf 'Modem 多目标探测、FM350 RNDIS IPv6 刷新和 CFUN 启动同步已启用\n'
}

set_r3mini_lan_default() {
	local current_count patched_file
	current_count=$(awk '
		/^[[:space:]]*uci set network\.lan\.ipaddr='\''[0-9.]*'\''[[:space:]]*$/ { count++ }
		END { print count + 0 }
	' "$R3MINI_LAN_DEFAULT_FILE")
	[ "$current_count" -eq 1 ] || \
		fail "R3 Mini LAN 默认地址行数量异常：$current_count"
	patched_file="${R3MINI_LAN_DEFAULT_FILE}.lan-ip.$$"
	[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
		fail "R3 Mini LAN 临时配置文件已存在：$patched_file"
	awk -v ip="$R3MINI_LAN_TEST_IP" '
		/^[[:space:]]*uci set network\.lan\.ipaddr='\''[0-9.]*'\''[[:space:]]*$/ {
			print "uci set network.lan.ipaddr='\''" ip "'\''"
			next
		}
		{ print }
	' "$R3MINI_LAN_DEFAULT_FILE" > "$patched_file"
	chmod --reference="$R3MINI_LAN_DEFAULT_FILE" "$patched_file"
	mv -T -- "$patched_file" "$R3MINI_LAN_DEFAULT_FILE"
	grep -Fqx "uci set network.lan.ipaddr='$R3MINI_LAN_TEST_IP'" \
		"$R3MINI_LAN_DEFAULT_FILE" || \
		fail "R3 Mini LAN 默认地址写入失败：$R3MINI_LAN_TEST_IP"
	printf 'R3 Mini 固件默认 LAN 地址=%s\n' "$R3MINI_LAN_TEST_IP"
}

set_rust_version() {
	local version_count hash_count patched_file
	version_count=$(grep -Ec '^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+$' "$RUST_MAKEFILE")
	hash_count=$(grep -Ec '^PKG_HASH:=[0-9a-f]{64}$' "$RUST_MAKEFILE")
	[ "$version_count" -eq 1 ] && [ "$hash_count" -eq 1 ] || \
		fail "Rust 配方版本或哈希行数量异常：version=$version_count hash=$hash_count"
	patched_file="${RUST_MAKEFILE}.rust-version.$$"
	[ ! -e "$patched_file" ] && [ ! -L "$patched_file" ] || \
		fail "Rust 临时配方文件已存在：$patched_file"
	awk -v version="$RUST_VERSION" -v hash="$RUST_SOURCE_HASH" '
		/^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+$/ { print "PKG_VERSION:=" version; next }
		/^PKG_HASH:=[0-9a-f]{64}$/ { print "PKG_HASH:=" hash; next }
		{ print }
	' "$RUST_MAKEFILE" > "$patched_file"
	chmod --reference="$RUST_MAKEFILE" "$patched_file"
	mv -T -- "$patched_file" "$RUST_MAKEFILE"
	grep -Fqx "PKG_VERSION:=$RUST_VERSION" "$RUST_MAKEFILE" && \
		grep -Fqx "PKG_HASH:=$RUST_SOURCE_HASH" "$RUST_MAKEFILE" || \
		fail 'Rust 版本或源码哈希写入失败'
	printf 'Rust 构建版本=%s，源码 SHA256=%s\n' "$RUST_VERSION" "$RUST_SOURCE_HASH"
}

ensure_host_python() {
	local host_bin="$ROOT/staging_dir/host/bin" system_python host_python backup_path name
	system_python=$(command -v python3 || true)
	[ -n "$system_python" ] && [ -x "$system_python" ] || \
		fail '24.04 宿主机缺少可执行的 python3'
	mkdir -p "$host_bin"
	for name in python python3; do
		host_python="$host_bin/$name"
		if [ -x "$host_python" ] && \
			"$host_python" -c 'import sys; assert sys.version_info[0] == 3' \
			>/dev/null 2>&1; then
			printf '宿主 Python 链接有效：%s -> %s\n' \
				"$host_python" "$(readlink -f "$host_python")"
			continue
		fi
		if [ -e "$host_python" ] || [ -L "$host_python" ]; then
			backup_path="$BACKUP_DIR/host-python-${name}.before"
			[ ! -e "$backup_path" ] && [ ! -L "$backup_path" ] || \
				backup_path="${backup_path}.$(date +%s).$$"
			cp -a -- "$host_python" "$backup_path"
			[ ! -d "$host_python" ] || \
				fail "宿主 Python 路径是目录，拒绝覆盖：$host_python"
			rm -f -- "$host_python"
			printf '宿主 Python 旧链接已备份：%s\n' "$backup_path"
		fi
		ln -s -- "$system_python" "$host_python"
		"$host_python" -c 'import sys; assert sys.version_info[0] == 3' \
			>/dev/null 2>&1 || fail "宿主 Python 链接修复失败：$host_python"
		printf '宿主 Python 链接已修复：%s -> %s\n' \
			"$host_python" "$(readlink -f "$host_python")"
	done
}

section '5. 将更新后的插件和 NVMe 工具同步进当前 .config'
ensure_host_python
set_r3mini_lan_default
set_rust_version
assert_upnp_lan_rebind_hook
assert_modem_runtime_fixes
set_config_package_y CONFIG_PACKAGE_luci-app-openclash
set_config_package_y CONFIG_PACKAGE_luci-app-passwall
for config_symbol in "${NVME_CONFIG_SYMBOLS[@]}"; do
	set_config_package_y "$config_symbol"
done
set_config_package_disabled "$LUCIMOUNT_CONFIG_SYMBOL"
assert_luci_mount_disabled 'make defconfig 前'
(
	cd "$ROOT"
	make defconfig
) 2>&1 | tee "$BACKUP_DIR/make-defconfig.log"

assert_luci_mount_disabled 'make defconfig 后'

[ -f "$ROOT/tmp/.packageinfo" ] || fail 'make defconfig did not create tmp/.packageinfo'
for package_name in \
	luci-app-openclash luci-app-passwall xray-core sing-box chinadns-ng nvme-cli
do
	grep -qx "Package: $package_name" "$ROOT/tmp/.packageinfo" || \
		fail "package metadata is missing: $package_name"
done

verify_unique_source() {
	local package_name=$1 expected_root=$2 list_file count actual
	list_file="$STAGE_ROOT/${package_name}.sources"
	: > "$list_file"
	while IFS= read -r -d '' makefile; do
		if grep -qx "PKG_NAME:=$package_name" "$makefile"; then
			readlink -f "${makefile%/Makefile}" >> "$list_file"
		fi
	done < <(find -L "$ROOT/package" -type f -name Makefile -print0 2>/dev/null)
	sort -u "$list_file" -o "$list_file"
	count=$(wc -l < "$list_file")
	[ "$count" -eq 1 ] || {
		cat "$list_file" >&2
		fail "expected one active $package_name source, found $count"
	}
	actual=$(sed -n '1p' "$list_file")
	case "$actual" in
		"$expected_root"|"$expected_root"/*) ;;
		*) fail "$package_name resolved outside expected source: $actual" ;;
	esac
	printf 'ActiveSource[%s]=%s\n' "$package_name" "$actual"
}

verify_unique_directory_source() {
	local package_name=$1 expected_root=$2 list_file count actual
	list_file="$STAGE_ROOT/${package_name}.directory-sources"
	: > "$list_file"
	while IFS= read -r -d '' makefile; do
		readlink -f "${makefile%/Makefile}" >> "$list_file"
	done < <(find -L "$ROOT/package" -type f \
		-path "*/$package_name/Makefile" -print0 2>/dev/null)
	sort -u "$list_file" -o "$list_file"
	count=$(wc -l < "$list_file")
	[ "$count" -eq 1 ] || {
		cat "$list_file" >&2
		fail "expected one active $package_name source directory, found $count"
	}
	actual=$(sed -n '1p' "$list_file")
	case "$actual" in
		"$expected_root"|"$expected_root"/*) ;;
		*) fail "$package_name resolved outside expected source: $actual" ;;
	esac
	printf 'ActiveSource[%s]=%s\n' "$package_name" "$actual"
}

verify_unique_source luci-app-openclash "$TARGET_OC"
verify_unique_source luci-app-passwall "$TARGET_PW_LUCI"
for package_name in "${PASSWALL_DEPENDENCIES[@]}"; do
	verify_unique_directory_source "$package_name" "$TARGET_PW_PACKAGES"
done

ACTIVE_OC_VERSION=$(sed -n 's/^PKG_VERSION:=//p' \
	"$TARGET_OC/Makefile" | head -n 1)
ACTIVE_PW_VERSION=$(sed -n 's/^PKG_VERSION:=//p' \
	"$TARGET_PW_LUCI/luci-app-passwall/Makefile" | head -n 1)
ACTIVE_PW_RELEASE=$(sed -n 's/^PKG_RELEASE:=//p' \
	"$TARGET_PW_LUCI/luci-app-passwall/Makefile" | head -n 1)

[ "$ACTIVE_OC_VERSION" = "$OPENCLASH_VERSION" ] || \
	fail 'active OpenClash version changed after source switch'
[ "$ACTIVE_PW_VERSION" = "$PW_VERSION" ] && \
	[ "$ACTIVE_PW_RELEASE" = "$PW_RELEASE" ] || \
	fail 'active Passwall version changed after source switch'
[ "$(sha256sum "$TARGET_OC/root/etc/init.d/openclash" | awk '{print $1}')" = \
	"$OPENCLASH_INIT_SHA" ] || \
	fail 'active OpenClash init script lost the offline-rootfs guard after source switch'
[ "$(sha256sum "$TARGET_OC/luasrc/controller/openclash.lua" | awk '{print $1}')" = \
	"$OPENCLASH_CONTROLLER_SHA" ] || \
	fail '正式 OpenClash 控制器丢失菜单优先级修改'
[ "$(sha256sum "$TARGET_PW_LUCI/luci-app-passwall/root/etc/init.d/passwall" | \
	awk '{print $1}')" = "$PASSWALL_INIT_SHA" ] || \
	fail 'active Passwall init script lost the offline-rootfs guard after source switch'
ACTIVE_PASSWALL_API="$TARGET_PW_LUCI/luci-app-passwall/luasrc/passwall/api.lua"
[ -f "$ACTIVE_PASSWALL_API" ] && [ ! -L "$ACTIVE_PASSWALL_API" ] || \
	fail 'active Passwall api.lua is missing or is a symlink after source switch'
[ "$(sha256sum "$ACTIVE_PASSWALL_API" | awk '{print $1}')" = \
	"$PASSWALL_API_SHA" ] || \
	fail 'active Passwall api.lua differs from the validated upstream payload'
[ "$(grep -Ec \
	'^[[:space:]]*cbi[[:space:]]*=[[:space:]]*require[[:space:]]*"luci\.cbi"[[:space:]]*$' \
	"$ACTIVE_PASSWALL_API" || true)" -eq 0 ] || \
	fail 'active Passwall api.lua gained an eager luci.cbi import after source switch'
ACTIVE_PASSWALL_NFTABLES="$TARGET_PW_LUCI/luci-app-passwall/root/usr/share/passwall/nftables.sh"
ACTIVE_PASSWALL_IPTABLES="$TARGET_PW_LUCI/luci-app-passwall/root/usr/share/passwall/iptables.sh"
ACTIVE_PASSWALL_APP="$TARGET_PW_LUCI/luci-app-passwall/root/usr/share/passwall/app.sh"
ACTIVE_PASSWALL_IFUP="$TARGET_PW_LUCI/luci-app-passwall/root/etc/hotplug.d/iface/98-passwall"
[ "$(sha256sum "$ACTIVE_PASSWALL_NFTABLES" | awk '{print $1}')" = \
	"$PASSWALL_NFTABLES_SHA" ] || \
	fail 'active Passwall nftables.sh differs from the validated compatibility payload'
[ "$(sha256sum "$ACTIVE_PASSWALL_IPTABLES" | awk '{print $1}')" = \
	"$PASSWALL_IPTABLES_SHA" ] || \
	fail 'active Passwall iptables.sh differs from the validated compatibility payload'
[ "$(grep -Fc 'is_socks_wrap' "$ACTIVE_PASSWALL_NFTABLES" || true)" -eq 0 ] && \
	[ "$(grep -Fc 'is_socks_wrap' "$ACTIVE_PASSWALL_IPTABLES" || true)" -eq 0 ] || \
	fail 'active Passwall firewall scripts still call removed is_socks_wrap'
[ "$(sha256sum "$ACTIVE_PASSWALL_APP" | awk '{print $1}')" = \
	"$PASSWALL_APP_SHA" ] || \
	fail 'active Passwall app.sh differs from the validated loop-schedule payload'
[ "$(sha256sum "$ACTIVE_PASSWALL_IFUP" | awk '{print $1}')" = \
	"$PASSWALL_IFUP_SHA" ] || \
	fail 'active Passwall 98-passwall differs from the validated debounce payload'
printf '正式源码复核通过：OpenClash 菜单=-5，Passwall API、防火墙及定时脚本未漂移，离线 rootfs 保护=openclash、passwall\n'

verify_current_config_preserved() {
	local config_line preserved_count=0 allowed_change_count
	local changed_file="$BACKUP_DIR/config-preservation-errors.txt"
	local allowed_file="$BACKUP_DIR/config-defconfig-package-changes.txt"
	: > "$changed_file"
	: > "$allowed_file"
	while IFS= read -r config_line || [ -n "$config_line" ]; do
		case "$config_line" in
			CONFIG_PACKAGE_luci-app-openclash=*|\
			CONFIG_PACKAGE_luci-app-passwall=*|\
			CONFIG_PACKAGE_kmod-nvme=*|\
			CONFIG_PACKAGE_libnvme=*|\
			CONFIG_PACKAGE_nvme-cli=*|\
			CONFIG_PACKAGE_luci-app-mount=*|\
			'# CONFIG_PACKAGE_luci-app-openclash is not set'|\
			'# CONFIG_PACKAGE_luci-app-passwall is not set'|\
			'# CONFIG_PACKAGE_kmod-nvme is not set'|\
			'# CONFIG_PACKAGE_libnvme is not set'|\
			'# CONFIG_PACKAGE_nvme-cli is not set'|\
			'# CONFIG_PACKAGE_luci-app-mount is not set')
				# OpenClash、Passwall 和 NVMe 栈按用户要求固定；挂载点 LuCI 必须禁用。
				;;
			CONFIG_PACKAGE_*=*)
				preserved_count=$((preserved_count + 1))
				grep -Fqx -- "$config_line" "$ROOT/.config" ||
					printf '原配置项发生变化或消失：%s\n' \
						"$config_line" >> "$changed_file"
				;;
			# This is a generated package override hint, not a stable Kconfig
			# symbol; make defconfig may drop it when the referenced packages
			# are absent from the active feeds.
			CONFIG_OVERRIDE_PKGS=*)
				;;
			'# CONFIG_PACKAGE_'*' is not set')
				# 允许新插件的依赖将原未选软件包改为 y/m。
				;;
			CONFIG_*=*|'# CONFIG_'*' is not set')
				preserved_count=$((preserved_count + 1))
				grep -Fqx -- "$config_line" "$ROOT/.config" ||
					printf '原非软件包配置项发生变化或消失：%s\n' \
						"$config_line" >> "$changed_file"
				;;
		esac
	done < "$BACKUP_DIR/config.before"
	while IFS= read -r config_line || [ -n "$config_line" ]; do
		case "$config_line" in
			CONFIG_*=*)
				grep -Fqx -- "$config_line" "$BACKUP_DIR/config.before" || \
					printf '%s\n' "$config_line" >> "$allowed_file"
				;;
		esac
	done < "$ROOT/.config"
	if [ -s "$changed_file" ]; then
		cat "$changed_file" >&2
		fail "make defconfig 改变了不应变动的当前配置；已停止并回滚源码与配置"
	fi
	allowed_change_count=$(wc -l < "$allowed_file")
	printf '配置保护检查通过：原有 %s 个必须保持的配置项未变\n' \
		"$preserved_count"
	printf 'defconfig 为新插件/新符号新增的有值配置项=%s，证据=%s\n' \
		"$allowed_change_count" "$allowed_file"
}

verify_current_config_preserved

for config_symbol in \
	CONFIG_PACKAGE_luci-app-openclash CONFIG_PACKAGE_luci-app-passwall \
	"${NVME_CONFIG_SYMBOLS[@]}"
do
	grep -qx "${config_symbol}=y" "$ROOT/.config" || \
		fail "$config_symbol 没有在 make defconfig 后作为 y 内置进固件"
	printf '插件配置已同步[%s]=y\n' "$config_symbol"
done

cp -a -- "$ROOT/.config" "$BACKUP_DIR/config.for-build"
CONFIG_BUILD_SHA=$(sha256sum "$BACKUP_DIR/config.for-build" | awk '{print $1}')
TARGET_BOARD=$(sed -n 's/^CONFIG_TARGET_BOARD="\([^"]*\)"$/\1/p' \
	"$BACKUP_DIR/config.for-build" | head -n 1)
TARGET_SUBTARGET=$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\([^"]*\)"$/\1/p' \
	"$BACKUP_DIR/config.for-build" | head -n 1)
TARGET_DIR=$(
	cd "$ROOT"
	make -s val.TARGET_DIR
)
TARGET_DEVICE_FILE="$BACKUP_DIR/config-target-devices.txt"
grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' \
	"$BACKUP_DIR/config.for-build" > "$TARGET_DEVICE_FILE" || true
[ -n "$TARGET_BOARD" ] && [ -n "$TARGET_SUBTARGET" ] || \
	fail '当前 .config 缺少 CONFIG_TARGET_BOARD 或 CONFIG_TARGET_SUBTARGET，拒绝编译未知目标'
[[ "$TARGET_BOARD" =~ ^[A-Za-z0-9._-]+$ ]] && \
	[[ "$TARGET_SUBTARGET" =~ ^[A-Za-z0-9._-]+$ ]] || \
	fail 'CONFIG_TARGET_BOARD/SUBTARGET 含有不安全字符，拒绝拼接输出目录'
case "$TARGET_DIR" in
	*$'\n'*|*'|'*) fail 'make val.TARGET_DIR 返回了不安全的多行或 | 路径' ;;
	"$ROOT"/build_dir/target-*/root-"$TARGET_BOARD") ;;
	*) fail "真实 TARGET_DIR 不在预期的当前源码 build_dir 内：$TARGET_DIR" ;;
esac
[ -s "$TARGET_DEVICE_FILE" ] || \
	fail '当前 .config 没有选中任何 CONFIG_TARGET_*_DEVICE_* 设备，拒绝编译'
printf '本次编译配置=%s\n' "$BACKUP_DIR/config.for-build"
printf '编译配置SHA256=%s\n' "$CONFIG_BUILD_SHA"
printf '编译目标=%s/%s\n' "$TARGET_BOARD" "$TARGET_SUBTARGET"
printf '编译目标rootfs=%s\n' "$TARGET_DIR"
printf '已选设备：\n'
cat "$TARGET_DEVICE_FILE"

section '6. 清理 OpenClash/Passwall 旧构建缓存'
CLEAN_LOG="$BACKUP_DIR/plugin-clean.log"
(
	cd "$ROOT"
	make package/luci-app-openclash/clean V=s
	make package/passwall-luci/luci-app-passwall/clean V=s
	make package/feeds/packages/rust/clean V=s
	make package/mtk/applications/5g-modem/luci-app-modem/clean V=s
) 2>&1 | tee "$CLEAN_LOG"
[ -f "$ROOT/.config" ] && [ ! -L "$ROOT/.config" ] && \
	cmp -s "$BACKUP_DIR/config.for-build" "$ROOT/.config" || \
	fail '清理旧构建缓存时 .config 发生变化'
printf '旧构建缓存已清理，确保 OpenClash 菜单 -5 会重新编译\n'

printf 'COMMITTED %s\n' "$(date -Is)" > "$BACKUP_DIR/COMMITTED"
COMMITTED=1
rm -f -- "$POINTER"
TRANSACTION_ACTIVE=0
if ! safe_cleanup_stage; then
	printf 'WARNING: sources were committed but stage cleanup was skipped: %s\n' \
		"$STAGE_ROOT" >&2
fi
STAGE_ROOT=

printf '源码更新成功：OpenClash、Passwall LuCI 和 Passwall 依赖包均已通过检查\n'

section "7. 使用同步后的 .config 前台编译固件（make -j${MAKE_JOBS} V=s）"
BUILD_LOG="$BACKUP_DIR/firmware-build-j${MAKE_JOBS}.log"
BUILD_SERIAL_LOG="$BACKUP_DIR/firmware-build-j1-diagnose.log"
BUILD_ERROR_SUMMARY="$BACKUP_DIR/firmware-build-errors.txt"
ROOTFS_IMPORT_ERRORS="$BACKUP_DIR/firmware-rootfs-import-errors.txt"
BUILD_MARKER="$BACKUP_DIR/firmware-build-start.marker"
TARGET_OUTPUT_DIR="$ROOT/bin/targets/$TARGET_BOARD/$TARGET_SUBTARGET"
FRESH_IMAGES="$BACKUP_DIR/firmware-images.txt"
FRESH_MAIN_IMAGES="$BACKUP_DIR/firmware-main-images.txt"
FRESH_MANIFESTS="$BACKUP_DIR/firmware-manifests.txt"
ARTIFACT_SHA="$BACKUP_DIR/firmware-artifacts.sha256"
HASH_VERIFY_LOG="$BACKUP_DIR/firmware-sha256-check.log"
: > "$BUILD_MARKER"

BUILD_PHASE_ACTIVE=1
set +e
(
	cd "$ROOT"
	make -j"$MAKE_JOBS" V=s
) 2>&1 | tee "$BUILD_LOG"
BUILD_PIPESTATUS=("${PIPESTATUS[@]}")
BUILD_RC=${BUILD_PIPESTATUS[0]:-99}
BUILD_TEE_RC=${BUILD_PIPESTATUS[1]:-99}
set -e

printf '固件编译退出码（-j%s）=%s\n' "$MAKE_JOBS" "$BUILD_RC"

if [ "$BUILD_TEE_RC" -ne 0 ]; then
	fail "源码更新已经成功，但无法完整写入并行固件编译日志：$BUILD_LOG"
fi

if [ "$BUILD_RC" -ne 0 ] && [ "$MAKE_JOBS" -ne 1 ]; then
	printf '并行编译失败，开始使用 make -j1 V=s 复现并记录诊断日志：%s\n' \
		"$BUILD_SERIAL_LOG" >&2
	set +e
	(
		cd "$ROOT"
		make -j1 V=s
	) 2>&1 | tee "$BUILD_SERIAL_LOG"
	BUILD_PIPESTATUS=("${PIPESTATUS[@]}")
	BUILD_RC=${BUILD_PIPESTATUS[0]:-99}
	BUILD_TEE_RC=${BUILD_PIPESTATUS[1]:-99}
	set -e
	BUILD_LOG="$BUILD_SERIAL_LOG"
	printf '单线程诊断编译退出码=%s\n' "$BUILD_RC"
fi

CONFIG_CHANGED_DURING_BUILD=0
if [ ! -f "$ROOT/.config" ] || [ -L "$ROOT/.config" ] || \
	! cmp -s "$BACKUP_DIR/config.for-build" "$ROOT/.config"; then
	CONFIG_CHANGED_DURING_BUILD=1
	restore_config_for_build || fail '无法恢复编译前配置'
	printf '警告：编译过程改动了 .config，已经恢复 config.for-build。\n' >&2
fi
BUILD_PHASE_ACTIVE=0

if [ "$BUILD_TEE_RC" -ne 0 ]; then
	fail "源码更新已经成功，但无法完整写入固件编译日志：$BUILD_LOG"
fi
if [ "$BUILD_RC" -ne 0 ]; then
	grep -Ei \
		'Collected errors:|kernel.*(ABI|mismatch|incompatible)|ABI.*kernel|(^|[[:space:]])ERROR:' \
		"$BUILD_LOG" | tail -n 200 > "$BUILD_ERROR_SUMMARY" || true
	if [ -s "$BUILD_ERROR_SUMMARY" ]; then
		printf '编译错误摘要：\n' >&2
		cat "$BUILD_ERROR_SUMMARY" >&2
	fi
	fail "源码更新已经成功，但固件编译失败（退出码 $BUILD_RC）；完整日志：$BUILD_LOG"
fi

if grep -Eq '^[[:space:]]*Collected errors:' "$BUILD_LOG"; then
	fail "源码更新已经成功，make 返回 0，但日志仍包含 Collected errors；不能判定固件编译成功：$BUILD_LOG"
fi

grep -E \
	'root-[^/]*/usr/share/(openclash|passwall)/.*No such file or directory' \
	"$BUILD_LOG" > "$ROOTFS_IMPORT_ERRORS" || true
if [ -s "$ROOTFS_IMPORT_ERRORS" ]; then
	cat "$ROOTFS_IMPORT_ERRORS" >&2
	fail "离线 rootfs 启用服务时仍加载了 OpenClash/Passwall 运行期脚本；本次固件不能判定成功"
fi
printf '离线 rootfs 检查通过：OpenClash/Passwall 未再出现宿主机绝对路径缺失\n'

ROOTFS_OC_CONTROLLER_LIST="$BACKUP_DIR/rootfs-openclash-controllers.txt"
ROOTFS_OC_CONTROLLER_SHA_FILE="$BACKUP_DIR/rootfs-openclash-controller.sha256"
[ -d "$TARGET_DIR" ] && [ ! -L "$TARGET_DIR" ] || \
	fail "编译后真实 TARGET_DIR 不存在或为链接：$TARGET_DIR"
TARGET_DIR_RESOLVED=$(readlink -f "$TARGET_DIR")
[ "$TARGET_DIR_RESOLVED" = "$TARGET_DIR" ] || \
	fail "编译后 TARGET_DIR 解析路径发生变化：$TARGET_DIR_RESOLVED"
ROOTFS_OC_CONTROLLER="$TARGET_DIR/usr/lib/lua/luci/controller/openclash.lua"
[ -f "$ROOTFS_OC_CONTROLLER" ] && [ ! -L "$ROOTFS_OC_CONTROLLER" ] || \
	fail "真实 TARGET_DIR 中没有 OpenClash 控制器：$ROOTFS_OC_CONTROLLER"
printf '%s\n' "$ROOTFS_OC_CONTROLLER" > "$ROOTFS_OC_CONTROLLER_LIST"
ROOTFS_OC_PRIORITY_MINUS5_COUNT=$(grep -Fc \
	'page = entry({"admin", "services", "openclash"}, alias("admin", "services", "openclash", "client"), _("OpenClash"), -5)' \
	"$ROOTFS_OC_CONTROLLER" || true)
ROOTFS_OC_PRIORITY_50_COUNT=$(grep -Fc \
	'page = entry({"admin", "services", "openclash"}, alias("admin", "services", "openclash", "client"), _("OpenClash"), 50)' \
	"$ROOTFS_OC_CONTROLLER" || true)
[ "$ROOTFS_OC_PRIORITY_MINUS5_COUNT" -eq 1 ] && \
	[ "$ROOTFS_OC_PRIORITY_50_COUNT" -eq 0 ] || \
	fail '编译后 rootfs 中 OpenClash 菜单优先级不是唯一的 -5'
sha256sum "$ROOTFS_OC_CONTROLLER" > "$ROOTFS_OC_CONTROLLER_SHA_FILE"
ROOTFS_OPENCLASH_CONTROLLER_SHA=$(awk '{print $1}' \
	"$ROOTFS_OC_CONTROLLER_SHA_FILE")
[ "$ROOTFS_OPENCLASH_CONTROLLER_SHA" = "$OPENCLASH_CONTROLLER_SHA" ] || \
	fail '编译后 rootfs 控制器 SHA256 与本次同步并修改的源码不同'
printf '编译后 rootfs 检查通过：OpenClash 菜单优先级=-5，SHA256=%s\n' \
	"$ROOTFS_OPENCLASH_CONTROLLER_SHA"

ROOTFS_NVME="$TARGET_DIR/usr/sbin/nvme"
[ -x "$ROOTFS_NVME" ] || \
	fail "真实 TARGET_DIR 中没有可执行的 nvme-cli：$ROOTFS_NVME"
for forbidden_path in \
	"$TARGET_DIR/usr/share/luci/menu.d/luci-app-mount.json" \
	"$TARGET_DIR/www/luci-static/resources/view/system/mounts.js"; do
	[ ! -e "$forbidden_path" ] && [ ! -L "$forbidden_path" ] || \
		fail "编译后 rootfs 中出现了被禁用的 LuCI 挂载点组件：$forbidden_path"
done
ROOTFS_LUCIMOUNT_MENU="$TARGET_DIR/usr/share/luci/menu.d/luci-mod-system.json"
ROOTFS_LUCIMOUNT_ACL="$TARGET_DIR/usr/share/rpcd/acl.d/luci-mod-system.json"
if [ -f "$ROOTFS_LUCIMOUNT_MENU" ] && grep -Fq '"admin/system/mounts"' "$ROOTFS_LUCIMOUNT_MENU"; then
	fail '编译后 rootfs 中出现了被禁用的 LuCI 挂载点菜单'
fi
if [ -f "$ROOTFS_LUCIMOUNT_ACL" ] && grep -Fq '"luci-mod-system-mounts"' "$ROOTFS_LUCIMOUNT_ACL"; then
	fail '编译后 rootfs 中出现了被禁用的 LuCI 挂载点 ACL'
fi
printf '编译后 rootfs 检查通过：nvme-cli=%s，LuCI 挂载点保持禁用\n' \
	"$ROOTFS_NVME"

ROOTFS_PASSWALL_API="$TARGET_DIR/usr/lib/lua/luci/passwall/api.lua"
ROOTFS_PASSWALL_API_SHA_FILE="$BACKUP_DIR/rootfs-passwall-api.sha256"
[ -f "$ROOTFS_PASSWALL_API" ] && [ ! -L "$ROOTFS_PASSWALL_API" ] || \
	fail "真实 TARGET_DIR 中没有 Passwall api.lua：$ROOTFS_PASSWALL_API"
sha256sum "$ROOTFS_PASSWALL_API" > "$ROOTFS_PASSWALL_API_SHA_FILE"
ROOTFS_PASSWALL_API_SHA=$(awk '{print $1}' \
	"$ROOTFS_PASSWALL_API_SHA_FILE")
[ "$ROOTFS_PASSWALL_API_SHA" = "$PASSWALL_API_SHA" ] || \
	fail '编译后 rootfs 中 Passwall api.lua 与本次同步的官方源码不同'
[ "$(grep -Ec \
	'^[[:space:]]*cbi[[:space:]]*=[[:space:]]*require[[:space:]]*"luci\.cbi"[[:space:]]*$' \
	"$ROOTFS_PASSWALL_API" || true)" -eq 0 ] || \
	fail '编译后 rootfs 中 Passwall api.lua 含有会破坏CLI/init的提前luci.cbi导入'
printf '编译后 rootfs 检查通过：Passwall api.lua SHA256=%s，无提前luci.cbi导入\n' \
	"$ROOTFS_PASSWALL_API_SHA"

ROOTFS_PASSWALL_NFTABLES="$TARGET_DIR/usr/share/passwall/nftables.sh"
ROOTFS_PASSWALL_IPTABLES="$TARGET_DIR/usr/share/passwall/iptables.sh"
ROOTFS_PASSWALL_APP="$TARGET_DIR/usr/share/passwall/app.sh"
ROOTFS_PASSWALL_IFUP="$TARGET_DIR/etc/hotplug.d/iface/98-passwall"
[ -f "$ROOTFS_PASSWALL_IFUP" ] && [ ! -L "$ROOTFS_PASSWALL_IFUP" ] || \
	fail "compiled rootfs has no regular Passwall 98-passwall: $ROOTFS_PASSWALL_IFUP"
ROOTFS_FLOCK=
for candidate in \
	"$TARGET_DIR/usr/bin/flock" "$TARGET_DIR/bin/flock" \
	"$TARGET_DIR/usr/sbin/flock" "$TARGET_DIR/sbin/flock"; do
	if [ -x "$candidate" ]; then
		ROOTFS_FLOCK=$candidate
		break
	fi
done
[ -n "$ROOTFS_FLOCK" ] || \
	fail 'compiled rootfs has no BusyBox flock applet required by Passwall debounce'
[ -x "$ROOTFS_PASSWALL_NFTABLES" ] || \
	fail "真实 TARGET_DIR 中没有可执行的 Passwall nftables.sh：$ROOTFS_PASSWALL_NFTABLES"
[ -x "$ROOTFS_PASSWALL_IPTABLES" ] || \
	fail "真实 TARGET_DIR 中没有可执行的 Passwall iptables.sh：$ROOTFS_PASSWALL_IPTABLES"
[ -x "$ROOTFS_PASSWALL_APP" ] || \
	fail "真实 TARGET_DIR 中没有可执行的 Passwall app.sh：$ROOTFS_PASSWALL_APP"
ROOTFS_PASSWALL_NFTABLES_SHA=$(sha256sum "$ROOTFS_PASSWALL_NFTABLES" | awk '{print $1}')
ROOTFS_PASSWALL_IPTABLES_SHA=$(sha256sum "$ROOTFS_PASSWALL_IPTABLES" | awk '{print $1}')
ROOTFS_PASSWALL_APP_SHA=$(sha256sum "$ROOTFS_PASSWALL_APP" | awk '{print $1}')
ROOTFS_PASSWALL_IFUP_SHA=$(sha256sum "$ROOTFS_PASSWALL_IFUP" | awk '{print $1}')
[ "$ROOTFS_PASSWALL_IFUP_SHA" = "$PASSWALL_IFUP_SHA" ] || \
	fail 'compiled rootfs Passwall 98-passwall differs from the validated debounce payload'
[ "$ROOTFS_PASSWALL_NFTABLES_SHA" = "$PASSWALL_NFTABLES_SHA" ] || \
	fail '编译后 rootfs 中 Passwall nftables.sh 与已验证源码不同'
[ "$ROOTFS_PASSWALL_IPTABLES_SHA" = "$PASSWALL_IPTABLES_SHA" ] || \
	fail '编译后 rootfs 中 Passwall iptables.sh 与已验证源码不同'
[ "$ROOTFS_PASSWALL_APP_SHA" = "$PASSWALL_APP_SHA" ] || \
	fail '编译后 rootfs 中 Passwall app.sh 与已验证循环定时源码不同'
[ "$(grep -Fc 'is_socks_wrap' "$ROOTFS_PASSWALL_NFTABLES" || true)" -eq 0 ] && \
	[ "$(grep -Fc 'is_socks_wrap' "$ROOTFS_PASSWALL_IPTABLES" || true)" -eq 0 ] || \
	fail '编译后 rootfs 中 Passwall 防火墙脚本仍调用已删除的 is_socks_wrap'
printf '编译后 rootfs 检查通过：Passwall nftables.sh=%s iptables.sh=%s app.sh=%s，无is_socks_wrap残留\n' \
	"$ROOTFS_PASSWALL_NFTABLES_SHA" "$ROOTFS_PASSWALL_IPTABLES_SHA" \
	"$ROOTFS_PASSWALL_APP_SHA"

if [ "$CONFIG_CHANGED_DURING_BUILD" -ne 0 ]; then
	fail "源码更新已经成功，但编译过程修改了 .config；配置已恢复，本次固件不能判定成功"
fi

: > "$FRESH_IMAGES"
: > "$FRESH_MAIN_IMAGES"
: > "$FRESH_MANIFESTS"
: > "$ARTIFACT_SHA"
[ -d "$TARGET_OUTPUT_DIR" ] || \
	fail "源码更新已经成功，但没有生成当前目标目录：$TARGET_OUTPUT_DIR"

while IFS= read -r -d '' artifact; do
	[ -s "$artifact" ] || continue
	printf '%s\n' "$artifact" >> "$FRESH_IMAGES"
	sha256sum "$artifact" >> "$ARTIFACT_SHA"
	case "${artifact##*/}" in
		*sysupgrade*|*factory*|*combined*|*.img|*.img.gz|*.ubi)
			printf '%s\n' "$artifact" >> "$FRESH_MAIN_IMAGES"
			;;
	esac
done < <(find "$TARGET_OUTPUT_DIR" -maxdepth 1 -type f -newer "$BUILD_MARKER" \
	\( -name '*.bin' -o -name '*.img' -o -name '*.img.gz' \
	-o -name '*.itb' -o -name '*.ubi' \) \
	-print0 | sort -z)

[ -s "$FRESH_IMAGES" ] || \
	fail "源码更新已经成功，make -j1 返回 0，但当前目标没有本次新生成的固件镜像：$TARGET_OUTPUT_DIR"
[ -s "$FRESH_MAIN_IMAGES" ] || \
	fail "源码更新已经成功，但没有发现本次新生成的 sysupgrade/factory/img 主固件：$TARGET_OUTPUT_DIR"

TARGET_SHA256SUMS="$TARGET_OUTPUT_DIR/sha256sums"
[ -s "$TARGET_SHA256SUMS" ] && [ "$TARGET_SHA256SUMS" -nt "$BUILD_MARKER" ] || \
	fail "源码更新已经成功，但当前目标没有本次新生成的 sha256sums：$TARGET_SHA256SUMS"

set +e
(
	cd "$TARGET_OUTPUT_DIR"
	sha256sum -c sha256sums
) 2>&1 | tee "$HASH_VERIFY_LOG"
HASH_PIPESTATUS=("${PIPESTATUS[@]}")
HASH_RC=${HASH_PIPESTATUS[0]:-99}
HASH_TEE_RC=${HASH_PIPESTATUS[1]:-99}
set -e
[ "$HASH_TEE_RC" -eq 0 ] || \
	fail "无法完整写入固件哈希校验日志：$HASH_VERIFY_LOG"
[ "$HASH_RC" -eq 0 ] || \
	fail "源码更新已经成功，但固件目录 sha256sums 校验失败：$HASH_VERIFY_LOG"

while IFS= read -r -d '' manifest; do
	printf '%s\n' "$manifest" >> "$FRESH_MANIFESTS"
done < <(find "$TARGET_OUTPUT_DIR" -maxdepth 1 -type f -newer "$BUILD_MARKER" \
	-name '*.manifest' -print0 | sort -z)

verify_plugin_output() {
	local package_name=$1 config_symbol=$2 selection manifest found=0 package_file
	selection=$(sed -n "s/^${config_symbol}=//p" \
		"$BACKUP_DIR/config.for-build" | tail -n 1)
	case "$selection" in
		y)
			[ -s "$FRESH_MANIFESTS" ] || \
				fail "$package_name 配置为 y，但没有本次新生成的固件 manifest"
			while IFS= read -r manifest; do
				grep -Eq "^${package_name}[[:space:]]" "$manifest" && found=1
			done < "$FRESH_MANIFESTS"
			[ "$found" -eq 1 ] || \
				fail "$package_name 配置为 y，但新固件 manifest 中没有该软件包"
			printf '固件内置检查通过：%s=y\n' "$package_name"
			;;
		m)
			while IFS= read -r -d '' package_file; do
				found=1
				printf '本次新生成的软件包：%s\n' "$package_file"
			done < <(find "$ROOT/bin" -type f -newer "$BUILD_MARKER" \
				\( -name "${package_name}_*.ipk" -o \
				-name "${package_name}-*.apk" -o \
				-name "${package_name}_*.apk" \) -print0)
			[ "$found" -eq 1 ] || \
				fail "$package_name 配置为 m，但没有找到本次新生成的 IPK/APK"
			printf '模块编译检查通过：%s=m（只生成软件包，不内置固件）\n' \
				"$package_name"
			;;
		*)
			printf '提示：%s 未在当前 .config 中选择；源码已更新，但不会编入固件。\n' \
				"$package_name"
			;;
	esac
}

verify_plugin_output luci-app-openclash CONFIG_PACKAGE_luci-app-openclash
verify_plugin_output luci-app-passwall CONFIG_PACKAGE_luci-app-passwall
verify_plugin_output nvme-cli CONFIG_PACKAGE_nvme-cli

printf '本次新生成的固件镜像：\n'
cat "$ARTIFACT_SHA"

printf 'BUILD_SUCCEEDED %s\n' "$(date -Is)" > "$BACKUP_DIR/BUILD_SUCCEEDED"

section '全部完成'
printf 'FINAL: 更新成功，固件编译成功\n'
printf 'OpenClash=%s commit=%s\n' "$OPENCLASH_VERSION" "$OPENCLASH_COMMIT"
printf 'Passwall=%s-%s commit=%s\n' \
	"$PW_VERSION" "$PW_RELEASE" "$PASSWALL_LUCI_COMMIT"
printf 'Passwall api.lua upstream=%s packaged=%s compatibility=%s\n' \
	"$PASSWALL_API_UPSTREAM_SHA" "$PASSWALL_API_SHA" \
	"$PASSWALL_API_COMPAT_PATCH"
printf 'Passwall nftables.sh upstream=%s packaged=%s\n' \
	"$PASSWALL_NFTABLES_UPSTREAM_SHA" "$PASSWALL_NFTABLES_SHA"
printf 'Passwall iptables.sh upstream=%s packaged=%s\n' \
	"$PASSWALL_IPTABLES_UPSTREAM_SHA" "$PASSWALL_IPTABLES_SHA"
printf 'Passwall socks firewall compatibility=%s\n' \
	"$PASSWALL_SOCKS_COMPAT_PATCH"
printf 'Passwall app.sh upstream=%s packaged=%s compatibility=%s\n' \
	"$PASSWALL_APP_UPSTREAM_SHA" "$PASSWALL_APP_SHA" \
	"$PASSWALL_LOOP_SCHEDULE_COMPAT_PATCH"
printf 'Passwall 98-passwall upstream=%s packaged=%s compatibility=%s\n' \
	"$PASSWALL_IFUP_UPSTREAM_SHA" "$PASSWALL_IFUP_SHA" \
	"$PASSWALL_IFUP_DEBOUNCE_COMPAT_PATCH"
printf 'PasswallPackagesCommit=%s\n' "$PASSWALL_PACKAGES_COMMIT"
printf 'OpenClash菜单优先级=-5\n'
printf '离线rootfs保护=openclash,passwall\n'
printf '固件插件配置=openclash:y,passwall:y,kmod-nvme:y,libnvme:y,nvme-cli:y,luci-app-mount:disabled\n'
printf 'rootfs OpenClash控制器SHA256=%s\n' \
	"$ROOTFS_OPENCLASH_CONTROLLER_SHA"
printf 'rootfs Passwall api.lua SHA256=%s\n' \
	"$ROOTFS_PASSWALL_API_SHA"
printf 'rootfs Passwall nftables.sh SHA256=%s\n' \
	"$ROOTFS_PASSWALL_NFTABLES_SHA"
printf 'rootfs Passwall iptables.sh SHA256=%s\n' \
	"$ROOTFS_PASSWALL_IPTABLES_SHA"
printf 'rootfs Passwall app.sh SHA256=%s\n' \
	"$ROOTFS_PASSWALL_APP_SHA"
printf 'rootfs Passwall 98-passwall SHA256=%s\n' \
	"$ROOTFS_PASSWALL_IFUP_SHA"
printf '原配置SHA256=%s\n' "$CONFIG_BEFORE_SHA"
printf '编译配置SHA256=%s\n' "$CONFIG_BUILD_SHA"
printf '固件输出目录=%s\n' "$TARGET_OUTPUT_DIR"
printf '备份目录=%s\n' "$BACKUP_DIR"
printf '更新总日志=%s\n' "$LOG_FILE"
printf '固件编译日志=%s\n' "$BUILD_LOG"
printf '固件哈希校验日志=%s\n' "$HASH_VERIFY_LOG"
printf '主固件清单=%s\n' "$FRESH_MAIN_IMAGES"
printf '固件文件哈希=%s\n' "$ARTIFACT_SHA"
