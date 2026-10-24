# The state contract between the plugin and the daemon

The plugin writes, the daemon reads. All paths are under `~/.local/state/stemmix/`.

| File | Shape | Written by | Read by |
| --- | --- | --- | --- |
| `config.json` | `{ "tracks": <integer N, default 4>, "player": "spotify" \| "music" }` | the plugin on `session.start` | the daemon every tick |
| `sessions/<session id>.json` | `{ "working": <bool>, "updatedAt": <ms since epoch> }` | the plugin on every state change and every 2 s | the daemon every tick |

A session file older than 6 s is dead. `working` is true while the session's main turn runs and no dialog waits on the person.

`session.json` and `config.json` in this folder are the fixtures both sides' tests decode.

# The pipe protocol between the daemon and the separator

The daemon starts `separator/stemmix_separator.py` and talks to it over its stdin and stdout. A frame is a 4-byte little-endian header length, a JSON header, then `payloadBytes` of raw little-endian float32.

| Frame | Header | Payload | Fixture |
| --- | --- | --- | --- |
| ready (separator, once at start) | `{ ready, model, stems, payloadBytes: 0 }` | none | `separator-ready.json` |
| request (daemon) | `{ id, rate, frames, keepStart, keepFrames, stems, payloadBytes }` | `frames` of interleaved stereo at `rate` | `separator-request.json` |
| reply (separator) | `{ id, stems, frames, ms, payloadBytes }` | each stem in `stems` in turn, `frames` of interleaved stereo at the request's `rate` | `separator-response.json` |
| error (separator) | `{ id, error, payloadBytes: 0 }` | none | `separator-error.json` |

The separator keeps nothing between requests. The daemon's tests (`daemon/Tests`) and the separator's (`separator/test_separator.py`) both read these fixtures.
