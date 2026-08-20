import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[1]
CGI_SCRIPT = (
    SOURCE_ROOT
    / "at-webserver"
    / "files"
    / "www"
    / "cgi-bin"
    / "at-ws-info"
)


def find_sh():
    shell = shutil.which("sh")
    if shell:
        return shell
    if os.name == "nt":
        candidate = (
            Path(sys.executable).resolve().parents[1]
            / "native"
            / "git"
            / "usr"
            / "bin"
            / "sh.exe"
        )
        if candidate.is_file():
            return str(candidate)
    return None


class AtWsInfoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shell = find_sh()
        if not cls.shell:
            raise unittest.SkipTest("POSIX sh is unavailable")

    def run_cgi(self, port, host):
        shell_source = r'''
uci() {
    case "$2" in
        at-webserver.config.websocket_port) printf '%s\n' "$TEST_WS_PORT" ;;
        at-webserver.config.websocket_allow_wan) printf '0\n' ;;
        at-webserver.config.websocket_auth_key) return 1 ;;
        network.lan.ipaddr) printf '192.168.1.1\n' ;;
        *) return 1 ;;
    esac
}
'''
        shell_source += "\n" + CGI_SCRIPT.read_text(encoding="utf-8")
        environment = os.environ.copy()
        environment.update({"TEST_WS_PORT": port, "HTTP_HOST": host})
        environment["PATH"] = (
            str(Path(self.shell).resolve().parent)
            + os.pathsep
            + environment.get("PATH", "")
        )
        result = subprocess.run(
            [self.shell, "-c", shell_source],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=environment,
        )
        _headers, payload = result.stdout.replace("\r\n", "\n").split("\n\n", 1)
        return json.loads(payload)

    def test_leading_zero_port_falls_back_to_valid_json_number(self):
        response = self.run_cgi("08765", "router.lan")
        self.assertEqual(8765, response["data"]["port"])
        self.assertEqual("ws://router.lan:8765", response["data"]["ws_url"])

    def test_malformed_host_cannot_break_json(self):
        response = self.run_cgi("8765", 'router.lan"\\\ninvalid')
        self.assertEqual("192.168.1.1", response["data"]["host"])
        self.assertEqual("ws://192.168.1.1:8765", response["data"]["ws_url"])


if __name__ == "__main__":
    unittest.main()
