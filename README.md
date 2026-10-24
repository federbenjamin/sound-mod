# stemmix

Music that fills in with the number of Claude Code sessions working right now.

A song from Spotify or Apple Music plays as 4 instrument stems: drums, bass, other, vocals. With k sessions working out of N you hear the first ceil(4k/N) of them: one session is just the drums, N sessions is the whole song, zero is silence. When sessions finish and hand back to you, the room goes quiet without you looking.

Three parts, and you pick the third:

- **The daemon** (`daemon/`, Swift, a launchd user agent `com.benjaminfeder.stemmix`): taps the player's audio with a Core Audio process tap (the player is muted at the source while tapped), records it into memory, and plays it back as stems from a play cursor of its own. Pause stops the cursor at once while recording continues, so play resumes where you paused; next and previous move between songs in the buffer. While no session is open the tap is released and the player sounds normal.
- **The separator** (`separator/`, Python): HTDemucs through `demucs-mlx` on the GPU. The daemon starts it while attached and sends it one 7.8 s window a second over a pipe; the stems play about 3 s behind the music.
- **A session source**, one of:
  - **The Claude Code plugin** (`claude-plugin/`): each Claude Code session reports whether its main turn is running and not waiting on you (a permission dialog, a question, a plan to approve). Counts Claude Code sessions in any terminal.
  - **The herdr plugin** (`herdr-plugin/`): reports every top-level agent pane in [herdr](https://herdr.dev) (Claude Code, Codex, and any agent herdr detects); a pane counts while herdr shows it `working`, and not while it is `blocked` on you, `idle` or `done`. Counts only sessions running inside herdr.

  Install one. Both write the same session files, keyed by the agent's session id where herdr knows it, so a Claude session reported by both is still one session.

The daemon and the session sources meet in `~/.local/state/stemmix/`; the daemon and the separator meet on a pipe. Both shapes are in `contract/README.md`. The design and its trade-offs: `docs/design/stem-player.md`.

## Install

```
./install.sh
```

Needs `uv`. Needs `uv`. Builds the separator's Python environment in `~/.local/share/stemmix/venv` and runs its self-test (the first run downloads the model weights to `~/.cache/demucs-mlx`), builds and signs the daemon with the Apple Development identity in the keychain, and installs the launchd agent.

Then install one session source:

- Claude Code: add this repo as a plugin marketplace and enable `stemmix@sound-mod` (`/plugin marketplace add <path or owner/repo>`, then `/plugin install stemmix@sound-mod`). Settings, in `/config`: `tracks` (N, default 4) and `player` (`spotify` or `music`).
- herdr: `herdr plugin link <this repo>/herdr-plugin` (or `herdr plugin install <owner>/sound-mod/herdr-plugin` from GitHub). herdr starts it with its server; to start it now, `herdr plugin action invoke restart --plugin stemmix`. Settings: `tracks = 4` and `player = "spotify"` in `config.toml` in the folder `herdr plugin config-dir stemmix` prints. Needs macOS's own `/usr/bin/python3` (Xcode Command Line Tools).

The first time a session works while music plays, macOS needs Stemmix allowed under System Settings > Privacy & Security > Screen & System Audio Recording > **System Audio Recording Only**. The daemon never taps without it, so it never raises the prompt itself; nothing else can grant it (not SSH, not a terminal-launched binary: TCC attributes those to the terminal).

## Controls

While attached, the daemon is the system's Now Playing app, so the keyboard's media keys, Control Center and headphone buttons reach it: play/pause, next (the next song already in the buffer, else back to live), previous (the start of this song, or the one before within its first 3 s). Pausing or playing in Spotify itself does the same to the daemon at once.

From a terminal or a hotkey tool:

```
~/Applications/Stemmix.app/Contents/MacOS/stemmix --control pause|play|toggle|next|previous|live
```

## Reading what it did

```
tail -f ~/.local/state/stemmix/stemmix.log
```

One line per event: `start`, `attach`, `detach reason=…`, `count working=… stems=…`, `transport source=… command=… action=…`, `player-event …` (the player's own play state and track changes), `separator ready|start-failed|request-failed`, and every 10 s a `level` line: input and output level, `state`, `behind` (how far the cursor plays behind the recording), `separated-ahead`, `waited` (silence while stems were not ready), and the separator's median time per window. The separator's own output: `separator.log` beside it. The herdr plugin logs to `herdr-bridge.log` beside it: one line per change in the working count.

## Checks

```
swift test --package-path daemon
claude plugin validate claude-plugin
claude plugin test claude-plugin
UV_PROJECT_ENVIRONMENT=~/.local/share/stemmix/venv uv run --project separator pytest separator
/usr/bin/python3 -m unittest discover -s herdr-plugin
```

`stemmix --simulate <recording.f32> <out.f32> <script.json>` runs the real timeline, separator and render code on a recording with scripted stem counts and commands, without Core Audio (set `STEMMIX_SEPARATOR` to `separator/stemmix_separator.py`).

## Known limits

- "Next" at the live edge cannot skip the song in Spotify: that needs the Automation permission, not built.
- Whether macOS hands the media keys to the daemon while Spotify also plays has not been checked by hand yet. If it does not, the keys go to Spotify, and following Spotify's own pause still stops the sound at once.
- The music keeps playing silently at zero sessions; it is not paused.
- Apple Music streamed (FairPlay) tracks and its track notifications were not verified here.
- One Mac: the count is of sessions on the machine the daemon runs on.
- herdr reads an agent's state from its terminal (title and on-screen forms), so its `working` can lag a moment behind the agent; the Claude Code plugin reports from inside the session.
