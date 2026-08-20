#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

ROOT="$(pwd -P)"
EXPECTED_ROOT='/home/ht/237'
BACKUP_ROOT='/home/ht/237-backups'
APP='feeds/luci/applications/luci-app-opkg'
PKG_LINK='package/feeds/luci/luci-app-opkg'
PATCH_NAME='opkg-luci-background-update-5.4.patch'
PATCH_SHA='080b9fc2e00f9c83d93901404f8b4744026d401d2e7b6ced4563e54f995dbbb3'
PATCH_URL="https://raw.githubusercontent.com/ZJJCKA/237/5.4/$PATCH_NAME"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
PATCH_FILE=''
PATCH_TMP=''
BACKUP=''
ROLLBACK_ACTIVE=0
ROLLBACK_DONE=0
MODE="${1:---apply}"
RECOVERY_SAFETY=''
LAST_DISPLACED=''
DISPLACED_MANIFEST=''

OLD_MAKEFILE='3688ecf78ba42b21ea0b5fa1dce4be1c6f24511e'
OLD_JS='5d9a7496b1a03af1242a6d9669c1025a96231d85'
OLD_CALL='1234b70330aa65b29d91a3dc512a68b301142e2e'
OLD_ACL='d6531a58e44040e18092db6954dc3108f14b0d2c'

NEW_MAKEFILE='9c13b2d5a3b5356f453afca42515bef4c318ab8b'
NEW_JS='1329c35bb6c6c64a196f03d026d68f5700e6070b'
NEW_CALL='47e0886fa5fbf8edbeb3ce0e6d0833020005faef'
NEW_ACL='93602bf12e58903a11b04e90f203fda6437367dd'

cleanup()
{
	[ -z "$PATCH_TMP" ] || [ ! -e "$PATCH_TMP" ] || rm -f -- "$PATCH_TMP"
}

blob()
{
	git hash-object "$1"
}

check_fixed_count()
{
	local expected="$1" pattern="$2" file="$3" label="$4"
	local count='' rc=0

	if count="$(grep -Fc -- "$pattern" "$file")"; then
		rc=0
	else
		rc=$?
	fi

	if [ "$rc" -gt 1 ]; then
		echo "ERROR=${label}_GREP_FAILED:$rc" >&2
		return 1
	fi
	[ -n "$count" ] || count=0
	if [ "$count" -ne "$expected" ]; then
		echo "ERROR=${label}_COUNT:$count:EXPECTED:$expected" >&2
		return 1
	fi
}

check_no_extended_match()
{
	local pattern="$1" file="$2" label="$3" rc=0

	if grep -Eq -- "$pattern" "$file"; then
		echo "ERROR=${label}_UNEXPECTED_MATCH" >&2
		return 1
	else
		rc=$?
	fi
	if [ "$rc" -ne 1 ]; then
		echo "ERROR=${label}_GREP_FAILED:$rc" >&2
		return 1
	fi
}

check_no_fixed_match()
{
	local pattern="$1" file="$2" label="$3" rc=0

	if grep -Fq -- "$pattern" "$file"; then
		echo "ERROR=${label}_UNEXPECTED_MATCH" >&2
		return 1
	else
		rc=$?
	fi
	if [ "$rc" -ne 1 ]; then
		echo "ERROR=${label}_GREP_FAILED:$rc" >&2
		return 1
	fi
}

path_has_no_symlink_component()
{
	local path="$1" component current=''
	local -a components

	[[ "$path" = /* ]] || return 1
	IFS='/' read -r -a components <<<"$path"
	for component in "${components[@]}"; do
		[ -n "$component" ] || continue
		current="$current/$component"
		[ ! -L "$current" ] || return 1
	done
}

audit_old_source()
{
	local base="$1"

	path_has_no_symlink_component "$base" || return 1
	[ -d "$base" ] && [ ! -L "$base" ] || return 1
	path_has_no_symlink_component "$base/Makefile" || return 1
	path_has_no_symlink_component "$base/htdocs/luci-static/resources/view/opkg.js" || return 1
	path_has_no_symlink_component "$base/root/usr/libexec/opkg-call" || return 1
	path_has_no_symlink_component "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json" || return 1
	[ -f "$base/Makefile" ] && [ ! -L "$base/Makefile" ] || return 1
	[ -f "$base/htdocs/luci-static/resources/view/opkg.js" ] &&
		[ ! -L "$base/htdocs/luci-static/resources/view/opkg.js" ] || return 1
	[ -f "$base/root/usr/libexec/opkg-call" ] &&
		[ ! -L "$base/root/usr/libexec/opkg-call" ] || return 1
	[ -f "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json" ] &&
		[ ! -L "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json" ] || return 1
	[ "$(blob "$base/Makefile")" = "$OLD_MAKEFILE" ] || return 1
	[ "$(blob "$base/htdocs/luci-static/resources/view/opkg.js")" = "$OLD_JS" ] || return 1
	[ "$(blob "$base/root/usr/libexec/opkg-call")" = "$OLD_CALL" ] || return 1
	[ "$(blob "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json")" = "$OLD_ACL" ]
}

audit_new_source()
{
	local base="$1"

	path_has_no_symlink_component "$base" || return 1
	[ -d "$base" ] && [ ! -L "$base" ] || return 1
	path_has_no_symlink_component "$base/Makefile" || return 1
	path_has_no_symlink_component "$base/htdocs/luci-static/resources/view/opkg.js" || return 1
	path_has_no_symlink_component "$base/root/usr/libexec/opkg-call" || return 1
	path_has_no_symlink_component "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json" || return 1
	[ -f "$base/Makefile" ] && [ ! -L "$base/Makefile" ] || return 1
	[ -f "$base/htdocs/luci-static/resources/view/opkg.js" ] &&
		[ ! -L "$base/htdocs/luci-static/resources/view/opkg.js" ] || return 1
	[ -f "$base/root/usr/libexec/opkg-call" ] &&
		[ ! -L "$base/root/usr/libexec/opkg-call" ] || return 1
	[ -f "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json" ] &&
		[ ! -L "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json" ] || return 1
	[ "$(blob "$base/Makefile")" = "$NEW_MAKEFILE" ] || return 1
	[ "$(blob "$base/htdocs/luci-static/resources/view/opkg.js")" = "$NEW_JS" ] || return 1
	[ "$(blob "$base/root/usr/libexec/opkg-call")" = "$NEW_CALL" ] || return 1
	[ "$(blob "$base/root/usr/share/rpcd/acl.d/luci-app-opkg.json")" = "$NEW_ACL" ]
}

remove_restore_stage()
{
	local stage="$1"

	case "$stage" in
		"$ROOT/feeds/luci/applications"/.luci-app-opkg.restore.*)
			[ ! -e "$stage" ] || rm -rf -- "$stage"
		;;
	esac
}

replace_source_from_backup()
{
	local source="$1"
	local target="$ROOT/$APP"
	local parent stage displaced preserve_root preserve_path

	parent="$(dirname "$target")"
	stage="$(mktemp -d "$parent/.luci-app-opkg.restore.XXXXXX")"
	displaced="$parent/.luci-app-opkg.interrupted.$$"

	if ! cp -a -- "$source/." "$stage/"; then
		remove_restore_stage "$stage"
		echo 'ERROR=RECOVERY_STAGED_SOURCE_COPY_FAILED'
		return 1
	fi
	audit_old_source "$stage" || {
		remove_restore_stage "$stage"
		echo 'ERROR=RECOVERY_STAGED_SOURCE_HASH_MISMATCH'
		return 1
	}

	[ ! -L "$target" ] || {
		remove_restore_stage "$stage"
		echo "ERROR=UNSAFE_SYMLINK_SOURCE:$APP"
		return 1
	}
	[ ! -e "$displaced" ] || {
		remove_restore_stage "$stage"
		echo "ERROR=RECOVERY_DISPLACED_PATH_EXISTS:$displaced"
		return 1
	}

	# Do not allow a second Ctrl-C to leave the feed source half restored.
	trap '' INT TERM HUP
	if [ -e "$target" ] && ! mv -- "$target" "$displaced"; then
		remove_restore_stage "$stage"
		echo 'ERROR=RECOVERY_CURRENT_SOURCE_RENAME_FAILED'
		return 1
	fi

	if ! mv -- "$stage" "$target"; then
		[ ! -e "$displaced" ] || mv -- "$displaced" "$target"
		remove_restore_stage "$stage"
		echo 'ERROR=RECOVERY_SOURCE_RENAME_FAILED'
		return 1
	fi

	if ! audit_old_source "$target"; then
		rm -rf -- "$target"
		[ ! -e "$displaced" ] || mv -- "$displaced" "$target"
		echo 'ERROR=RECOVERY_INSTALLED_SOURCE_HASH_MISMATCH'
		return 1
	fi

	if [ -e "$displaced" ]; then
		if [ -n "$RECOVERY_SAFETY" ]; then
			preserve_root="$RECOVERY_SAFETY"
			preserve_path="$preserve_root/displaced-live-source"
		else
			preserve_root="$BACKUP"
			preserve_path="$preserve_root/rejected-source"
		fi
		[ -d "$preserve_root" ] && [ ! -e "$preserve_path" ] || {
			echo 'ERROR=RECOVERY_DISPLACED_PRESERVE_PATH_UNSAFE'
			return 1
		}
		mv -- "$displaced" "$preserve_path" || {
			echo 'ERROR=RECOVERY_DISPLACED_SOURCE_PRESERVE_FAILED'
			return 1
		}
		LAST_DISPLACED="$preserve_path"
		if [ -n "$RECOVERY_SAFETY" ]; then
			DISPLACED_MANIFEST="$RECOVERY_SAFETY/SHA256SUMS"
			write_verified_manifest "$RECOVERY_SAFETY" "$DISPLACED_MANIFEST" || {
				echo 'ERROR=RECOVERY_SAFETY_MANIFEST_REFRESH_FAILED'
				return 1
			}
		else
			DISPLACED_MANIFEST="$BACKUP/rejected-source.SHA256SUMS"
			write_verified_manifest "$preserve_path" "$DISPLACED_MANIFEST" || {
				echo 'ERROR=ROLLBACK_REJECTED_SOURCE_MANIFEST_FAILED'
				return 1
			}
		fi
	fi

	if find "$parent" -mindepth 1 -maxdepth 1 \
		\( -name '.luci-app-opkg.restore.*' -o -name '.luci-app-opkg.interrupted.*' \) \
		-print -quit | grep -q .; then
		echo 'ERROR=RECOVERY_TEMP_SOURCE_LEFT_IN_FEED_TREE'
		return 1
	fi
}

recover_latest()
{
	local candidate latest='' clean_rc=0

	[ -d "$BACKUP_ROOT" ] || {
		echo "ERROR=OPKG_BACKUP_ROOT_MISSING:$BACKUP_ROOT"
		return 1
	}

	while IFS= read -r -d '' candidate; do
		if audit_old_source "$candidate/source" &&
		   path_has_no_symlink_component "$candidate/dot-config" &&
		   [ -f "$candidate/dot-config" ] && [ ! -L "$candidate/dot-config" ]; then
			latest="$candidate"
		fi
	done < <(
		find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
			-name 'luci-opkg-background-update-before-*' -print0 | sort -z
	)

	[ -n "$latest" ] || {
		echo 'ERROR=NO_VALID_LUCI_OPKG_BACKUP_FOUND'
		return 1
	}

	if [ -e "$ROOT/$PKG_LINK" ] && [ ! -L "$ROOT/$PKG_LINK" ]; then
		echo "ERROR=UNSAFE_FEED_PACKAGE_LINK:$PKG_LINK"
		return 1
	fi
	if [ -L "$ROOT/$PKG_LINK" ] &&
	   [ "$(readlink "$ROOT/$PKG_LINK")" != '../../../feeds/luci/applications/luci-app-opkg' ]; then
		echo "ERROR=UNEXPECTED_FEED_PACKAGE_LINK:$PKG_LINK"
		return 1
	fi

	BACKUP="$latest"
	create_recovery_safety_backup
	echo "RECOVERY_SAFETY_BACKUP=$RECOVERY_SAFETY"
	# From this point onward, do not allow a second Ctrl-C to split recovery.
	trap '' INT TERM HUP
	collect_preexisting_feed_artifacts
	if audit_old_source "$ROOT/$APP"; then
		echo 'RECOVERY_SOURCE_STATE=ALREADY_ORIGINAL'
	else
		replace_source_from_backup "$BACKUP/source"
	fi

	if [ ! -e "$ROOT/$PKG_LINK" ] && [ ! -L "$ROOT/$PKG_LINK" ]; then
		ln -s '../../../feeds/luci/applications/luci-app-opkg' "$ROOT/$PKG_LINK"
	fi

	[ "$(readlink -f "$ROOT/$PKG_LINK")" = "$(readlink -f "$ROOT/$APP")" ] || {
		echo "ERROR=RECOVERED_FEED_PACKAGE_LINK_TARGET_MISMATCH:$PKG_LINK"
		return 1
	}

	[ -f "$BACKUP/dot-config" ] && [ ! -L "$BACKUP/dot-config" ] || {
		echo 'ERROR=RECOVERY_BACKUP_DOT_CONFIG_INVALID'
		return 1
	}
	cp -p -- "$BACKUP/dot-config" "$ROOT/.config"
	cmp -s -- "$BACKUP/dot-config" "$ROOT/.config" || {
		echo 'ERROR=RECOVERED_DOT_CONFIG_MISMATCH'
		return 1
	}

	make -j1 package/feeds/luci/luci-app-opkg/clean V=s >/dev/null 2>&1 || clean_rc=$?
	restore_ipks
	verify_restored_ipks || {
		echo 'ERROR=RECOVERED_IPK_SET_MISMATCH'
		return 1
	}
	audit_old_source "$ROOT/$APP"
	if [ "$clean_rc" -ne 0 ]; then
		echo "ERROR=RECOVERY_PACKAGE_CLEAN_FAILED:$clean_rc"
		return 1
	fi

	echo "RECOVERED_BACKUP=$BACKUP"
	echo "RECOVERY_DISPLACED_SOURCE=${LAST_DISPLACED:-NONE}"
	echo "RECOVERY_SAFETY_MANIFEST=$RECOVERY_SAFETY/SHA256SUMS"
	sha256sum "$RECOVERY_SAFETY/SHA256SUMS"
	echo 'LUCI_OPKG_INTERRUPTED_ROLLBACK_RECOVERY=PASS'
	echo 'RESULT=RETURN_FULL_OUTPUT'
}

backup_ipks()
{
	local destination="${1:-$BACKUP}"
	local file rel

	while IFS= read -r -d '' file; do
		rel="${file#"$ROOT"/}"
		case "$rel" in
			bin/packages/*/luci-app-opkg_*.ipk) ;;
			*) return 1 ;;
		esac
		[ -f "$file" ] && [ ! -L "$file" ] &&
			path_has_no_symlink_component "$file" || return 1
		mkdir -p "$destination/ipks/$(dirname "$rel")"
		cp -p -- "$file" "$destination/ipks/$rel"
		cmp -s -- "$file" "$destination/ipks/$rel" || return 1
	done < <(find "$ROOT/bin/packages" \( -type f -o -type l \) -name 'luci-app-opkg_*.ipk' -print0 2>/dev/null || true)
}

remove_live_ipks()
{
	local file

	while IFS= read -r -d '' file; do
		case "$file" in
			"$ROOT"/bin/packages/*/luci-app-opkg_*.ipk) rm -f -- "$file" ;;
			*) return 1 ;;
		esac
	done < <(find "$ROOT/bin/packages" \( -type f -o -type l \) -name 'luci-app-opkg_*.ipk' -print0 2>/dev/null || true)
}

restore_ipks()
{
	local file rel

	remove_live_ipks

	[ -d "$BACKUP/ipks" ] || return 0

	while IFS= read -r -d '' file; do
		rel="${file#"$BACKUP/ipks"/}"
		case "$rel" in
			bin/packages/*/luci-app-opkg_*.ipk) ;;
			*) return 1 ;;
		esac
		[ -f "$file" ] && [ ! -L "$file" ] &&
			path_has_no_symlink_component "$file" || return 1
		mkdir -p "$ROOT/$(dirname "$rel")"
		cp -p -- "$file" "$ROOT/$rel"
	done < <(find "$BACKUP/ipks" \( -type f -o -type l \) -name 'luci-app-opkg_*.ipk' -print0)
}

verify_restored_ipks()
{
	local file rel backup_count=0 live_count=0

	if [ -d "$BACKUP/ipks" ]; then
		while IFS= read -r -d '' file; do
			rel="${file#"$BACKUP/ipks"/}"
			case "$rel" in
				bin/packages/*/luci-app-opkg_*.ipk) ;;
				*) return 1 ;;
			esac
			[ -f "$file" ] && [ ! -L "$file" ] &&
				path_has_no_symlink_component "$file" || return 1
			[ -f "$ROOT/$rel" ] && [ ! -L "$ROOT/$rel" ] &&
				cmp -s -- "$file" "$ROOT/$rel" || return 1
			backup_count=$((backup_count + 1))
		done < <(find "$BACKUP/ipks" \( -type f -o -type l \) -name 'luci-app-opkg_*.ipk' -print0)
	fi

	while IFS= read -r -d '' file; do
		[ -f "$file" ] && [ ! -L "$file" ] || return 1
		live_count=$((live_count + 1))
	done < <(find "$ROOT/bin/packages" \( -type f -o -type l \) -name 'luci-app-opkg_*.ipk' -print0 2>/dev/null || true)

	[ "$live_count" -eq "$backup_count" ]
}

verify_built_ipk()
{
	local ipk="$1" proof ok=0

	[ -f "$ipk" ] && [ ! -L "$ipk" ] || return 1
	proof="$(mktemp -d /tmp/luci-opkg-ipk-proof.XXXXXX)"

	if (
		set -e
		mkdir "$proof/outer" "$proof/control" || exit 1
		tar -xf "$ipk" -C "$proof/outer" || exit 1
		[ "$(cat "$proof/outer/debian-binary")" = '2.0' ] || exit 1
		tar -xf "$proof/outer/control.tar.gz" -C "$proof/control" || exit 1
		grep -Fxq 'Package: luci-app-opkg' "$proof/control/control" || exit 1
		grep -Fxq 'Version: git-25.294.31582-8ceae5a-bgupdate1-1' "$proof/control/control" || exit 1
		grep -Fxq 'Architecture: all' "$proof/control/control" || exit 1
	); then
		ok=1
	fi

	case "$proof" in
		/tmp/luci-opkg-ipk-proof.*) rm -rf -- "$proof" ;;
	esac
	[ "$ok" -eq 1 ]
}

remove_incomplete_safety_backup()
{
	case "$RECOVERY_SAFETY" in
		"$BACKUP_ROOT"/luci-opkg-interrupted-state-before-recovery-*)
			[ ! -e "$RECOVERY_SAFETY" ] || rm -rf -- "$RECOVERY_SAFETY"
		;;
	esac
}

write_verified_manifest()
{
	local tree="$1" manifest="$2" file

	[ -d "$tree" ] && [ ! -L "$tree" ] || return 1
	: >"$manifest" || return 1
	while IFS= read -r -d '' file; do
		sha256sum "$file" >>"$manifest" || return 1
	done < <(find "$tree" -type f ! -path "$manifest" -print0 | sort -z)
	sha256sum -c "$manifest" >/dev/null
}

collect_preexisting_feed_artifacts()
{
	local parent destination entry base count=0
	local -a artifacts=()

	parent="$ROOT/feeds/luci/applications"
	destination="$RECOVERY_SAFETY/orphaned-feed-state"
	if ! path_has_no_symlink_component "$parent" ||
	   [ ! -d "$parent" ] || [ -L "$parent" ]; then
		echo 'ERROR=UNSAFE_LUCI_APPLICATIONS_DIRECTORY'
		return 1
	fi
	mapfile -d '' -t artifacts < <(
		find "$parent" -mindepth 1 -maxdepth 1 \
			\( -name '.luci-app-opkg.restore.*' -o -name '.luci-app-opkg.interrupted.*' \) \
			-print0 | sort -z
	)

	if [ "${#artifacts[@]}" -eq 0 ]; then
		echo 'RECOVERY_ORPHANED_FEED_STATE_COUNT=0'
		return 0
	fi

	[ ! -e "$destination" ] || {
		echo "ERROR=RECOVERY_ORPHAN_DESTINATION_EXISTS:$destination"
		return 1
	}

	for entry in "${artifacts[@]}"; do
		case "$entry" in
			"$parent"/.luci-app-opkg.restore.*|"$parent"/.luci-app-opkg.interrupted.*) ;;
			*) echo "ERROR=UNSAFE_RECOVERY_ORPHAN_PATH:$entry"; return 1 ;;
		esac
		if [ ! -d "$entry" ] || [ -L "$entry" ]; then
			echo "ERROR=UNSAFE_RECOVERY_ORPHAN_TYPE:$entry"
			return 1
		fi
		base="${entry##*/}"
		[ ! -e "$destination/$base" ] || {
			echo "ERROR=RECOVERY_ORPHAN_NAME_COLLISION:$base"
			return 1
		}
	done

	mkdir "$destination" || return 1
	for entry in "${artifacts[@]}"; do
		base="${entry##*/}"
		if ! mv -- "$entry" "$destination/$base"; then
			write_verified_manifest "$RECOVERY_SAFETY" "$RECOVERY_SAFETY/SHA256SUMS" || true
			echo "ERROR=RECOVERY_ORPHAN_MOVE_FAILED:$entry"
			return 1
		fi
		count=$((count + 1))
	done

	if find "$parent" -mindepth 1 -maxdepth 1 \
		\( -name '.luci-app-opkg.restore.*' -o -name '.luci-app-opkg.interrupted.*' \) \
		-print -quit | grep -q .; then
		echo 'ERROR=RECOVERY_ORPHAN_LEFT_IN_FEED_TREE'
		return 1
	fi
	printf 'ORPHANED_FEED_STATE_COUNT=%s\n' "$count" >>"$RECOVERY_SAFETY/RECOVERY_INFO"
	write_verified_manifest "$RECOVERY_SAFETY" "$RECOVERY_SAFETY/SHA256SUMS" || {
		echo 'ERROR=RECOVERY_ORPHAN_MANIFEST_REFRESH_FAILED'
		return 1
	}
	echo "RECOVERY_ORPHANED_FEED_STATE_COUNT=$count"
	echo "RECOVERY_ORPHANED_FEED_STATE=$destination"
}

create_recovery_safety_backup()
{
	local stamp target manifest

	stamp="$(date +%Y%m%d-%H%M%S)-$$"
	RECOVERY_SAFETY="$BACKUP_ROOT/luci-opkg-interrupted-state-before-recovery-$stamp"
	target="$ROOT/$APP"

	path_has_no_symlink_component "$BACKUP_ROOT" || {
		echo "ERROR=UNSAFE_OPKG_BACKUP_ROOT:$BACKUP_ROOT"
		return 1
	}
	[ ! -L "$target" ] || {
		echo "ERROR=UNSAFE_CURRENT_SOURCE_SYMLINK:$APP"
		return 1
	}
	[ ! -e "$target" ] || [ -d "$target" ] || {
		echo "ERROR=UNSAFE_CURRENT_SOURCE_TYPE:$APP"
		return 1
	}
	[ ! -e "$ROOT/.config" ] || {
		[ -f "$ROOT/.config" ] && [ ! -L "$ROOT/.config" ]
	} || {
		echo 'ERROR=UNSAFE_CURRENT_DOT_CONFIG'
		return 1
	}
	[ ! -e "$RECOVERY_SAFETY" ] || return 1
	mkdir "$RECOVERY_SAFETY" || return 1

	if [ -d "$target" ]; then
		if ! cp -a -- "$target" "$RECOVERY_SAFETY/source" ||
		   ! diff -qr -- "$target" "$RECOVERY_SAFETY/source" >/dev/null; then
			remove_incomplete_safety_backup
			echo 'ERROR=RECOVERY_SAFETY_SOURCE_COPY_FAILED'
			return 1
		fi
	else
		printf '%s\n' 'source was missing before recovery' >"$RECOVERY_SAFETY/SOURCE_MISSING" || {
			remove_incomplete_safety_backup
			return 1
		}
	fi

	if [ -f "$ROOT/.config" ]; then
		cp -p -- "$ROOT/.config" "$RECOVERY_SAFETY/dot-config" &&
			cmp -s -- "$ROOT/.config" "$RECOVERY_SAFETY/dot-config" || {
				remove_incomplete_safety_backup
				echo 'ERROR=RECOVERY_SAFETY_DOT_CONFIG_COPY_FAILED'
				return 1
			}
	fi

	backup_ipks "$RECOVERY_SAFETY" || {
		remove_incomplete_safety_backup
		echo 'ERROR=RECOVERY_SAFETY_IPK_COPY_FAILED'
		return 1
	}
	printf 'SOURCE_PATH=%s\n' "$target" >"$RECOVERY_SAFETY/RECOVERY_INFO" || {
		remove_incomplete_safety_backup
		return 1
	}

	manifest="$RECOVERY_SAFETY/SHA256SUMS"
	write_verified_manifest "$RECOVERY_SAFETY" "$manifest" || {
		remove_incomplete_safety_backup
		echo 'ERROR=RECOVERY_SAFETY_MANIFEST_VERIFY_FAILED'
		return 1
	}
}

rollback()
{
	local rc="${1:-$?}"
	local rollback_ok=1
	local rollback_marker=''
	trap - ERR
	trap '' INT TERM HUP
	set +e

	# ERR is inherited by command substitutions under set -E. Keep a future
	# subshell failure from contaminating captured stdout or rolling back twice.
	if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
		exec 1>&2
	fi
	if [ "$ROLLBACK_ACTIVE" -eq 1 ] || [ "$ROLLBACK_DONE" -eq 1 ]; then
		exit "$rc"
	fi
	ROLLBACK_ACTIVE=1
	[ -z "$BACKUP" ] || rollback_marker="$BACKUP/AUTO_ROLLBACK_COMPLETE"

	if [ -n "$rollback_marker" ] && [ -f "$rollback_marker" ] && [ ! -L "$rollback_marker" ] &&
	   audit_old_source "$ROOT/$APP" &&
	   { [ ! -f "$BACKUP/dot-config" ] || cmp -s -- "$BACKUP/dot-config" "$ROOT/.config"; } &&
	   verify_restored_ipks; then
		ROLLBACK_DONE=1
		ROLLBACK_ACTIVE=0
		exit "$rc"
	fi

	if [ -n "$BACKUP" ] && [ -d "$BACKUP/source" ]; then
		echo '===== AUTO ROLLBACK ====='
		if ! audit_old_source "$ROOT/$APP"; then
			replace_source_from_backup "$BACKUP/source" || rollback_ok=0
		fi

		if [ -f "$BACKUP/dot-config" ]; then
			cp -p -- "$BACKUP/dot-config" "$ROOT/.config" || rollback_ok=0
			cmp -s -- "$BACKUP/dot-config" "$ROOT/.config" || rollback_ok=0
		fi
		make -j1 package/feeds/luci/luci-app-opkg/clean V=s >/dev/null 2>&1 || rollback_ok=0
		restore_ipks || rollback_ok=0
		verify_restored_ipks || rollback_ok=0
		echo "ROLLBACK_BACKUP=$BACKUP"
		echo "ROLLBACK_REJECTED_SOURCE=${LAST_DISPLACED:-NONE}"
		[ -z "$DISPLACED_MANIFEST" ] || sha256sum "$DISPLACED_MANIFEST"
		if [ "$rollback_ok" -eq 1 ] && audit_old_source "$ROOT/$APP" &&
		   printf 'AUTO_ROLLBACK_COMPLETE=1\n' >"$rollback_marker"; then
			echo 'LUCI_OPKG_BACKGROUND_UPDATE_ROLLBACK=PASS'
		else
			echo 'LUCI_OPKG_BACKGROUND_UPDATE_ROLLBACK=FAIL'
		fi
	fi

	ROLLBACK_DONE=1
	ROLLBACK_ACTIVE=0
	exit "$rc"
}

trap cleanup EXIT

[ "$ROOT" = "$EXPECTED_ROOT" ] || {
	echo "ERROR=WRONG_BUILD_ROOT:$ROOT"
	exit 1
}

for command_name in cat chmod cmp cp curl date diff dirname find flock git grep ln ls make mkdir mktemp mv patch python3 readlink rm sha256sum sh sort tar tee; do
	command -v "$command_name" >/dev/null 2>&1 || {
		echo "ERROR=MISSING_COMMAND:$command_name"
		exit 1
	}
done

exec 7>/tmp/luci-opkg-background-update-source.lock
flock -n 7 || {
	echo 'ERROR=ANOTHER_LUCI_OPKG_FIX_IS_RUNNING'
	exit 1
}

case "$MODE" in
	--apply)
	;;
	--recover-latest)
		recover_latest
		exit 0
	;;
	*)
		echo "Usage: $0 [--apply|--recover-latest]" >&2
		exit 2
	;;
esac

[ -d "$APP" ] && [ ! -L "$APP" ] || {
	echo "ERROR=MISSING_OR_UNSAFE_SOURCE:$APP"
	exit 1
}

[ -L "$PKG_LINK" ] || {
	echo "ERROR=MISSING_FEED_PACKAGE_LINK:$PKG_LINK"
	exit 1
}

[ "$(readlink -f "$PKG_LINK")" = "$(readlink -f "$APP")" ] || {
	echo "ERROR=FEED_PACKAGE_LINK_TARGET_MISMATCH:$PKG_LINK"
	exit 1
}

[ -f .config ] && [ ! -L .config ] || {
	echo 'ERROR=MISSING_OR_UNSAFE_DOT_CONFIG'
	exit 1
}

grep -Fxq 'CONFIG_PACKAGE_luci-app-opkg=y' .config || {
	echo 'ERROR=LUCI_APP_OPKG_NOT_SELECTED'
	exit 1
}

grep -Fxq 'CONFIG_PACKAGE_cgi-io=y' .config || {
	echo 'ERROR=CGI_IO_NOT_SELECTED'
	exit 1
}

grep -Fxq 'CONFIG_BUSYBOX_CONFIG_FLOCK=y' .config || {
	echo 'ERROR=BUSYBOX_FLOCK_NOT_SELECTED'
	exit 1
}

if [ -e "$ROOT/$PATCH_NAME" ] || [ -L "$ROOT/$PATCH_NAME" ]; then
	path_has_no_symlink_component "$ROOT/$PATCH_NAME" &&
		[ -f "$ROOT/$PATCH_NAME" ] && [ ! -L "$ROOT/$PATCH_NAME" ] || {
		echo "ERROR=UNSAFE_LOCAL_PATCH:$ROOT/$PATCH_NAME"
		exit 1
	}
	PATCH_FILE="$ROOT/$PATCH_NAME"
elif [ -e "$SCRIPT_DIR/$PATCH_NAME" ] || [ -L "$SCRIPT_DIR/$PATCH_NAME" ]; then
	path_has_no_symlink_component "$SCRIPT_DIR/$PATCH_NAME" &&
		[ -f "$SCRIPT_DIR/$PATCH_NAME" ] && [ ! -L "$SCRIPT_DIR/$PATCH_NAME" ] || {
		echo "ERROR=UNSAFE_SCRIPT_PATCH:$SCRIPT_DIR/$PATCH_NAME"
		exit 1
	}
	PATCH_FILE="$SCRIPT_DIR/$PATCH_NAME"
else
	PATCH_TMP="$(mktemp /tmp/opkg-luci-background-update-5.4.XXXXXX.patch)"
	curl -fL --retry 3 --connect-timeout 20 -o "$PATCH_TMP" "$PATCH_URL"
	PATCH_FILE="$PATCH_TMP"
fi

printf '%s  %s\n' "$PATCH_SHA" "$PATCH_FILE" | sha256sum -c -
echo "PATCH_SOURCE=$PATCH_FILE"

MAKEFILE="$APP/Makefile"
JS="$APP/htdocs/luci-static/resources/view/opkg.js"
CALL="$APP/root/usr/libexec/opkg-call"
ACL="$APP/root/usr/share/rpcd/acl.d/luci-app-opkg.json"

CURRENT_MAKEFILE="$(blob "$MAKEFILE")"
CURRENT_JS="$(blob "$JS")"
CURRENT_CALL="$(blob "$CALL")"
CURRENT_ACL="$(blob "$ACL")"

if [ "$CURRENT_MAKEFILE" = "$NEW_MAKEFILE" ] &&
   [ "$CURRENT_JS" = "$NEW_JS" ] &&
   [ "$CURRENT_CALL" = "$NEW_CALL" ] &&
   [ "$CURRENT_ACL" = "$NEW_ACL" ]; then
	audit_new_source "$ROOT/$APP" || {
		echo 'ERROR=UNSAFE_PATCHED_LUCI_APP_OPKG_SOURCE_LAYOUT'
		exit 1
	}
	echo 'SOURCE_STATE=ALREADY_PATCHED'
	mapfile -d '' -t EXISTING_IPKS < <(
		find "$ROOT/bin/packages" \( -type f -o -type l \) \
			-name 'luci-app-opkg_*.ipk' -print0 2>/dev/null
	)
	if [ "${#EXISTING_IPKS[@]}" -eq 1 ] && verify_built_ipk "${EXISTING_IPKS[0]}"; then
		sh -n "$CALL"
		ls -lh "${EXISTING_IPKS[0]}"
		sha256sum "${EXISTING_IPKS[0]}"
		echo 'LUCI_OPKG_SOURCE_BACKUP=EXISTING_PATCH'
		echo 'LUCI_OPKG_BUILD_LOG=NOT_REBUILT'
		echo 'LUCI_OPKG_BACKGROUND_UPDATE_5_4=PASS'
		echo 'RESULT=RETURN_FULL_OUTPUT'
		exit 0
	fi
	echo 'ERROR=PATCHED_SOURCE_WITHOUT_ONE_VALID_IPK'
	echo 'ACTION=RUN_THIS_SCRIPT_WITH_--recover-latest_FIRST'
	exit 1
elif [ "$CURRENT_MAKEFILE" = "$OLD_MAKEFILE" ] &&
     [ "$CURRENT_JS" = "$OLD_JS" ] &&
     [ "$CURRENT_CALL" = "$OLD_CALL" ] &&
     [ "$CURRENT_ACL" = "$OLD_ACL" ]; then
	audit_old_source "$ROOT/$APP" || {
		echo 'ERROR=UNSAFE_ORIGINAL_LUCI_APP_OPKG_SOURCE_LAYOUT'
		exit 1
	}
	STAMP="$(date +%Y%m%d-%H%M%S)-$$"
	BACKUP="/home/ht/237-backups/luci-opkg-background-update-before-$STAMP"
	mkdir -p "$BACKUP"
	cp -a -- "$APP" "$BACKUP/source"
	audit_old_source "$BACKUP/source" || {
		echo 'ERROR=LUCI_OPKG_SOURCE_BACKUP_VERIFY_FAILED'
		exit 1
	}
	cp -p -- .config "$BACKUP/dot-config"
	cmp -s -- .config "$BACKUP/dot-config" || {
		echo 'ERROR=LUCI_OPKG_DOT_CONFIG_BACKUP_VERIFY_FAILED'
		exit 1
	}
	backup_ipks
	trap rollback ERR
	trap 'rollback 130' INT
	trap 'rollback 143' TERM HUP

	patch --dry-run -d "$APP" -p1 <"$PATCH_FILE"
	patch -d "$APP" -p1 <"$PATCH_FILE"
	chmod 0755 "$CALL"
	echo 'SOURCE_STATE=PATCHED_NOW'
else
	echo 'ERROR=LUCI_APP_OPKG_SOURCE_DRIFT'
	echo "CURRENT_MAKEFILE_BLOB=$CURRENT_MAKEFILE"
	echo "CURRENT_JS_BLOB=$CURRENT_JS"
	echo "CURRENT_CALL_BLOB=$CURRENT_CALL"
	echo "CURRENT_ACL_BLOB=$CURRENT_ACL"
	exit 1
fi

[ "$(blob "$MAKEFILE")" = "$NEW_MAKEFILE" ]
[ "$(blob "$JS")" = "$NEW_JS" ]
[ "$(blob "$CALL")" = "$NEW_CALL" ]
[ "$(blob "$ACL")" = "$NEW_ACL" ]

chmod 0755 "$CALL"
sh -n "$CALL"
python3 -m json.tool "$ACL" >/dev/null

VERIFY_OK=1
check_fixed_count 1 "[ 'update-start' ]" "$JS" 'UPDATE_START' || VERIFY_OK=0
check_fixed_count 1 "[ 'update-status' ]" "$JS" 'UPDATE_STATUS' || VERIFY_OK=0
check_fixed_count 1 "document.addEventListener('visibilitychange'" "$JS" 'VISIBILITY_CHANGE' || VERIFY_OK=0
check_fixed_count 1 "window.addEventListener('pagehide'" "$JS" 'PAGEHIDE' || VERIFY_OK=0
check_fixed_count 2 'if flock -x 8; then' "$CALL" 'FD8_FLOCK' || VERIFY_OK=0
check_fixed_count 1 'flock -x 9' "$CALL" 'FD9_FLOCK' || VERIFY_OK=0
check_fixed_count 1 'exec 9>&-' "$CALL" 'FD9_CLOSE' || VERIFY_OK=0
check_fixed_count 1 'run_update_worker 8>/tmp/opkg.lock' "$CALL" 'WORKER_FD8' || VERIFY_OK=0
check_fixed_count 1 ') 8>/tmp/opkg.lock' "$CALL" 'ACTION_FD8' || VERIFY_OK=0
check_no_extended_match '(^|[^0-9])(200|201)>' "$CALL" 'HIGH_FD' || VERIFY_OK=0
check_no_fixed_match 'rm -f /tmp/opkg.lock' "$CALL" 'OLD_LOCK_REMOVAL' || VERIFY_OK=0
[ "$VERIFY_OK" -eq 1 ]

BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_LOG="/tmp/luci-opkg-background-update-5.4-$BUILD_STAMP.log"

make -j1 package/feeds/luci/luci-app-opkg/clean V=s 2>&1 | tee "$BUILD_LOG"
remove_live_ipks
make -j1 package/feeds/luci/luci-app-opkg/compile V=s 2>&1 | tee -a "$BUILD_LOG"

mapfile -d '' -t NEW_IPKS < <(
	find "$ROOT/bin/packages" \( -type f -o -type l \) \
		-name 'luci-app-opkg_*.ipk' -print0 2>/dev/null
)

[ "${#NEW_IPKS[@]}" -eq 1 ] || {
	echo "ERROR=PATCHED_LUCI_APP_OPKG_IPK_COUNT:${#NEW_IPKS[@]}"
	false
}

for ipk in "${NEW_IPKS[@]}"; do
	case "$ipk" in
		"$ROOT"/bin/packages/*/luci-app-opkg_*bgupdate1-1_all.ipk) ;;
		*) echo "ERROR=UNEXPECTED_PATCHED_LUCI_APP_OPKG_IPK:$ipk"; false ;;
	esac
	verify_built_ipk "$ipk" || {
		echo "ERROR=PATCHED_LUCI_APP_OPKG_IPK_INVALID:$ipk"
		false
	}
	ls -lh "$ipk"
	sha256sum "$ipk"
done

trap - ERR INT TERM HUP

echo "LUCI_OPKG_SOURCE_BACKUP=${BACKUP:-EXISTING_PATCH}"
echo "LUCI_OPKG_BUILD_LOG=$BUILD_LOG"
echo 'LUCI_OPKG_BACKGROUND_UPDATE_5_4=PASS'
echo 'RESULT=RETURN_FULL_OUTPUT'
