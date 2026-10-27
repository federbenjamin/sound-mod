import os
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "session-source.sh")
REPO = os.path.dirname(HERE)

# A fake CLI: logs each call, answers `list` from a file the test writes, and records link/install in that file.
FAKE = """#!/bin/bash
echo "$(basename "$0") $*" >> "$FAKE_DIR/calls.log"
name=$(basename "$0")
case "$*" in
  "plugin list") cat "$FAKE_DIR/$name-plugins" 2>/dev/null ;;
  "plugin marketplace list") cat "$FAKE_DIR/$name-marketplaces" 2>/dev/null ;;
esac
exit 0
"""


class SessionSourceTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        os.makedirs(os.path.join(self.root, "bin"))
        for name in ["claude", "herdr"]:
            path = os.path.join(self.root, "bin", name)
            with open(path, "w") as f:
                f.write(FAKE)
            os.chmod(path, 0o755)
        self.state = os.path.join(self.root, "home", ".local", "state", "stemmix")
        os.makedirs(self.state)

    def tearDown(self):
        self.dir.cleanup()

    def write(self, name, text):
        with open(os.path.join(self.root, name), "w") as f:
            f.write(text)

    def run_script(self, *args):
        env = {"PATH": os.path.join(self.root, "bin") + ":/usr/bin:/bin", "HOME": os.path.join(self.root, "home"), "FAKE_DIR": self.root}
        result = subprocess.run(["/bin/bash", SCRIPT, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        with open(os.path.join(self.root, "calls.log")) as f:
            calls = [line.strip() for line in f if " list" not in line]
        return result, calls

    def test_herdr_removes_the_claude_plugin_and_links_and_restarts_the_bridge(self):
        self.write("claude-plugins", "Installed plugins:\n\n  ❯ stemmix@sound-mod\n    Version: 0.2.0\n")
        self.write("claude-marketplaces", "Configured marketplaces:\n\n  ❯ sound-mod\n    Source: Directory\n")

        result, calls = self.run_script("herdr")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            "claude plugin uninstall stemmix@sound-mod",
            "claude plugin marketplace remove sound-mod",
            f"herdr plugin link {REPO}/herdr-plugin",
            "herdr plugin action invoke restart --plugin stemmix",
        ])

    def test_no_argument_keeps_the_one_installed_and_claude_stops_the_bridge(self):
        self.write("herdr-plugins", "8 plugins installed:\n- stemmix (stemmix) enabled [local:/x/herdr-plugin]\n")
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["herdr plugin action invoke restart --plugin stemmix"], "herdr alone stays herdr")

        os.remove(os.path.join(self.root, "calls.log"))
        bridge = subprocess.Popen(["/bin/sleep", "30"])
        with open(os.path.join(self.state, "herdr-bridge.pid"), "w") as f:
            f.write(str(bridge.pid))
        result, calls = self.run_script("claude")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            "herdr plugin unlink stemmix",
            f"claude plugin marketplace add {REPO}",
            "claude plugin install stemmix@sound-mod",
        ])
        deadline = time.time() + 5
        while bridge.poll() is None and time.time() < deadline:
            time.sleep(0.05)
        self.assertIsNotNone(bridge.poll(), "the running bridge was stopped")
        self.assertFalse(os.path.exists(os.path.join(self.state, "herdr-bridge.pid")))


if __name__ == "__main__":
    unittest.main()
