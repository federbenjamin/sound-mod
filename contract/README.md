# The state contract between the plugin and the daemon

The plugin writes, the daemon reads. All paths are under `~/.local/state/stemmix/`.

| File | Shape | Written by | Read by |
| --- | --- | --- | --- |
| `config.json` | `{ "tracks": <integer N>, "player": "spotify" \| "music" }` | the plugin on `session.start` | the daemon every tick |
| `sessions/<session id>.json` | `{ "working": <bool>, "updatedAt": <ms since epoch> }` | the plugin on every state change and every 2 s | the daemon every tick |

A session file older than 6 s is dead. `working` is true while the session's main turn runs and no dialog waits on the person.

`session.json` and `config.json` in this folder are the fixtures both sides' tests decode.
