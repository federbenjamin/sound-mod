# sound-mod

<!-- >>> git-workflow (generated block; do not edit by hand) -->
## Git workflow

- `main` changes only through a PR, squash-merged.
<!-- <<< git-workflow -->

## Project state

- 2026-10-24: not launched; no release yet. The author is the one user, running it on their own Mac; no real data beyond local state files. Retires at the first version tag.
- 2026-10-23: the daemon's System Audio Recording grant is given on the author's Mac (Apple Development signing, so it survives rebuilds). Never run a tap from any other identity or before `capturePermission()` says authorized: an unanswered prompt wedges coreaudiod until `sudo killall coreaudiod`. Retires when the install grants the permission itself without that risk.

## Layout

- `daemon/`: Swift package. `Main.swift` is the entry and its command-line modes; `Daemon.swift` orchestrates; `Playback.swift` owns one attach's audio and is the one entry for transport commands; `Timeline.swift` (rings), `Player.swift` (the IO thread), `SeparationWorker.swift` + `Separator.swift` (the separator process), `NowPlaying.swift` (the Now Playing claim and the media keys), `StatusMenu.swift` (the menu bar item, AppKit). Pure and tested: `State.swift`, `Stems.swift`, `Schedule.swift`, `Transport.swift`, `SeparatorProtocol.swift`, `Menu.swift`, `MediaKeys.swift`. `Audio.swift` touches Core Audio. `Simulate.swift` runs everything but Core Audio offline.
- `separator/`: the Python HTDemucs separator (`uv` project); tests in `separator/test_separator.py`.
- `docs/design/stem-player.md`: the design and its choices.
- Session sources, two interchangeable writers of the same session files (`contract/README.md`):
  - `claude-plugin/`: the Claude Code hooks module; tests in `claude-plugin/hooks/*.test.ts` run with `claude plugin test claude-plugin`.
  - `herdr-plugin/`: the herdr plugin, a bridge from herdr's agent states (system Python 3.9, standard library only); tests run with `/usr/bin/python3 -m unittest discover -s herdr-plugin`.
- `contract/`: the state-file shapes, the separator pipe protocol, and the fixtures every side decodes.
- `install.sh`: the one install command (README §Install).
