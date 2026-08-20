#!/usr/bin/env python3
"""Safety contract for the single temperature-source implementation."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def shell_path(path: Path) -> str:
    value = path.resolve().as_posix()
    if len(value) >= 3 and value[1:3] == ":/":
        return f"/{value[0].lower()}{value[2:]}"
    return value


def find_shell() -> Path:
    override = os.environ.get("FANCONTROL_TEST_SHELL")
    if override:
        candidate = Path(override)
        if candidate.is_file():
            return candidate
        raise RuntimeError(f"FANCONTROL_TEST_SHELL does not exist: {override}")
    candidate = (
        Path.home()
        / ".cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/usr/bin/sh.exe"
    )
    if candidate.is_file():
        return candidate
    located = shutil.which("sh")
    if located:
        return Path(located)
    raise RuntimeError("No POSIX sh was found for the Wi-Fi parser test")


def function_source(text: str, name: str) -> str:
    match = re.search(rf"(?ms)^{re.escape(name)}\(\)\n\{{\n.*?^\}}\n", text)
    if not match:
        raise AssertionError(f"missing shell function: {name}")
    return match.group(0)


def test_iwpriv_parser(collector: str) -> None:
    parser = function_source(collector, "parse_iwpriv_temperature")
    harness = """#!/bin/sh
set -eu
__PARSER_FUNCTION__
check()
{
    expected="$1"
    shift
    actual="$(printf '%b' "$1" | parse_iwpriv_temperature)"
    [ "$actual" = "$expected" ] || {
        printf 'expected=[%s] actual=[%s] input=[%s]\n' "$expected" "$actual" "$1" >&2
        exit 1
    }
}
check 46 'CurrentTemperature              = 46\n'
check 46 'CurrentTemperature = 46 CalOffset = 2\n'
check -5 'CurrentTemperature = -5 C\n'
check 61 'noise=2\nCurrentTemperature = 61\r\n'
check 8 'CurrentTemperature = 08\n'
check 0 'CurrentTemperature = -0\n'
check -40 'CurrentTemperature = -40\n'
check 150 'CurrentTemperature = 150\n'
check '' 'CurrentTemperature = 46.5\n'
check '' 'CurrentTemperature = unavailable\n'
check '' 'CurrentTemperature = -41\n'
check '' 'CurrentTemperature = 151\n'
check '' 'CurrentTemperature = 0008\n'
check '' 'CurrentTemperature = 999999999999999999999999999999999999999999999999999999\n'
check '' 'NotCurrentTemperature = 46\n'
check '' 'PrefixCurrentTemperature = 46\n'
check '' 'CurrentTemperatureExtra = 46\n'
check '' 'noise CurrentTemperature = 46\n'
check 12 'NotCurrentTemperature = 99\nCurrentTemperature = -41\n  CurrentTemperature = 12 C\nCurrentTemperature = 150\n'
""".replace("__PARSER_FUNCTION__", parser)
    shell = find_shell()
    with tempfile.TemporaryDirectory(prefix="fan-wifi-parser-", dir=ROOT.parent) as temporary:
        base = Path(temporary)
        script = base / "test.sh"
        script.write_text(harness, encoding="utf-8", newline="\n")
        script.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = shell_path(shell.parent) + ":/usr/bin:/bin"
        result = subprocess.run(
            [str(shell), script.name],
            cwd=base,
            env=environment,
            capture_output=True,
            timeout=10,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                result.stderr.decode("utf-8", errors="replace")
                or result.stdout.decode("utf-8", errors="replace")
            )


def test_iwpriv_watchdog(collector: str) -> None:
    names = (
        "iwpriv_interface_disabled",
        "disable_iwpriv_interface",
        "enable_iwpriv_interface",
        "remember_stuck_iwpriv",
        "reap_stuck_iwpriv",
        "cleanup_iwpriv_run",
        "run_iwpriv_stat",
    )
    functions = "\n".join(function_source(collector, name) for name in names)
    harness = r'''#!/bin/sh
set -fu
CACHE_DIR="$FAN_TEST_CACHE"
IWPRIV_SEQUENCE=0
IWPRIV_ACTIVE_PID=
IWPRIV_ACTIVE_IDENTITY=
IWPRIV_RUN_DIR=
IWPRIV_OUTPUT_FILE=
IWPRIV_OUTPUT=
IWPRIV_PROCESS_STATE=UNKNOWN
IWPRIV_PROCESS_IDENTITY=
IWPRIV_DISABLED_INTERFACES=
IWPRIV_RA0_PID=
IWPRIV_RA0_IDENTITY=
IWPRIV_RAX0_PID=
IWPRIV_RAX0_IDENTITY=

trusted_path() { return 0; }
chown() { return 0; }
chmod() { return 0; }
sleep() { "$FAN_TEST_PYTHON" -c 'import sys,time; time.sleep(float(sys.argv[1]))' "$1"; }
read_process_identity() { printf '%s\n' "$$:12345"; }
classify_iwpriv_process()
{
    IWPRIV_PROCESS_IDENTITY="${2:-$$:12345}"
    if [ -f "$FAN_TEST_ALLOW_REAP" ] && [ "$1" = "$IWPRIV_RA0_PID" ]; then
        IWPRIV_PROCESS_STATE=REAPABLE
    elif [ "$(wc -l < "$FAN_TEST_LAUNCHES")" -ge 2 ]; then
        IWPRIV_PROCESS_STATE=REAPABLE
    else
        IWPRIV_PROCESS_STATE=ACTIVE
    fi
}
iwpriv()
{
    printf '1\n' >> "$FAN_TEST_LAUNCHES"
    if [ "$(wc -l < "$FAN_TEST_LAUNCHES")" -ge 2 ]; then
        printf 'CurrentTemperature = 46\n'
        return 0
    fi
    printf 'CurrentTemperature = 99\n'
    while :; do :; done
}
__WATCHDOG_FUNCTIONS__

: > "$FAN_TEST_LAUNCHES"
run_iwpriv_stat ra0 && exit 20
[ -z "$IWPRIV_OUTPUT" ] || exit 21
[ "$IWPRIV_DISABLED_INTERFACES" = ra0 ] || exit 22
[ "$(wc -l < "$FAN_TEST_LAUNCHES")" -eq 1 ] || exit 23
stuck_pid="$IWPRIV_RA0_PID"
[ -n "$stuck_pid" ] || exit 24

# This is the next collection round. The poisoned interface must not launch
# another child and the caller must continue immediately.
run_iwpriv_stat ra0 && exit 25
printf 'next-round-ran\n' > "$FAN_TEST_NEXT_ROUND"
[ "$(wc -l < "$FAN_TEST_LAUNCHES")" -eq 1 ] || exit 26

# The real child is killable in this harness; the classifier deliberately
# models a kernel-stuck task so the production path must never wait for it.
kill -KILL "$stuck_pid" 2>/dev/null || :
wait "$stuck_pid" 2>/dev/null || :
: > "$FAN_TEST_ALLOW_REAP"
reap_stuck_iwpriv
[ -z "$IWPRIV_DISABLED_INTERFACES" ] || exit 27
[ -z "$IWPRIV_RA0_PID" ] || exit 28

# Once the exact poisoned child is reapable, the same radio must recover on
# the next collection round instead of staying disabled until service restart.
run_iwpriv_stat ra0 || exit 29
[ "$IWPRIV_OUTPUT" = 'CurrentTemperature = 46' ] || exit 30
[ "$(wc -l < "$FAN_TEST_LAUNCHES")" -eq 2 ] || exit 31
'''.replace("__WATCHDOG_FUNCTIONS__", functions)
    shell = find_shell()
    with tempfile.TemporaryDirectory(prefix="fan-wifi-watchdog-", dir=ROOT.parent) as temporary:
        base = Path(temporary)
        script = base / "test.sh"
        cache = base / "cache"
        launches = base / "launches"
        next_round = base / "next-round"
        cache.mkdir(mode=0o700)
        script.write_text(harness, encoding="utf-8", newline="\n")
        script.chmod(0o755)
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": shell_path(shell.parent) + ":/usr/bin:/bin",
                "FAN_TEST_CACHE": "cache",
                "FAN_TEST_LAUNCHES": "launches",
                "FAN_TEST_NEXT_ROUND": "next-round",
                "FAN_TEST_ALLOW_REAP": "allow-reap",
                "FAN_TEST_PYTHON": Path(sys.executable).as_posix(),
            }
        )
        started = time.monotonic()
        result = subprocess.run(
            [str(shell), script.name],
            cwd=base,
            env=environment,
            capture_output=True,
            timeout=4,
            check=False,
        )
        elapsed = time.monotonic() - started
        if result.returncode != 0:
            raise AssertionError(
                result.stderr.decode("utf-8", errors="replace")
                or result.stdout.decode("utf-8", errors="replace")
                or f"watchdog harness rc={result.returncode}"
            )
        assert elapsed <= 3.0, f"watchdog returned too slowly: {elapsed:.3f}s"
        assert next_round.read_text(encoding="utf-8") == "next-round-ran\n"
        assert launches.read_text(encoding="utf-8") == "1\n1\n"


def test_reaped_timeout_is_retried(collector: str) -> None:
    names = (
        "iwpriv_interface_disabled",
        "disable_iwpriv_interface",
        "enable_iwpriv_interface",
        "remember_stuck_iwpriv",
        "reap_stuck_iwpriv",
        "cleanup_iwpriv_run",
        "run_iwpriv_stat",
    )
    functions = "\n".join(function_source(collector, name) for name in names)
    harness = r'''#!/bin/sh
set -fu
CACHE_DIR="$FAN_TEST_CACHE"
IWPRIV_SEQUENCE=0
IWPRIV_ACTIVE_PID=
IWPRIV_ACTIVE_IDENTITY=
IWPRIV_RUN_DIR=
IWPRIV_OUTPUT_FILE=
IWPRIV_OUTPUT=
IWPRIV_PROCESS_STATE=UNKNOWN
IWPRIV_PROCESS_IDENTITY=
IWPRIV_DISABLED_INTERFACES=
IWPRIV_RA0_PID=
IWPRIV_RA0_IDENTITY=
IWPRIV_RAX0_PID=
IWPRIV_RAX0_IDENTITY=

trusted_path() { return 0; }
chown() { return 0; }
chmod() { return 0; }
sleep() { "$FAN_TEST_PYTHON" -c 'import sys,time; time.sleep(float(sys.argv[1]))' "$1"; }
read_process_identity() { printf '%s\n' "$$:12345"; }
classify_iwpriv_process()
{
    IWPRIV_PROCESS_IDENTITY="${2:-$$:12345}"
    if [ -f "$FAN_TEST_KILLED" ] || [ "$(wc -l < "$FAN_TEST_LAUNCHES")" -ge 2 ]; then
        IWPRIV_PROCESS_STATE=REAPABLE
    else
        IWPRIV_PROCESS_STATE=ACTIVE
    fi
}
kill()
{
    : > "$FAN_TEST_KILLED"
    command kill "$@"
}
iwpriv()
{
    printf '1\n' >> "$FAN_TEST_LAUNCHES"
    if [ "$(wc -l < "$FAN_TEST_LAUNCHES")" -ge 2 ]; then
        printf 'CurrentTemperature = 47\n'
        return 0
    fi
    while :; do :; done
}
__WATCHDOG_FUNCTIONS__

: > "$FAN_TEST_LAUNCHES"
run_iwpriv_stat ra0 && exit 40
[ -z "$IWPRIV_DISABLED_INTERFACES" ] || exit 41
[ -z "$IWPRIV_RA0_PID" ] || exit 42
[ "$(wc -l < "$FAN_TEST_LAUNCHES")" -eq 1 ] || exit 43

rm -f "$FAN_TEST_KILLED"
run_iwpriv_stat ra0 || exit 44
[ "$IWPRIV_OUTPUT" = 'CurrentTemperature = 47' ] || exit 45
[ "$(wc -l < "$FAN_TEST_LAUNCHES")" -eq 2 ] || exit 46
'''.replace("__WATCHDOG_FUNCTIONS__", functions)
    shell = find_shell()
    with tempfile.TemporaryDirectory(prefix="fan-wifi-retry-", dir=ROOT.parent) as temporary:
        base = Path(temporary)
        script = base / "test.sh"
        cache = base / "cache"
        launches = base / "launches"
        cache.mkdir(mode=0o700)
        script.write_text(harness, encoding="utf-8", newline="\n")
        script.chmod(0o755)
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": shell_path(shell.parent) + ":/usr/bin:/bin",
                "FAN_TEST_CACHE": "cache",
                "FAN_TEST_LAUNCHES": "launches",
                "FAN_TEST_KILLED": "killed",
                "FAN_TEST_PYTHON": Path(sys.executable).as_posix(),
            }
        )
        started = time.monotonic()
        result = subprocess.run(
            [str(shell), script.name],
            cwd=base,
            env=environment,
            capture_output=True,
            timeout=4,
            check=False,
        )
        elapsed = time.monotonic() - started
        if result.returncode != 0:
            raise AssertionError(
                result.stderr.decode("utf-8", errors="replace")
                or result.stdout.decode("utf-8", errors="replace")
                or f"reaped-timeout retry harness rc={result.returncode}"
            )
        assert elapsed <= 3.0, f"reaped timeout retry was too slow: {elapsed:.3f}s"
        assert launches.read_text(encoding="utf-8") == "1\n1\n"


def test_unknown_process_is_never_waited(collector: str) -> None:
    run_iwpriv = function_source(collector, "run_iwpriv_stat")
    harness = r'''#!/bin/sh
set -fu
CACHE_DIR="$FAN_TEST_CACHE"
IWPRIV_SEQUENCE=0
IWPRIV_ACTIVE_PID=
IWPRIV_ACTIVE_IDENTITY=
IWPRIV_RUN_DIR=
IWPRIV_OUTPUT_FILE=
IWPRIV_OUTPUT=
IWPRIV_PROCESS_STATE=UNKNOWN
IWPRIV_PROCESS_IDENTITY=
IWPRIV_DISABLED_INTERFACES=

reap_stuck_iwpriv() { :; }
iwpriv_interface_disabled() { return 1; }
disable_iwpriv_interface() { IWPRIV_DISABLED_INTERFACES="$1"; }
remember_stuck_iwpriv()
{
    IWPRIV_RA0_PID="$2"
    IWPRIV_RA0_IDENTITY="$3"
}
cleanup_iwpriv_run()
{
    [ -z "$IWPRIV_OUTPUT_FILE" ] || rm -f "$IWPRIV_OUTPUT_FILE"
    [ -z "$IWPRIV_RUN_DIR" ] || rmdir "$IWPRIV_RUN_DIR" 2>/dev/null || :
    IWPRIV_RUN_DIR=
    IWPRIV_OUTPUT_FILE=
}
trusted_path() { return 0; }
chown() { return 0; }
chmod() { return 0; }
read_process_identity() { return 1; }
classify_iwpriv_process()
{
    IWPRIV_PROCESS_STATE=UNKNOWN
    IWPRIV_PROCESS_IDENTITY=
}
sleep() { "$FAN_TEST_PYTHON" -c 'import sys,time; time.sleep(float(sys.argv[1]))' "$1"; }
iwpriv()
{
    printf '1\n' >> "$FAN_TEST_LAUNCHES"
    while :; do :; done
}
__RUN_IWPRIV_FUNCTION__

: > "$FAN_TEST_LAUNCHES"
run_iwpriv_stat ra0 && exit 30
[ "$IWPRIV_DISABLED_INTERFACES" = ra0 ] || exit 31
[ -n "$IWPRIV_RA0_PID" ] || exit 32
unknown_pid="$IWPRIV_RA0_PID"
kill -KILL "$unknown_pid" 2>/dev/null || :
wait "$unknown_pid" 2>/dev/null || :
'''.replace("__RUN_IWPRIV_FUNCTION__", run_iwpriv)
    shell = find_shell()
    with tempfile.TemporaryDirectory(prefix="fan-wifi-unknown-", dir=ROOT.parent) as temporary:
        base = Path(temporary)
        script = base / "test.sh"
        cache = base / "cache"
        launches = base / "launches"
        cache.mkdir(mode=0o700)
        script.write_text(harness, encoding="utf-8", newline="\n")
        script.chmod(0o755)
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": shell_path(shell.parent) + ":/usr/bin:/bin",
                "FAN_TEST_CACHE": "cache",
                "FAN_TEST_LAUNCHES": "launches",
                "FAN_TEST_PYTHON": Path(sys.executable).as_posix(),
            }
        )
        started = time.monotonic()
        result = subprocess.run(
            [str(shell), script.name],
            cwd=base,
            env=environment,
            capture_output=True,
            timeout=2,
            check=False,
        )
        elapsed = time.monotonic() - started
        if result.returncode != 0:
            raise AssertionError(
                result.stderr.decode("utf-8", errors="replace")
                or result.stdout.decode("utf-8", errors="replace")
                or f"unknown-state harness rc={result.returncode}"
            )
        assert elapsed <= 1.0, f"UNKNOWN path waited for child: {elapsed:.3f}s"
        assert launches.read_text(encoding="utf-8") == "1\n"


def main() -> None:
    daemon = (ROOT / "root/usr/bin/fancontrol").read_text(encoding="utf-8")
    collector = (ROOT / "root/usr/bin/fancontrol-sensors").read_text(encoding="utf-8")
    controller = (ROOT / "luasrc/controller/fancontrol.lua").read_text(encoding="utf-8")
    init = (ROOT / "root/etc/init.d/fancontrol").read_text(encoding="utf-8")
    default = (ROOT / "root/etc/config/fancontrol").read_text(encoding="utf-8")
    maintained = (ROOT / "root/usr/share/fancontrol/fancontrol.default").read_text(encoding="utf-8")
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

    assert default == maintained
    for content in (default, makefile):
        assert "option temp_sources 'cpu'" in content

    assert "TEMP_SOURCE_IDS = { \"cpu\", \"wifi\", \"modem\", \"nvme\" }" in controller
    assert 'phy = true' not in controller
    assert "normalize_temp_sources" in controller
    assert "not TEMP_SOURCE_ALLOWED[value]" in controller
    assert "canonical_temp_source" in controller
    assert "invalid temperature sources" in controller
    assert "runtime_source(\"cpu\")" in controller
    assert "runtime_source(\"nvme\")" in controller
    assert "TEMP_SOURCE_ALLOWED[runtime_control_source" in controller
    assert "current_uptime - sample_uptime <= 3" in controller

    assert "set -f" in daemon and "umask 077" in daemon
    assert "MODEM_CACHE_FILE=/var/run/at-webserver/chiptemp.status" in daemon
    assert "MODEM_CACHE_TTL=20" in daemon
    assert "SENSOR_CACHE_TTL=15" in daemon
    assert "DISCOVER_COUNTDOWN=30" in daemon
    assert "selected_sources=" in daemon
    assert 'normalized="$source"; break' in daemon
    assert "source_nvme_state=" in daemon
    assert "sample_uptime=" in daemon
    assert "所选温度来源全部不可用，已使用全速保护" in daemon
    assert "温度来源配置无效，已使用全速保护" in daemon
    assert "read_cpu_temperature" in daemon and "CPU_TEMP_FILES" in daemon
    assert "discover_nvme_temperature_files" in daemon
    assert "NVME_TEMP_FILES" in daemon
    assert "trusted_cache_file" in daemon
    assert "trusted_cache_path" in daemon
    assert 'if [ -z "$WIFI_CACHE_FILE" ]; then' in daemon
    assert 'if [ -z "$TRUSTED_MODEM_CACHE_FILE" ]; then' in daemon
    assert "version_seen=0" in daemon and "sample_uptime" in daemon

    assert "POLL_INTERVAL=5" in collector
    assert "CACHE_DIR=/var/run/fancontrol-sensors" in collector
    assert "trusted_path" in collector
    assert "/sys/kernel/debug" not in collector
    assert "run_cat_with_timeout" not in collector
    assert "command -v timeout" not in collector
    assert 'iwpriv "$interface" stat > "$IWPRIV_OUTPUT_FILE" 2>/dev/null &' in collector
    assert "classify_iwpriv_process" in collector
    assert 'IWPRIV_PROCESS_STATE=UNKNOWN' in collector
    assert '[ "$IWPRIV_PROCESS_STATE" = REAPABLE ]' in collector
    assert 'disable_iwpriv_interface "$interface"' in collector
    assert 'enable_iwpriv_interface "$interface"' in collector
    assert "remember_stuck_iwpriv" in collector
    assert "trap 'exit 0' HUP INT TERM" in collector
    assert "command -v iwpriv >/dev/null 2>&1 && command -v timeout" not in collector
    assert "parse_iwpriv_temperature" in collector
    assert "read_phy_temperature" not in collector
    assert "write_cache phy" not in collector
    assert "AT^" not in collector and "sendat" not in collector
    assert "chmod 0600" in collector and "chmod 0700" in collector
    assert '[ -d "/sys/class/net/$interface" ] || continue' in collector
    for content in (daemon, collector):
        assert "stat -c" not in content
        assert '-xdev -maxdepth 0 -type "$kind"' in content
        assert '-user 0 -group 0 -perm "$permission"' in content
        assert '[ ! -L "$path" ]' in content

    target_defconfig = (
        ROOT.parent / "_work_237/defconfig/mt7986-ax4200-bpir3_mini.config"
    )
    if target_defconfig.is_file():
        target = target_defconfig.read_text(encoding="utf-8")
        assert "# CONFIG_BUSYBOX_CONFIG_STAT is not set" in target
        assert "CONFIG_BUSYBOX_CONFIG_FIND=y" in target
        for feature in (
            "CONFIG_BUSYBOX_CONFIG_FEATURE_FIND_TYPE=y",
            "CONFIG_BUSYBOX_CONFIG_FEATURE_FIND_PERM=y",
            "CONFIG_BUSYBOX_CONFIG_FEATURE_FIND_XDEV=y",
            "CONFIG_BUSYBOX_CONFIG_FEATURE_FIND_MAXDEPTH=y",
            "CONFIG_BUSYBOX_CONFIG_FEATURE_FIND_USER=y",
            "CONFIG_BUSYBOX_CONFIG_FEATURE_FIND_GROUP=y",
        ):
            assert feature in target

    assert "procd_open_instance sensors" in init
    assert "procd_open_instance controller" in init

    test_iwpriv_parser(collector)
    test_iwpriv_watchdog(collector)
    test_reaped_timeout_is_retried(collector)
    test_unknown_process_is_never_waited(collector)

    print("PASS: fancontrol single temperature-source safety contract")


if __name__ == "__main__":
    main()
