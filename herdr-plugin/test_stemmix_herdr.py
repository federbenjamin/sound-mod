import json
import os
import tempfile
import unittest
from unittest import mock

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

    def test_saved_machine_panes_merge_and_a_silent_machine_drops_out(self):
        with open(os.path.join(HERE, "fixtures", "agent-list.json")) as f:
            agents = json.load(f)["result"]["agents"]
        remote = bridge.sessions_from_agents(agents, machine="13be883b")

        self.assertEqual(remote, {
            "0b8c6a3e-1f2d-4c5b-9a7e-2d3f4a5b6c7d": True,
            "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b": False,
            "herdr-13be883b-w2-p1": True,
            "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d": False,
        })
        local = {"herdr-w2-p1": True, "aaaa": False}
        merged = bridge.merge_sessions(local, {"13be883b": (remote, 9_000), "stale": ({"zzzz": True}, 0)}, now_ms=10_000, stale_ms=5_000)
        self.assertEqual(merged, {**remote, **local})
        self.assertNotIn("zzzz", merged)

    def test_only_listed_enabled_machines_are_polled_and_no_list_polls_none(self):
        machines = [
            {"id": "4ed4d96b", "label": "M5 Pro", "enabled": True},
            {"id": "13be883b", "label": "M1 Pro", "enabled": True},
            {"id": "aaaa1111", "label": "Off box", "enabled": False},
        ]

        self.assertEqual(bridge.opted_in(machines, ["M5 Pro", "aaaa1111"]), [("4ed4d96b", "M5 Pro")])
        self.assertEqual(bridge.opted_in(machines, ["13be883b"]), [("13be883b", "M1 Pro")])
        self.assertEqual(bridge.opted_in(machines, []), [])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "herdr-machines.json")
            self.assertEqual(bridge.wanted_machines(path), [])
            for bad in ["not json", '{"M5 Pro": true}']:
                with open(path, "w") as f:
                    f.write(bad)
                self.assertEqual(bridge.wanted_machines(path), [])
            with open(path, "w") as f:
                json.dump(["M5 Pro", 3], f)
            self.assertEqual(bridge.wanted_machines(path), ["M5 Pro"])

    def test_no_list_never_runs_herdr(self):
        with mock.patch.object(bridge, "wanted_machines", return_value=[]), \
                mock.patch.object(bridge.subprocess, "run", side_effect=AssertionError("herdr was run")):
            self.assertEqual(bridge.saved_machines(), [])


if __name__ == "__main__":
    unittest.main()
