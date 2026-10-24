# Design: the stem player

Status: approved to build 2026-10-23 (the user: "Write up a design, for each major choice come up with 3 options, synthesize the best one, run a simple plan review, then build it").

## What changes

Today the daemon taps Spotify, runs it through a low-pass filter whose cutoff rises with the number of working sessions, and plays it straight back. That changes in two ways.

1. **Instrument stems replace the filter.** HTDemucs splits the music into drums, bass, other and vocals. k working sessions of N unmute the first stems in that order. N working sessions play the exact original.
2. **The daemon becomes a player, not a filter.** Spotify keeps playing, muted, and everything it plays is recorded into memory. What you hear comes from a play cursor that moves through that recording. Pausing stops the cursor at once while recording goes on. Resuming plays from where you paused, so the daemon can be minutes behind Spotify. Skipping jumps the cursor.

Measured on this Mac (M5 Pro), from the offline tests in this session:

| | Mr. Brightside | Blinding Lights |
|---|---|---|
| One 7.8 s window | 0.15 s | 0.14 s |
| GPU busy at a 1 s hop | 15% | 14% |
| Live vs whole-clip agreement at 1.5 s right context (drums / bass / other / vocals, dB) | 19.2 / 18.0 / 12.7 / 20.2 | 25.3 / 23.6 / 10.0 / 24.6 |
| Delay from capture to sound | about 2.6 s | about 2.6 s |

## Choices

Each choice lists three options and the pick. The pick names what it took from the others.

### 1. What runs the separation model

| Option | For | Against |
|---|---|---|
| A. A Python process running `demucs-mlx`, spawned by the daemon | Measured above: 0.14 s per window, quality known. Already installed and working. | A Python environment in the install command. One more process to supervise. |
| B. `demucs-mlx-swift` inside the daemon | One process, no Python. | MLX Swift's Metal shaders cannot be built by `swift build`, so the install moves to `xcodebuild`. The package is weeks old and untested here. |
| C. HTDemucs converted to Core ML | Apple-native. | The only published port is verified on CPU only; CPU HTDemucs runs about 6x real time on an M4 Max, too tight for a 1 s hop. GPU/ANE risks FP16 overflow by its own card. |

**Pick: A.** It is the only one measured on this Mac. The daemon talks to it through one small protocol (choice 2), so swapping in B later changes one file.

### 2. How the daemon and the separator talk

| Option | For | Against |
|---|---|---|
| A. Stateless request/response over the child's stdin/stdout: each request carries one whole 7.8 s window and says which slice to return | The separator holds no state, so a restart loses nothing. All audio and all scheduling stay in the daemon, in Swift, under test. About 3 MB/s through a pipe. | Sends each second of audio about 8 times. |
| B. Stateful stream: the daemon sends only new audio; the separator keeps its own window and decides the slices | Less data. | Two copies of the timeline, in two languages, that must agree. A seek needs a reset message. |
| C. Shared memory ring with semaphores | No copies. | Hand-written synchronisation across two processes and languages for a 3 MB/s stream that a pipe carries easily. |

**Pick: A.** A frame is a 4-byte little-endian header length, a JSON header, then raw float32. The header shapes are fixtures in `contract/`, decoded by both sides' tests.

### 3. Where the audio lives (the intermediate player)

| Option | For | Against |
|---|---|---|
| A. A fixed delay line: output is the capture delayed by about 2.6 s; pause mutes | Simplest. | Pause can't resume where you paused, which is what was asked for. |
| B. A timeline: recorded mix in a ring addressed by absolute frame number, stems computed just ahead of a play cursor, cursor moves only while playing | Instant pause and resume, time-shift, skip inside the buffer. Separation runs only for what will be played. | A ring with a cursor, a recording head and a stems frontier to keep consistent. |
| C. Separate whole songs ahead and keep them on disk | Best quality (full context). | Spotify only plays at real-time speed, so nothing can get ahead faster than real time anyway. It writes Spotify audio to disk. |

**Pick: B**, with C's quality gain where it is free: when the cursor is behind the recording head, the separator looks up to 2.5 s past each slice instead of 1.5 s.

### 4. How the mix is built from stems

| Option | For | Against |
|---|---|---|
| A. Play the model's four stems | Straightforward. | All four together differ from the original (the stems sum to within 28 to 34 dB of it). |
| B. Model drums, bass and vocals; "other" is the recording minus those three | All four on is the original exactly. Drums+bass+other is exactly "the song minus vocals". One stem less to store. | Separation errors in the first three land in "other". |
| C. Six stems (`htdemucs_6s`) | More steps. | Guitar and piano scored 5 to 8 dB live; the model's own docs say piano does not work well. |

**Pick: B.**

### 5. Which stems k sessions hear

| Option | For | Against |
|---|---|---|
| A. The first min(k, 4) stems; N is ignored | Simple. | Drops the user's N setting. |
| B. The first ceil(4k / N) stems, so N sessions play the whole song, with 0.4 s gain ramps | Keeps N meaningful. Any working session is audible. | With N above 4, two counts can sound the same. |
| C. Every stem at gain k/N | Smooth. | It's a volume knob, not tracks. |

**Pick: B.** Order: drums, bass, other, vocals (the order the user listened to). The default N becomes 4, so one session is one stem.

### 6. Pause and play controls

| Option | For | Against |
|---|---|---|
| A. The daemon becomes the Now Playing app (MPRemoteCommandCenter), so media keys, Control Center and headphones control it | The keyboard controls the player that is actually sounding. | Whether macOS routes the keys to the daemon while Spotify also plays is untested. |
| B. Follow Spotify's own state through its `com.spotify.client.PlaybackStateChanged` notification (no permission needed) | Pausing in Spotify's window stops the sound immediately instead of 2.6 s later. | Can't resume a time-shift, because a paused Spotify records nothing. |
| C. A command, `stemmix --control pause|play|toggle|next|previous|live`, over a distributed notification | Scriptable, and testable without pressing keys. | Not where anyone's hands are. |

**Pick: all three, through one entry point.** Each source becomes a `TransportCommand` handed to one function, so behaviour can't differ by source. A acts while the daemon is attached (it releases Now Playing on detach). B keeps "pause stops at once" true even if A never gets the keys. C is for tests and hotkeys.

### 7. Songs: skips and track changes

| Option | For | Against |
|---|---|---|
| A. No track knowledge: "next" jumps to the live edge | Simplest. | Can't skip one song inside a long buffer. |
| B. Record each track change from Spotify's notification as a boundary on the timeline. "Next" jumps to the next boundary in the buffer, else to the live edge; "previous" jumps to the start of the current song. A change made in Spotify (a skip, not a song ending) while behind jumps the cursor to it. Now Playing shows the title and artist from the boundary under the cursor. | Skips behave like a player's. No new permission. | Telling a skip from a natural song end is a heuristic: elapsed time vs the song's duration. |
| C. Control Spotify itself through AppleScript | "Next" at the live edge skips the song in Spotify. | Needs the Automation permission: a new prompt, which needs the user present. |

**Pick: B.** C stays an open question for the user (`afk-questions.md` Q1).

### 8. Threads and memory

| Option | For | Against |
|---|---|---|
| A. Lock-free single-writer rings: the IO thread alone writes the recording and moves the cursor; the separation worker alone writes stems; each publishes one atomic index | The audio thread never waits. | Atomics need macOS 15 (`Synchronization`); the package moves from 14.2. |
| B. One lock around the shared state | Familiar. | The IO thread can wait behind a 1 MB stem copy. |
| C. Hand every change to a serial queue | No locks in user code. | A dispatch hop from a real-time thread is not allowed to block, and it allocates. |

**Pick: A.** This Mac runs macOS 26. Memory: the recording ring holds 10 minutes (230 MB at 48 kHz stereo float), allocated on attach and freed on detach. If you're paused longer than that, the oldest audio is dropped and the cursor moves up to the oldest kept. The stems ring holds 20 s.

### 9. The separator's lifetime and install

| Option | For | Against |
|---|---|---|
| A. The daemon spawns it on attach, stops it on detach, and restarts it with a back-off if it dies | Lives only while used; one supervisor. | A cold start (Python, MLX, weights) on each attach, about 2 to 3 s. |
| B. Its own launchd agent, always on | Warm. | About 1 GB resident all day for an idle feature. |
| C. A new process per request | No supervision. | A cold start every second. |

**Pick: A.** `install.sh` builds the Python environment with `uv` under `~/.local/share/stemmix/venv` and runs the separator's self-test once, which downloads the weights to `~/.cache/demucs-mlx`. Until the first slice arrives the cursor waits, so an attach has about 3 to 5 s of silence. While the separator is down the player waits too, and the log says why.

## Behaviour summary

- Attached (a live session and the player outputting): Spotify is muted at the source. The recording runs. The cursor starts at the recording head and plays once stems exist (about 2.6 s).
- k = 0: the cursor keeps moving, gain 0. Unchanged from today.
- Pause (key, Spotify, or command): a 10 ms fade, then the cursor stops. The recording continues.
- Play: from the cursor.
- Next: the next song start in the buffer, else the live edge. Previous: the start of the current song if it's buffered.
- Detach (no live session for 60 s): the tap, the recording and the separator go away, and Spotify sounds normal at its own position. Any time-shift is lost.

## Not built

- Skipping in Spotify from the keyboard at the live edge (choice 7C; open question Q1).
- Apple Music track boundaries: its `com.apple.Music.playerInfo` notification is parsed with the same shape, but nothing here was verified with Apple Music.

## Proof

- Swift unit tests: k to stems, the separation schedule, crossfade ramps, the timeline rings including wrap and the overflow drop, transport (pause fade, seek, next/previous), notification parsing and skip detection, protocol frames against the `contract/` fixtures.
- Python test: the separator returns the requested slice in the right shape, and drums+bass+vocals+other adds back up to the input.
- Offline end-to-end: `stemmix --simulate <recording.f32> <out.f32> <script>` runs the real timeline, worker, separator and render code on the Blinding Lights recording with a scripted k, pause and resume. Check: k = 4 is the input delayed (exact), and a pause produces silence then resumes at the same sample.
- Live: the installed daemon with Spotify playing and a scripted session file. The log shows attach, separator ready, steady lead, no underruns, an output level, and pause/play/next by command.

## Plan review (2026-10-23), applied

One read by a plan-review agent before building. Each finding and what changed:

1. A separator that dies mid-write raises SIGPIPE, whose default kills the daemon with the tap running, which wedges coreaudiod. **The daemon ignores SIGPIPE, every separator read and write has a timeout, and a hung or dead separator is killed and restarted.**
2. The tap runs at 48 kHz; HTDemucs takes 44.1 kHz. **The separator resamples both ways with soxr (HQ)**, inside the timed request, so the per-window figure in the log includes it. The residual "other" stays at the tap's rate, so all-on remains the original.
3. The last F samples of a slice change when the next slice lands. **The published stems frontier is the slice end minus F; ring slots behind the frontier never change until the next seek.**
4. Tap creation had its permission check at three call sites. **The preflight moves into `ProcessTap.init`, which throws when not authorized.** `--simulate` and `--control` never construct a tap.
5. The Python sum test now sums the model's own four stems (within 20 dB); the exact all-on check belongs to `--simulate` at k = 4.
6. Nothing proved Now Playing. **The daemon runs as an accessory NSApplication; the media-key route is a hand check for the user** (press play/pause with Spotify playing; the log names each command's source). Choice 6B covers pause if the keys never arrive.
7. N = 4 changes at all five places that say 5: `Config.swift`, `plugin.json`, `register.ts`, `contract/config.json`, README.
8. The macOS 15 floor goes into both `Package.swift` and `Info.plist`.
9. **The recording ring is touched once off the IO thread before the tap starts**, so the IO thread never takes a first-write page fault.
10. The separator writes frames to a private copy of stdout and points fd 1 at stderr.
11. Right context when behind is capped at **2.5 s** (measured), not 3 s.
