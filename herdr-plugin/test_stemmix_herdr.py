import json
import os
import tempfile
import unittest

import stemmix_herdr as bridge

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT = os.path.join(HERE, "..", "contract")


class BridgeTests(unittest.TestCase):
    def test_every_agent_pane_is_a_session_and_only_working_counts(self):
        with open(os.path.join(HERE, "fixtures", "agent-list.json")) as f:
            agents = json.load(f)["result"]["agents"]

        sessions = bridge.sessions_from_agents(agents)

        self.assertEqual(sessions, {
            "0b8c6a3e-1f2d-4c5b-9a7e-2d3f4a5b6c7d": True,
            "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b": False,
            "herdr-w2-p1": True,
            "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d": False,
        })

    def test_sync_writes_the_contract_shape_and_removes_sessions_that_went_away(self):
        with open(os.path.join(CONTRACT, "session.json")) as f:
            contract_keys = set(json.load(f))
        with tempfile.TemporaryDirectory() as d:
            written = bridge.sync(d, {"a": True, "b": False}, set(), 1000)
            with open(os.path.join(d, "a.json")) as f:
                self.assertEqual(set(json.load(f)), contract_keys)

            bridge.sync(d, {"a": False}, written, 3000)

            self.assertEqual(sorted(os.listdir(d)), ["a.json"])
            with open(os.path.join(d, "a.json")) as f:
                self.assertEqual(json.load(f), {"working": False, "updatedAt": 3000})

    def test_read_config_takes_every_setting_and_defaults_the_rest(self):
        with open(os.path.join(CONTRACT, "config.json")) as f:
            contract_keys = set(json.load(f))
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
            f.write('tracks = 6\nmode = "both"  # comment\nmuffling_max = 5.5\nplayer = 7\n')
            path = f.name
        try:
            config = bridge.read_config(path)
        finally:
            os.remove(path)

        self.assertEqual(set(config), contract_keys)
        self.assertEqual(config, {"tracks": 6, "player": "spotify", "mode": "both", "muffling_max": 5.5, "muffling_min": 0})


if __name__ == "__main__":
    unittest.main()
