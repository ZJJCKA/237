import asyncio
import importlib.util
import socket
import sys
import types
import unittest
from pathlib import Path
from unittest import mock


BIN_DIR = (
    Path(__file__).resolve().parents[1]
    / "at-webserver"
    / "files"
    / "usr"
    / "bin"
)
sys.path.insert(0, str(BIN_DIR))

for module_name in ("aiohttp", "websockets", "serial"):
    sys.modules.setdefault(module_name, types.ModuleType(module_name))

SPEC = importlib.util.spec_from_file_location(
    "at_server_under_test", BIN_DIR / "at-server.py"
)
AT_SERVER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AT_SERVER
with mock.patch("subprocess.run") as subprocess_run:
    subprocess_run.return_value = types.SimpleNamespace(returncode=1, stdout="")
    SPEC.loader.exec_module(AT_SERVER)


class NetworkATCoordinationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.connection = AT_SERVER.NetworkATConnection("unused", 0, 1)
        self.connection.socket, self.peer = socket.socketpair()
        self.connection.socket.setblocking(False)
        self.peer.setblocking(False)
        self.connection.is_connected = True

    async def asyncTearDown(self):
        await self.connection.close()
        if self.peer:
            self.peer.close()

    async def test_empty_receive_does_not_block_event_loop(self):
        read_task = asyncio.create_task(self.connection.receive(4096))
        tick_task = asyncio.create_task(asyncio.sleep(0.01, result="tick"))
        done, _ = await asyncio.wait(
            {read_task, tick_task}, return_when=asyncio.FIRST_COMPLETED
        )
        self.assertIn(tick_task, done)
        self.assertNotIn(read_task, done)
        self.assertEqual(b"", await read_task)

    async def test_idle_monitor_cannot_steal_command_response(self):
        loop = asyncio.get_running_loop()
        monitor_task = asyncio.create_task(
            self.connection.receive_unsolicited(4096)
        )
        await asyncio.sleep(0.01)
        self.assertTrue(self.connection._command_lock.locked())

        async def modem():
            command = await asyncio.wait_for(loop.sock_recv(self.peer, 64), 1)
            self.assertEqual(b"AT\r", command)
            await loop.sock_sendall(self.peer, b"\r\nOK\r\n")

        modem_task = asyncio.create_task(modem())
        command_task = asyncio.create_task(self.connection.send_command("AT"))
        await asyncio.sleep(0.01)
        self.assertFalse(command_task.done())
        self.assertEqual(b"", await monitor_task)
        response = await asyncio.wait_for(command_task, 1)
        await modem_task
        self.assertIn(b"OK\r\n", response)

    async def test_idle_urc_remains_on_monitor_path(self):
        loop = asyncio.get_running_loop()
        urc = b'+CMTI: "ME",7\r\n'
        await loop.sock_sendall(self.peer, urc)
        self.assertEqual(
            urc, await self.connection.receive_unsolicited(4096)
        )

    async def test_urc_after_terminal_response_is_not_consumed_as_response(self):
        loop = asyncio.get_running_loop()
        urc = b'+CMTI: "ME",8\r\n'

        async def modem():
            await loop.sock_recv(self.peer, 64)
            await loop.sock_sendall(self.peer, b"\r\nOK\r\n")
            await asyncio.sleep(0.02)
            await loop.sock_sendall(self.peer, urc)

        modem_task = asyncio.create_task(modem())
        response = await self.connection.send_command("AT")
        await modem_task
        self.assertNotIn(b"+CMTI:", response)
        self.assertEqual(
            urc, await self.connection.receive_unsolicited(4096)
        )

    async def test_peer_eof_marks_connection_disconnected(self):
        self.peer.close()
        self.peer = None
        self.assertFalse(await self.connection.receive(4096))
        self.assertFalse(self.connection.is_connected)

    async def test_connect_wait_yields_to_other_coroutines(self):
        await self.connection.close()
        loop = asyncio.get_running_loop()

        async def delayed_connect(sock, address):
            await asyncio.sleep(0.05)

        with mock.patch.object(loop, "sock_connect", side_effect=delayed_connect):
            connect_task = asyncio.create_task(self.connection.connect())
            self.assertEqual("tick", await asyncio.sleep(0.01, result="tick"))
            self.assertFalse(connect_task.done())
            self.assertTrue(await connect_task)


class NetworkATSourceRegressionTests(unittest.TestCase):
    def test_socket_monitor_has_no_synchronous_network_reads(self):
        source = (BIN_DIR / "at-server.py").read_text(encoding="utf-8")
        monitor = source.split("    async def monitor_socket():", 1)[1].split(
            "    async def traffic_stats_monitor():", 1
        )[0]
        self.assertNotIn(".socket.recv(", monitor)
        self.assertNotIn(".socket.settimeout(", monitor)

    def test_abnormal_exit_does_not_enter_persistent_write_loop(self):
        source = (BIN_DIR / "at-server.py").read_text(encoding="utf-8")
        shutdown_block = source.split(
            "# 只对 SIGTERM/SIGINT 触发的正常停止执行落盘。", 1
        )[1].split("if notification_started:", 1)[0]
        self.assertIn("if shutdown_event.is_set():", shutdown_block)
        self.assertIn(
            "await persist_traffic_on_shutdown(client, traffic_store)",
            shutdown_block,
        )

    def test_webhook_https_verification_and_ca_dependency_are_enabled(self):
        source = (BIN_DIR / "at-server.py").read_text(encoding="utf-8")
        package_root = BIN_DIR.parents[2]
        makefile = (package_root / "Makefile").read_text(encoding="utf-8")
        self.assertNotIn("ssl=False", source)
        self.assertIn("+ca-bundle", makefile)

    def test_backend_declares_optimized_modem_dependency(self):
        package_root = BIN_DIR.parents[2]
        makefile = (package_root / "Makefile").read_text(encoding="utf-8")
        self.assertIn("+luci-app-modem", makefile)


class ManagedMT5700StartupTests(unittest.IsolatedAsyncioTestCase):
    def test_gate_requires_exact_r3mini_serial_topology(self):
        serial_config = {
            "TYPE": "SERIAL",
            "SERIAL": {"PORT": "/dev/ttyUSB1"},
        }
        with (
            mock.patch.object(AT_SERVER, "AT_CONFIG", serial_config),
            mock.patch.object(
                AT_SERVER,
                "_read_small_text",
                return_value="bananapi,bpi-r3mini-emmc",
            ),
            mock.patch.object(AT_SERVER, "_tty_has_usb_parent", return_value=True),
        ):
            self.assertTrue(AT_SERVER._is_managed_r3mini_mt5700_serial())

        for config in (
            {"TYPE": "NETWORK", "SERIAL": {"PORT": "/dev/ttyUSB1"}},
            {"TYPE": "SERIAL", "SERIAL": {"PORT": "/dev/ttyUSB0"}},
        ):
            with mock.patch.object(AT_SERVER, "AT_CONFIG", config):
                self.assertFalse(AT_SERVER._is_managed_r3mini_mt5700_serial())

    async def test_exact_target_waits_then_uses_silent_at_probe(self):
        connection = types.SimpleNamespace(
            send_command=mock.AsyncMock(return_value=bytearray(b"\r\nOK\r\n")),
            close=mock.AsyncMock(),
        )
        client = types.SimpleNamespace(connection=connection)
        with (
            mock.patch.object(
                AT_SERVER, "_is_managed_r3mini_mt5700_serial", return_value=True
            ),
            mock.patch.object(AT_SERVER, "_sendat_cfun_enabled", return_value=True),
            mock.patch.object(AT_SERVER.os.path, "exists", return_value=True),
        ):
            await AT_SERVER.wait_for_managed_mt5700_startup(
                client, marker_timeout=0.01, probe_timeout=0.01
            )

        connection.send_command.assert_awaited_once_with("AT", report_error=False)
        connection.close.assert_not_awaited()

    async def test_non_target_skips_marker_and_probe(self):
        connection = types.SimpleNamespace(
            send_command=mock.AsyncMock(),
            close=mock.AsyncMock(),
        )
        client = types.SimpleNamespace(connection=connection)
        with mock.patch.object(
            AT_SERVER, "_is_managed_r3mini_mt5700_serial", return_value=False
        ):
            await AT_SERVER.wait_for_managed_mt5700_startup(client)
        connection.send_command.assert_not_awaited()

    async def test_silent_probe_does_not_emit_runtime_error(self):
        class FailingConnection(AT_SERVER.ATConnection):
            async def connect(self):
                self.is_connected = True
                return True

            async def close(self):
                self.is_connected = False

            async def send(self, data):
                raise ConnectionError("busy")

            async def receive(self, size):
                return b""

        connection = FailingConnection()
        connection.is_connected = True
        with (
            mock.patch.object(AT_SERVER.logger, "error") as log_error,
            mock.patch.object(AT_SERVER.asyncio, "sleep", new=mock.AsyncMock()),
        ):
            self.assertEqual(
                bytearray(), await connection.send_command("AT", report_error=False)
            )
        log_error.assert_not_called()


class WebSocketOriginTests(unittest.TestCase):
    def test_same_host_origin_is_allowed_across_ports(self):
        allowed = AT_SERVER.WebSocketServer._origin_is_allowed
        self.assertTrue(allowed("http://192.168.8.1", "192.168.8.1:8765"))
        self.assertTrue(allowed("https://router.lan", "router.lan:8765"))
        self.assertTrue(allowed("http://[fd00::1]", "[fd00::1]:8765"))
        self.assertTrue(allowed("http://router.lan.", "router.lan:8765"))

    def test_cross_site_or_invalid_origin_is_rejected(self):
        allowed = AT_SERVER.WebSocketServer._origin_is_allowed
        self.assertFalse(allowed("https://attacker.example", "192.168.8.1:8765"))
        self.assertFalse(allowed("ftp://router.lan", "router.lan:8765"))
        self.assertFalse(allowed("http://[invalid", "router.lan:8765"))

    def test_missing_origin_keeps_non_browser_clients_compatible(self):
        self.assertTrue(
            AT_SERVER.WebSocketServer._origin_is_allowed(None, "router.lan:8765")
        )


class WebSocketCommandTests(unittest.IsolatedAsyncioTestCase):
    async def test_empty_modem_response_is_reported_as_failure(self):
        client = types.SimpleNamespace(
            connection_type="NETWORK",
            send_command=mock.AsyncMock(return_value=bytearray()),
        )
        store = mock.Mock()
        server = AT_SERVER.WebSocketServer(client, store)

        result = await server._process_command("AT+CSQ")

        self.assertFalse(result.success)
        self.assertEqual("未收到响应", result.error)
        store.rewrite_query_response.assert_not_called()


class TrafficShutdownPersistenceTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    def modem_response(ds_time=1, tx=2, rx=3):
        return (
            "^DSFLOWQRY: 00000001,00000002,00000003,"
            f"{ds_time:08X},{tx:016X},{rx:016X}\r\nOK"
        ).encode("ascii")

    async def test_runtime_samples_update_memory_without_flushing(self):
        events = []
        client = types.SimpleNamespace(
            is_connected=True,
            send_command=mock.AsyncMock(return_value=self.modem_response()),
        )
        store = types.SimpleNamespace(
            enabled=True,
            rewrite_query_response=lambda response: events.append("observe"),
            flush=lambda force=False: events.append("flush"),
        )

        self.assertTrue(await AT_SERVER.collect_traffic_sample(client, store))
        self.assertTrue(await AT_SERVER.collect_traffic_sample(client, store))

        self.assertEqual(["observe", "observe"], events)

    async def test_shutdown_observes_final_sample_before_single_flush(self):
        events = []
        client = types.SimpleNamespace(
            is_connected=True,
            send_command=mock.AsyncMock(return_value=self.modem_response(4, 5, 6)),
        )

        def observe(response):
            events.append("observe")

        def flush(force=False):
            events.append(("flush", force))
            return True

        store = types.SimpleNamespace(
            enabled=True,
            rewrite_query_response=observe,
            flush=flush,
        )

        self.assertTrue(
            await AT_SERVER.persist_traffic_on_shutdown(client, store)
        )
        self.assertEqual(["observe", ("flush", True)], events)

    async def test_shutdown_query_failure_still_flushes_last_known_state(self):
        events = []
        client = types.SimpleNamespace(
            is_connected=True,
            send_command=mock.AsyncMock(side_effect=ConnectionError("offline")),
        )
        store = types.SimpleNamespace(
            enabled=True,
            rewrite_query_response=lambda response: events.append("observe"),
            flush=lambda force=False: events.append(("flush", force)) or True,
        )

        self.assertTrue(
            await AT_SERVER.persist_traffic_on_shutdown(client, store)
        )
        self.assertEqual([("flush", True)], events)

    async def test_shutdown_query_timeout_is_bounded_and_still_flushes(self):
        async def never_responds(command):
            await asyncio.Event().wait()

        events = []
        client = types.SimpleNamespace(
            is_connected=True,
            send_command=never_responds,
        )
        store = types.SimpleNamespace(
            enabled=True,
            rewrite_query_response=lambda response: events.append("observe"),
            flush=lambda force=False: events.append(("flush", force)) or True,
        )

        self.assertTrue(
            await AT_SERVER.persist_traffic_on_shutdown(
                client, store, query_timeout=0.01
            )
        )
        self.assertEqual([("flush", True)], events)


class ConfigFallbackTests(unittest.TestCase):
    def test_invalid_uci_values_fall_back_to_complete_schedule_defaults(self):
        result = types.SimpleNamespace(
            returncode=0,
            stdout=(
                "at-webserver.config=at-webserver\n"
                "at-webserver.config.connection_type='NETWORK'\n"
                "at-webserver.config.network_port='invalid'\n"
            ),
        )
        with mock.patch("subprocess.run", return_value=result):
            config = AT_SERVER.load_config()

        required = {
            "ENABLED", "CHECK_INTERVAL", "TIMEOUT", "UNLOCK_LTE",
            "UNLOCK_NR", "TOGGLE_AIRPLANE", "NIGHT_ENABLED",
            "NIGHT_START", "NIGHT_END", "NIGHT_LTE_TYPE",
            "NIGHT_LTE_BANDS", "NIGHT_LTE_ARFCNS", "NIGHT_LTE_PCIS",
            "NIGHT_NR_TYPE", "NIGHT_NR_BANDS", "NIGHT_NR_ARFCNS",
            "NIGHT_NR_SCS_TYPES", "NIGHT_NR_PCIS", "DAY_ENABLED",
            "DAY_LTE_TYPE", "DAY_LTE_BANDS", "DAY_LTE_ARFCNS",
            "DAY_LTE_PCIS", "DAY_NR_TYPE", "DAY_NR_BANDS",
            "DAY_NR_ARFCNS", "DAY_NR_SCS_TYPES", "DAY_NR_PCIS",
        }
        self.assertTrue(required.issubset(config["SCHEDULE_CONFIG"]))
        with mock.patch.object(
            AT_SERVER, "SCHEDULE_CONFIG", config["SCHEDULE_CONFIG"]
        ):
            AT_SERVER.ScheduleFrequencyLock(None)

    def test_loaded_config_does_not_mutate_default_nested_values(self):
        original_host = AT_SERVER.DEFAULT_CONFIG["AT_CONFIG"]["NETWORK"]["HOST"]
        result = types.SimpleNamespace(
            returncode=0,
            stdout=(
                "at-webserver.config=at-webserver\n"
                "at-webserver.config.connection_type='NETWORK'\n"
                "at-webserver.config.network_host='10.0.0.99'\n"
            ),
        )
        with mock.patch("subprocess.run", return_value=result):
            config = AT_SERVER.load_config()
        self.assertEqual("10.0.0.99", config["AT_CONFIG"]["NETWORK"]["HOST"])
        self.assertEqual(
            original_host,
            AT_SERVER.DEFAULT_CONFIG["AT_CONFIG"]["NETWORK"]["HOST"],
        )

    def test_bad_schedule_number_does_not_discard_valid_auth_key(self):
        result = types.SimpleNamespace(
            returncode=0,
            stdout=(
                "at-webserver.config=at-webserver\n"
                "at-webserver.config.websocket_auth_key='secret-key'\n"
                "at-webserver.config.schedule_timeout='invalid'\n"
            ),
        )
        with mock.patch("subprocess.run", return_value=result):
            config = AT_SERVER.load_config()

        self.assertEqual(
            "secret-key", config["WEBSOCKET_CONFIG"]["AUTH_KEY"]
        )
        self.assertEqual(180, config["SCHEDULE_CONFIG"]["TIMEOUT"])


if __name__ == "__main__":
    unittest.main()
