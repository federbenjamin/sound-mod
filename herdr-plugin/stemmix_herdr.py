"""stemmix for herdr: writes each herdr agent pane's state to the stemmix daemon's session files.

Every top-level agent pane herdr detects (Claude, Codex, ...) is one session; it counts as working while herdr
reports `working`. `blocked` (a permission or question form on screen), `idle` and `done` do not. The file shape
is contract/README.md in the stemmix repo. Runs on macOS's own Python 3.9, standard library only.
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
CONFIG_FILE = os.path.join(STATE_DIR, "config.json")
PIDFILE = os.path.join(STATE_DIR, "herdr-bridge.pid")
LOG_FILE = os.path.join(STATE_DIR, "herdr-bridge.log")
SOCKET_PATH = os.environ.get("HERDR_SOCKET_PATH") or os.path.expanduser("~/.config/herdr/herdr.sock")
HERDR = os.environ.get("HERDR_BIN_PATH", "herdr")
PLUGIN_ID = "stemmix"

HEARTBEAT_SECS = 2  # the daemon treats a session file older than 6 s as gone
MAX_FAILS = 30  # herdr unreachable this many beats in a row: the server is gone, so stop
WAKE_EVENTS = ["pane.agent_status_changed", "pane.agent_detected", "pane.closed", "pane.exited"]
DEFAULTS = {"tracks": 4, "player": "spotify", "mode": "instruments", "muffling_max": 7, "muffling_min": 0}
NUMBER_KEYS = {"tracks": int, "muffling_max": float, "muffling_min": float}

wake = threading.Event()


def session_id(agent):
    """The agent's own session id when herdr knows it, so a session reported by both stemmix's Claude plugin
    and this bridge is one file; otherwise one id per pane."""
    session = agent.get("agent_session") or {}
    value = session.get("value")
    if value and re.fullmatch(r"[A-Za-z0-9._-]+", value):
        return value
    return "herdr-" + re.sub(r"[^A-Za-z0-9._-]", "-", agent["pane_id"])


def sessions_from_agents(agents):
    """{session id: working} for every agent pane herdr lists."""
    return {session_id(a): a.get("agent_status") == "working" for a in agents}


def read_config(path):
    """The settings from the plugin's config.toml (one-line `key = value`; Python 3.9 has no tomllib): tracks,
    player, mode, muffling_max, muffling_min; a key left out keeps its default."""
    config = dict(DEFAULTS)
    try:
        with open(path) as f:
            for line in f:
                m = re.fullmatch(r'\s*(tracks|player|mode|muffling_max|muffling_min)\s*=\s*(\d+(?:\.\d+)?|"[^"]*")\s*(#.*)?', line.rstrip("\n"))
                if m:
                    key, raw = m.group(1), m.group(2)
                    if key in NUMBER_KEYS and not raw.startswith('"'):
                        config[key] = NUMBER_KEYS[key](raw)
                    elif key not in NUMBER_KEYS and raw.startswith('"'):
                        config[key] = raw.strip('"')
    except OSError:
        pass
    return config


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


def plugin_config_path():
    try:
        out = subprocess.run([HERDR, "plugin", "config-dir", PLUGIN_ID], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return os.path.join(out, "config.toml") if out else None


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
    config_path = plugin_config_path()
    threading.Thread(target=listen, daemon=True).start()
    fails = 0
    last_config = None
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
            sessions = sessions_from_agents(result.get("agents", []))
            written = sync(SESSIONS_DIR, sessions, written, time.time() * 1000)
            counts = (sum(sessions.values()), len(sessions))
            if counts != last_counts:
                log(f"agents working={counts[0]} live={counts[1]}")
                last_counts = counts
            config = read_config(config_path) if config_path else dict(DEFAULTS)
            if config != last_config:
                write_json(CONFIG_FILE, config)
                last_config = config
        wake.wait(HEARTBEAT_SECS)
    # Taken over by a newer start: it owns the files now. Only a bridge that lost herdr removes them.
    if fails >= MAX_FAILS:
        sync(SESSIONS_DIR, {}, written, time.time() * 1000)


if __name__ == "__main__":
    main()
