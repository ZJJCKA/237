"""Persistent cumulative traffic counters for MT5700 ``AT^DSFLOWQRY``.

The modem's total counters reset when it loses power.  This module keeps a
durable logical total and rewrites query responses before they reach the WebUI.
"""

import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Dict, Optional


logger = logging.getLogger(__name__)


class TrafficStatsStore:
    """Merge volatile modem counters into durable cumulative totals."""

    VERSION = 1
    COUNTERS = ("ds_time", "tx", "rx")
    DSFLOW_PATTERN = re.compile(
        r"(?P<prefix>\^DSFLOWQRY\s*:?\s*)"
        r"(?P<values>[0-9A-Fa-f]+(?:\s*,\s*[0-9A-Fa-f]+){5})"
    )

    def __init__(
        self,
        state_file: str = "/etc/at-webserver/traffic-stats.json",
        enabled: bool = True,
    ):
        self.state_file = Path(state_file)
        self.enabled = enabled
        self._totals = {name: 0 for name in self.COUNTERS}
        self._raw = {name: 0 for name in self.COUNTERS}
        self._initialized = False
        self._dirty = False
        if self.enabled:
            self._load()

    @staticmethod
    def _valid_counters(value: object) -> Optional[Dict[str, int]]:
        if not isinstance(value, dict):
            return None
        counters = {}
        for name in TrafficStatsStore.COUNTERS:
            item = value.get(name)
            if not isinstance(item, int) or isinstance(item, bool) or item < 0:
                return None
            counters[name] = item
        return counters

    def _load(self) -> None:
        try:
            with self.state_file.open("r", encoding="utf-8") as handle:
                state = json.load(handle)
            if not isinstance(state, dict):
                raise ValueError("invalid traffic state root")
            if state.get("version") != self.VERSION:
                raise ValueError("unsupported traffic state version")
            totals = self._valid_counters(state.get("totals"))
            raw = self._valid_counters(state.get("raw"))
            if totals is None or raw is None:
                raise ValueError("invalid traffic counters")
            self._totals = totals
            self._raw = raw
            self._initialized = True
            logger.info(
                "已恢复流量统计: 上传=%d, 下载=%d, 时长=%d",
                totals["tx"],
                totals["rx"],
                totals["ds_time"],
            )
        except FileNotFoundError:
            logger.info("未找到历史流量统计，将从模组当前计数开始")
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            logger.warning("读取流量统计文件失败，将从模组当前计数开始: %s", exc)

    @staticmethod
    def _format_hex(value: int, original: str) -> str:
        width = max(len(original), 1)
        return format(value, "0{}X".format(width))

    def _observe(self, current: Dict[str, int]) -> Dict[str, int]:
        if not self._initialized:
            new_totals = dict(current)
            self._initialized = True
        else:
            new_totals = {}
            for name in self.COUNTERS:
                raw_now = current[name]
                raw_before = self._raw[name]
                # A smaller value means the modem rebooted or its counter wrapped.
                increment = raw_now - raw_before if raw_now >= raw_before else raw_now
                new_totals[name] = self._totals[name] + max(increment, 0)

        if new_totals != self._totals or current != self._raw:
            self._dirty = True
        self._totals = new_totals
        self._raw = dict(current)
        return dict(self._totals)

    def rewrite_query_response(self, response: str) -> str:
        """Update counters and replace DSFLOW total fields in ``response``."""
        if not self.enabled:
            return response
        match = self.DSFLOW_PATTERN.search(response)
        if not match:
            return response

        fields = re.split(r"\s*,\s*", match.group("values"))
        try:
            current = {
                "ds_time": int(fields[3], 16),
                "tx": int(fields[4], 16),
                "rx": int(fields[5], 16),
            }
        except (IndexError, ValueError):
            logger.warning("无法解析 DSFLOWQRY 响应: %s", match.group("values"))
            return response

        totals = self._observe(current)
        fields[3] = self._format_hex(totals["ds_time"], fields[3])
        fields[4] = self._format_hex(totals["tx"], fields[4])
        fields[5] = self._format_hex(totals["rx"], fields[5])
        values = ",".join(fields)
        return response[: match.start("values")] + values + response[match.end("values") :]

    def reset(self) -> None:
        """Reset totals and durably record the explicit user action."""
        self._totals = {name: 0 for name in self.COUNTERS}
        self._raw = {name: 0 for name in self.COUNTERS}
        self._initialized = True
        self._dirty = True
        # A manual clear is intentionally the only runtime write exception.
        # Persist it immediately so an abrupt power loss cannot resurrect the
        # pre-clear totals from the previous shutdown snapshot.
        self.flush(force=True)

    def flush(self, force: bool = False) -> bool:
        """Atomically and durably write the latest observed counters."""
        if not self.enabled or not self._initialized or (not force and not self._dirty):
            return False

        parent = self.state_file.parent
        temporary = self.state_file.with_name(
            "{}.tmp.{}".format(self.state_file.name, os.getpid())
        )
        state = {
            "version": self.VERSION,
            "updated_at": int(time.time()),
            "totals": self._totals,
            "raw": self._raw,
        }

        try:
            parent.mkdir(parents=True, exist_ok=True)
            with temporary.open("w", encoding="utf-8") as handle:
                json.dump(state, handle, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.state_file)

            # Persist the rename itself when the filesystem supports directory fsync.
            if hasattr(os, "O_DIRECTORY"):
                directory_fd = os.open(str(parent), os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)

            self._dirty = False
            return True
        except OSError as exc:
            logger.error("保存流量统计失败: %s", exc)
            try:
                temporary.unlink()
            except OSError:
                pass
            return False

    def snapshot(self) -> Dict[str, Dict[str, int]]:
        """Return a copy of state for diagnostics and tests."""
        return {"totals": dict(self._totals), "raw": dict(self._raw)}
