"""stemmix for herdr: writes each herdr agent pane's state to the stemmix daemon's session files.

Every top-level agent pane herdr detects (Claude, Codex, ...) is one session; it counts as working while herdr
reports `working`. `blocked` (a permission or question form on screen), `idle` and `done` do not. The panes of
the enabled saved machines (`herdr machine list`) named in MACHINES_FILE count too, asked through herdr's own
forwarding; with no such file no other machine is contacted, and a machine that does not answer counts as no
sessions. The file shape is contract/README.md in the stemmix repo. Runs on
macOS's own Python 3.9, standard library only.
"""
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time

STATE_DIR = os.path.expanduser("~/.local/state/stemmix")
SESSIONS_DIR = os.path.join(STATE_DIR, "sessions")
PIDFILE = os.path.join(STATE_DIR, "herdr-bridge.pid")
LOG_FILE = os.path.join(STATE_DIR, "herdr-bridge.log")
MACHINES_FILE = os.path.join(STATE_DIR, "herdr-machines.json")  # a JSON list of saved-machine labels or ids to count
SOCKET_PATH = os.environ.get("HERDR_SOCKET_PATH") or os.path.expanduser("~/.config/herdr/herdr.sock")
HERDR = os.environ.get("HERDR_BIN_PATH", "herdr")
PLUGIN_ID = "stemmix"

HEARTBEAT_SECS = 2  # the daemon treats a session file older than 6 s as gone
MACHINES_REFRESH_SECS = 30  # how often the saved-machine list is re-read
MACHINE_TIMEOUT_SECS = 8  # one forwarded agent list; a machine slower than this is treated as not answering
REMOTE_STALE_MS = 15_000  # a machine's last answer older than this counts as no sessions (one forwarded call takes seconds)
MAX_FAILS = 30  # herdr unreachable this many beats in a row: the server is gone, so stop
WAKE_EVENTS = ["pane.agent_status_changed", "pane.agent_detected", "pane.closed", "pane.exited"]

wake = threading.Event()


def session_id(agent, machine=None):
    """The agent's own session id when herdr knows it, so a session reported by both stemmix's Claude plugin
    and this bridge is one file; otherwise one id per pane, with the machine's id in front for a saved machine,
    since pane ids repeat per herdr server."""
    session = agent.get("agent_session") or {}
    value = session.get("value")
    if value and re.fullmatch(r"[A-Za-z0-9._-]+", value):
        return value
    pane = re.sub(r"[^A-Za-z0-9._-]", "-", agent["pane_id"])
    return f"herdr-{machine}-{pane}" if machine else "herdr-" + pane


def sessions_from_agents(agents, machine=None):
    """{session id: working} for every agent pane herdr lists, on this machine or on saved machine `machine`."""
    return {session_id(a, machine): a.get("agent_status") == "working" for a in agents}


def merge_sessions(local, remotes, now_ms, stale_ms=REMOTE_STALE_MS):
    """The local sessions plus every saved machine's, `remotes` being {machine id: (sessions, answered at ms)};
    an answer older than `stale_ms` is left out, so a machine that stopped answering stops counting."""
    merged = {}
    for sessions, at in remotes.values():
        if now_ms - at < stale_ms:
            merged.update(sessions)
    merged.update(local)
    return merged


def wanted_machines(path=MACHINES_FILE):
    """The labels or ids listed in `path`; [] when the file is missing or is not a JSON list of strings."""
    try:
        with open(path) as f:
            wanted = json.load(f)
    except (OSError, ValueError):
        return []
    if not isinstance(wanted, list):
        return []
    return [w for w in wanted if isinstance(w, str)]


def opted_in(machines, wanted):
    """The enabled saved machines whose id or label is in `wanted`, as [(id, label)]."""
    return [(m["id"], m.get("label", m["id"])) for m in machines
            if m.get("enabled") and (m["id"] in wanted or m.get("label") in wanted)]


def saved_machines():
    """[(id, label)] of the enabled saved machines MACHINES_FILE names; [] without asking herdr when it names
    none, and [] when herdr does not answer."""
    wanted = wanted_machines()
    if not wanted:
        return []
    try:
        out = subprocess.run([HERDR, "machine", "list", "--json"], capture_output=True, text=True, timeout=10)
        return opted_in(json.loads(out.stdout), wanted)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        return []


def remote_agents(machine_id):
    """herdr's agent list on a saved machine, through its own forwarding; None when the machine does not answer."""
    try:
        out = subprocess.run([HERDR, "--machine", machine_id, "agent", "list"], capture_output=True, text=True, timeout=MACHINE_TIMEOUT_SECS)
        if out.returncode != 0:
            return None
        return (json.loads(out.stdout).get("result") or {}).get("agents", [])
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


remotes_lock = threading.Lock()
remotes = {}  # machine id: (sessions, answered at ms)


def poll_machines():
    """Keeps `remotes` current: re-reads the saved machines every MACHINES_REFRESH_SECS and asks each one for its
    agents every beat. Logs a machine once when it stops or starts answering."""
    machines, machines_at, answering = [], 0, {}
    while True:
        if time.time() - machines_at >= MACHINES_REFRESH_SECS:
            machines, machines_at = saved_machines(), time.time()
            with remotes_lock:
                for gone in set(remotes) - {m for m, _ in machines}:
                    del remotes[gone]
        for machine_id, label in machines:
            agents = remote_agents(machine_id)
            if agents is None:
                if answering.get(machine_id, True):
                    log(f"machine {label}: not answering; counting no sessions there")
                answering[machine_id] = False
                continue
            if not answering.get(machine_id, False):
                log(f"machine {label}: answering, {len(agents)} agent panes")
            answering[machine_id] = True
            with remotes_lock:
                remotes[machine_id] = (sessions_from_agents(agents, machine_id[:8]), time.time() * 1000)
        time.sleep(HEARTBEAT_SECS)


def write_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f, separators=(",", ":"))
    os.replace(tmp, path)


def sync(sessions_dir, sessions, previous, now_ms):
    """Writes every current session's file and removes the files of sessions that went away. Returns the ids
    written, for the next call."""
    os.makedirs(sessions_dir, exist_ok=True)
    for sid, working in sessions.items():
        write_json(os.path.join(sessions_dir, sid + ".json"), {"working": working, "updatedAt": now_ms})
    for sid in set(previous) - set(sessions):
        try:
            os.remove(os.path.join(sessions_dir, sid + ".json"))
        except OSError:
            pass
    return set(sessions)


def request(method, params=None):
    """One request over herdr's socket; the result, or None when herdr does not answer."""
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect(SOCKET_PATH)
            sock.sendall((json.dumps({"id": PLUGIN_ID, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf).get("result")
    except (OSError, ValueError):
        return None


def listen():
    """Wakes the main loop on every agent state change; reconnects with backoff, and the heartbeat covers gaps."""
    subscribe = {"id": PLUGIN_ID, "method": "events.subscribe",
                 "params": {"subscriptions": [{"type": t} for t in WAKE_EVENTS]}}
    delay = 1
    while True:
        try:
            with socket.socket(socket.AF_UNIX) as sock:
                sock.connect(SOCKET_PATH)
                sock.sendall((json.dumps(subscribe) + "\n").encode())
                delay = 1
                while sock.recv(65536):
                    wake.set()
        except OSError as e:
            log(f"event socket: {e}")
        time.sleep(delay)
        delay = min(delay * 2, 30)


def log(text):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {text}", file=sys.stderr, flush=True)


def owns_pidfile():
    try:
        with open(PIDFILE) as f:
            return f.read().strip() == str(os.getpid())
    except OSError:
        return False


def detach():
    """Outlives whatever started it; output goes to the log, since herdr discards a startup command's."""
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    try:
        os.setsid()
    except OSError:
        pass
    sys.stdout = sys.stderr = open(LOG_FILE, "a", buffering=1)


def main():
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    detach()
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    log(f"start pid={os.getpid()} socket={SOCKET_PATH}")
    written = set()

    def stop(*_):
        sync(SESSIONS_DIR, {}, written, time.time() * 1000)
        log("stop: session files removed")
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    threading.Thread(target=listen, daemon=True).start()
    threading.Thread(target=poll_machines, daemon=True).start()
    fails = 0
    last_counts = None
    while owns_pidfile():
        wake.clear()
        result = request("agent.list")
        if result is None:
            fails += 1
            if fails >= MAX_FAILS:
                log("herdr not answering; exiting")
                break
        else:
            fails = 0
            now_ms = time.time() * 1000
            local = sessions_from_agents(result.get("agents", []))
            with remotes_lock:
                remote = dict(remotes)
            sessions = merge_sessions(local, remote, now_ms)
            written = sync(SESSIONS_DIR, sessions, written, now_ms)
            counts = (sum(sessions.values()), len(sessions))
            if counts != last_counts:
                here = f"here {sum(local.values())}/{len(local)}"
                there = sum(len(s) for s, _ in remote.values())
                log(f"agents working={counts[0]} live={counts[1]} ({here}, saved machines {len(sessions) - len(local)}/{there})")
                last_counts = counts
        wake.wait(HEARTBEAT_SECS)
    # Taken over by a newer start: it owns the files now. Only a bridge that lost herdr removes them.
    if fails >= MAX_FAILS:
        sync(SESSIONS_DIR, {}, written, time.time() * 1000)


if __name__ == "__main__":
    main()
