# sound-mod

<!-- >>> git-workflow (generated block; do not edit by hand) -->
## Git workflow

- `main` changes only through a PR, squash-merged.
<!-- <<< git-workflow -->

## Project state

- 2026-10-23: not launched; a personal tool, one user, no real data beyond local state files. Retires when the repo is shared.
- 2026-10-23: the daemon's System Audio Recording grant has not been clicked yet on this Mac. Retires once `~/.local/state/stemmix/stemmix.log` shows an `attach` followed by a `count … gain=1` with audible output.

## Layout

- `daemon/`: Swift package; `Daemon.swift` orchestrates, `State.swift`/`Cutoff.swift`/`Filter.swift` are pure and tested, `Audio.swift` and `Mixer.swift` touch Core Audio.
- `plugin/`: the Claude Code hooks module; tests in `plugin/hooks/*.test.ts` run with `claude plugin test plugin`.
- `contract/`: the state-file shapes and the fixtures both sides decode.
- `install.sh`: the one install command (README §Install).
