import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_DIR = Path(__file__).resolve().parents[1] / "at-webserver" / "files" / "usr" / "bin"
sys.path.insert(0, str(MODULE_DIR))

from traffic_stats import TrafficStatsStore  # noqa: E402


def response(ds_time: int, tx: int, rx: int) -> str:
    return (
        "^DSFLOWQRY: 00000001,00000002,00000003,"
        f"{ds_time:08X},{tx:016X},{rx:016X}\r\nOK"
    )


def totals_from(text: str):
    values = text.split(":", 1)[1].split("\r\n", 1)[0].strip().split(",")
    return tuple(int(values[index], 16) for index in (3, 4, 5))


class TrafficStatsStoreTests(unittest.TestCase):
    def test_first_query_starts_from_modem_totals_and_persists(self):
        with tempfile.TemporaryDirectory() as directory:
            state_file = Path(directory) / "traffic.json"
            store = TrafficStatsStore(str(state_file))

            rewritten = store.rewrite_query_response(response(100, 1000, 2000))
            self.assertEqual((100, 1000, 2000), totals_from(rewritten))
            self.assertTrue(store.flush())

            saved = json.loads(state_file.read_text(encoding="utf-8"))
            self.assertEqual(1000, saved["totals"]["tx"])
            self.assertEqual(2000, saved["totals"]["rx"])
            self.assertEqual(saved["totals"], saved["raw"])

    def test_service_restart_and_modem_power_cycle_keep_accumulating(self):
        with tempfile.TemporaryDirectory() as directory:
            state_file = Path(directory) / "traffic.json"

            first = TrafficStatsStore(str(state_file))
            first.rewrite_query_response(response(100, 1000, 2000))
            first.flush()

            # Service restart while the modem counters keep increasing.
            second = TrafficStatsStore(str(state_file))
            same_boot = second.rewrite_query_response(response(110, 1200, 2300))
            self.assertEqual((110, 1200, 2300), totals_from(same_boot))
            second.flush()

            # Full power loss resets modem counters, but durable totals remain.
            third = TrafficStatsStore(str(state_file))
            after_power_loss = third.rewrite_query_response(response(2, 50, 60))
            self.assertEqual((112, 1250, 2360), totals_from(after_power_loss))

    def test_clear_resets_durable_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            state_file = Path(directory) / "traffic.json"
            store = TrafficStatsStore(str(state_file))
            store.rewrite_query_response(response(100, 1000, 2000))
            store.flush()

            store.reset()
            reloaded = TrafficStatsStore(str(state_file))
            after_clear = reloaded.rewrite_query_response(response(1, 10, 20))
            self.assertEqual((1, 10, 20), totals_from(after_clear))

    def test_corrupt_state_falls_back_to_current_modem_values(self):
        with tempfile.TemporaryDirectory() as directory:
            state_file = Path(directory) / "traffic.json"
            state_file.write_text("not-json", encoding="utf-8")

            store = TrafficStatsStore(str(state_file))
            rewritten = store.rewrite_query_response(response(7, 70, 80))
            self.assertEqual((7, 70, 80), totals_from(rewritten))

    def test_invalid_json_root_falls_back_to_current_modem_values(self):
        with tempfile.TemporaryDirectory() as directory:
            state_file = Path(directory) / "traffic.json"
            state_file.write_text("[]", encoding="utf-8")

            store = TrafficStatsStore(str(state_file))
            rewritten = store.rewrite_query_response(response(8, 81, 82))
            self.assertEqual((8, 81, 82), totals_from(rewritten))

    def test_unrelated_response_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            store = TrafficStatsStore(str(Path(directory) / "traffic.json"))
            raw_response = "^OTHER: 1,2,3\r\nOK"
            self.assertEqual(raw_response, store.rewrite_query_response(raw_response))

    def test_disabled_store_is_a_passthrough(self):
        with tempfile.TemporaryDirectory() as directory:
            state_file = Path(directory) / "traffic.json"
            raw_response = response(9, 90, 100)
            store = TrafficStatsStore(str(state_file), enabled=False)

            self.assertEqual(raw_response, store.rewrite_query_response(raw_response))
            self.assertFalse(store.flush(force=True))
            self.assertFalse(state_file.exists())


if __name__ == "__main__":
    unittest.main()
