# The state contract between the session sources and the daemon

A session source writes, the daemon reads. The two sources, `claude-plugin/` and `herdr-plugin/`, write the same shapes; a session id is the agent's own session id where known (`herdr-<pane>` otherwise), so a session reported by both is one file. All paths are under `~/.local/state/stemmix/`.

| File | Shape | Written by | Read by |
| --- | --- | --- | --- |
| `sessions/<session id>.json` | `{ "working": <bool>, "updatedAt": <ms since epoch> }` | the session source on every state change and every 2 s | the daemon every tick |

A session file older than 6 s is dead. `working` is true while the session's main turn runs and no question waits on the person.

`session.json` in this folder is the fixture the daemon's and both sources' tests read. The settings (`config.json` beside the sessions) are the daemon's own, written from its menu.

# The pipe protocol between the daemon and the separator

The daemon starts `separator/stemmix_separator.py` and talks to it over its stdin and stdout. A frame is a 4-byte little-endian header length, a JSON header, then `payloadBytes` of raw little-endian float32.

| Frame | Header | Payload | Fixture |
| --- | --- | --- | --- |
| ready (separator, once at start) | `{ ready, model, stems, payloadBytes: 0 }` | none | `separator-ready.json` |
| request (daemon) | `{ id, rate, frames, keepStart, keepFrames, stems, payloadBytes }` | `frames` of interleaved stereo at `rate` | `separator-request.json` |
| reply (separator) | `{ id, stems, frames, ms, payloadBytes }` | each stem in `stems` in turn, `frames` of interleaved stereo at the request's `rate` | `separator-response.json` |
| error (separator) | `{ id, error, payloadBytes: 0 }` | none | `separator-error.json` |

The separator keeps nothing between requests. The daemon's tests (`daemon/Tests`) and the separator's (`separator/test_separator.py`) both read these fixtures.
