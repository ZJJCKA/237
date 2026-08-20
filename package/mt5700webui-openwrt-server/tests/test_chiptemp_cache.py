import asyncio
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BIN_DIR = ROOT / "at-webserver" / "files" / "usr" / "bin"


def load_server_module():
    sys.path.insert(0, str(BIN_DIR))
    sys.modules.setdefault("aiohttp", types.ModuleType("aiohttp"))
    serial_module = sys.modules.setdefault("serial", types.ModuleType("serial"))
    serial_module.Serial = object
    websocket_module = sys.modules.setdefault("websockets", types.ModuleType("websockets"))
    websocket_module.exceptions = types.SimpleNamespace(ConnectionClosed=Exception)
    websocket_module.serve = None
    spec = importlib.util.spec_from_file_location("at_server_chiptemp_test", BIN_DIR / "at-server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SERVER = load_server_module()


class ChiptempCacheTests(unittest.TestCase):
    def test_poll_interval_is_exactly_five_seconds(self):
        self.assertEqual(SERVER.CHIPTEMP_POLL_INTERVAL, 5)

    def test_parser_uses_hottest_valid_of_twelve_tenths(self):
        response = b"AT^CHIPTEMP?\r\n^CHIPTEMP: 421,65535,503,499,510,487,520,515,600,590,580,570\r\nOK\r\n"
        self.assertEqual(SERVER.parse_mt5700_chiptemp(response), 60000)

    def test_parser_rejects_missing_or_malformed_payload(self):
        self.assertIsNone(SERVER.parse_mt5700_chiptemp("OK"))
        self.assertIsNone(SERVER.parse_mt5700_chiptemp("^CHIPTEMP: 1,2,3"))
        self.assertIsNone(SERVER.parse_mt5700_chiptemp("^CHIPTEMP: x,x,x,x,x,x,x,x,x,x,x,x"))

    def test_cache_is_atomic_and_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = os.path.join(temporary, "private", "chiptemp.status")
            self.assertTrue(SERVER.write_chiptemp_cache(61200, 123, cache))
            self.assertEqual(
                Path(cache).read_text(encoding="ascii"),
                "version=1\ntemp_mc=61200\nsample_uptime=123\n",
            )
            if os.name != "nt":
                self.assertEqual(os.stat(os.path.dirname(cache)).st_mode & 0o777, 0o700)
                self.assertEqual(os.stat(cache).st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(os.path.dirname(cache)).glob("*.tmp.*")), [])

    def test_collector_uses_client_command_path(self):
        class Client:
            is_connected = True
            commands = []

            async def send_command(self, command):
                self.commands.append(command)
                return b"^CHIPTEMP: 500,510,520,530,540,550,560,570,580,590,600,610\r\nOK\r\n"

        client = Client()
        with tempfile.TemporaryDirectory() as temporary:
            cache = os.path.join(temporary, "runtime", "chiptemp.status")
            original_probe = SERVER._is_managed_r3mini_mt5700_serial
            original_uptime = SERVER._read_uptime_seconds
            SERVER._is_managed_r3mini_mt5700_serial = lambda: True
            SERVER._read_uptime_seconds = lambda: 123
            try:
                self.assertTrue(asyncio.run(SERVER.collect_chiptemp_sample(client, cache)))
            finally:
                SERVER._is_managed_r3mini_mt5700_serial = original_probe
                SERVER._read_uptime_seconds = original_uptime
            self.assertEqual(client.commands, ["AT^CHIPTEMP?\r"])
            self.assertIn("temp_mc=61000\n", Path(cache).read_text(encoding="ascii"))


if __name__ == "__main__":
    unittest.main()
