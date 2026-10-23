# stemmix

Music that fills in with the number of Claude Code sessions working right now.

A song from Spotify or Apple Music plays as N bands. With k sessions working you hear the lowest k bands: one session is music through a wall, N sessions is the full mix, zero is silence. When sessions finish and hand back to you, the room goes quiet without you looking.

Two parts:

- **The daemon** (`daemon/`, Swift, a launchd user agent `com.benjaminfeder.stemmix`): taps the player's audio output with a Core Audio process tap (muted at the source while tapped), runs it through a low-pass whose cutoff rises with the working count, and plays the result on the default output. While no Claude session is open the tap is released and the player sounds normal.
- **The plugin** (`plugin/`, a Claude Code hooks module): writes whether this session's main turn is running and not waiting on you (a permission dialog, a question, a plan to approve).

The two meet in `~/.local/state/stemmix/`; the shape is in `contract/README.md`.

## Install

```
./install.sh
```

Builds and signs the daemon with the Apple Development identity in the keychain, installs the launchd agent, and prints the plugin registration lines if `~/.claude/settings.json` does not enable `stemmix@sound-mod` yet. The first time a session works while music plays, macOS asks once to allow Stemmix "System Audio Recording". Click Allow. Nothing else can grant it (not SSH, not a terminal-launched binary: TCC attributes those to the terminal and refuses without a prompt).

Settings for the plugin, in `/config` or `pluginConfigs.stemmix.options`: `tracks` (N, default 5) and `player` (`spotify` or `music`).

## Reading what it did

```
tail -f ~/.local/state/stemmix/stemmix.log
```

One line per event: `start`, `attach` (player, tap format, output device), `detach reason=…`, `count working=… live=… k=… cutoff=…`, and `session id=… working=…` as the plugin's writes land. The daemon's own stdout and stderr: `daemon.out.log` and `daemon.err.log` beside it.

## Checks

```
swift test --package-path daemon
claude plugin validate plugin
claude plugin test plugin
```

## Known limits

- Playback is not paused at zero sessions: the player keeps going silently. Pausing needs a second permission (Automation) and is not built.
- Apple Music streamed (FairPlay) tracks are reported capturable by a process tap but were not verified here.
- One Mac: the count is of sessions on the machine the daemon runs on.
