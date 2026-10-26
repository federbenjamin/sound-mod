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
| B. The first ceil(4k / N) stems, so N sessions play the whole song, with 1 s gain ramps | Keeps N meaningful. Any working session is audible. | With N above 4, two counts can sound the same. |
| C. Every stem at gain k/N | Smooth. | It's a volume knob, not tracks. |

**Pick: B.** Order: drums, bass, other, vocals (the order the user listened to). The default N becomes 4, so one session is one stem.

### 6. Pause and play controls

| Option | For | Against |
|---|---|---|
| A. The daemon becomes the Now Playing app (MPRemoteCommandCenter), so media keys, Control Center and headphones control it | The keyboard controls the player that is actually sounding. | macOS gives the keys to the app that last started playing, so Spotify takes them at each start; choices 11 and 18 take them back. |
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

Built later (2026-10-24), C for `next` only: with no later song in the buffer, `next` sends the player its AppleScript `next track` Apple event (Spotify `spfy`/`Next`, Music `hook`/`Next`). The cursor jumps to the recording head at once and waits there in silence; the player's track change marks the new song, and the cursor jumps to that mark and plays once its stems exist. If no track change comes within 3 s, it stops waiting and the current song plays on from the head. This replaced `next` jumping to the live edge, mid-song, when nothing was ahead. `live` still does that.

### 8. Threads and memory

| Option | For | Against |
|---|---|---|
| A. Lock-free single-writer rings: the IO thread alone writes the recording and moves the cursor; the separation worker alone writes stems; each publishes one atomic index | The audio thread never waits. | Atomics need macOS 15 (`Synchronization`); the package moves from 14.2. |
| B. One lock around the shared state | Familiar. | The IO thread can wait behind a 1 MB stem copy. |
| C. Hand every change to a serial queue | No locks in user code. | A dispatch hop from a real-time thread is not allowed to block, and it allocates. |

**Pick: A.** This Mac runs macOS 26. Memory: the recording ring holds 6 minutes (138 MB at 48 kHz stereo float), allocated on attach and freed on detach. If you're paused longer than that, the oldest audio is dropped and the cursor moves up to the oldest kept. The stems ring holds 20 s. Playback starts, and restarts after a stall, only once 5 s of stems lie ahead of the cursor: started at the live edge with under a second separated ahead, a slow slice made it play and stall by turns.

Fixed later (2026-10-26): that move ran every IO cycle as a jump, so past 10 minutes of pause the separator worked flat out on slices that were stale before they landed, and play after such a pause never got a slice and stayed silent until `next`. The move now keeps the generation, the worker restarts at the cursor when the cursor passes its frontier, and the worker separates nothing while paused. The separator caps MLX's buffer cache at 1 GB; unbounded it held about 5 GB beside a 0.22 GB model.

### 9. The separator's lifetime and install

| Option | For | Against |
|---|---|---|
| A. The daemon spawns it on attach, stops it on detach, and restarts it with a back-off if it dies | Lives only while used; one supervisor. | A cold start (Python, MLX, weights) on each attach, about 2 to 3 s. |
| B. Its own launchd agent, always on | Warm. | About 1 GB resident all day for an idle feature. |
| C. A new process per request | No supervision. | A cold start every second. |

**Pick: A.** `install.sh` builds the Python environment with `uv` under `~/.local/share/stemmix/venv` and runs the separator's self-test once, which downloads the weights to `~/.cache/demucs-mlx`. Until the first slice arrives the cursor waits, so an attach has about 3 to 5 s of silence. While the separator is down the player waits too, and the log says why.

### 10. The low-pass filter comes back as a mode (2026-10-24)

The stem player replaced the first version's moving low-pass without the user asking. Asked, with both versions and their combination rendered to listen to:

| Option | For | Against |
|---|---|---|
| A. Stems only; the filter stays gone | One audio path. | Loses a zero-delay, no-GPU way to thin the song. |
| B. A `mode` setting: `instruments`, `muffled`, or `both` | The user picks by ear; `both` is "instruments taken away and muffled". | Two mechanisms kept alive and tested. |
| C. Stems, with the filter covering the start-up gap | Sound from the first second. | The stems run 3 s behind live, so the hand-over repeats 3 s. |

**Pick: B**, the user's ruling, with the muffling softened for `both` so drums-only is not a thud under a wall. The muffling is a 0 to 10 knob at each end: `muffling_max` with no session working and `muffling_min` with `tracks` sessions working (the user: none at all when every agent works, so 0), one pair shared by `muffled` and `both`. Level to cutoff is log-spaced from 20 kHz (0, no filter) to 150 Hz (10); the level runs in a straight line between the two ends, so max 10 and min 0 reproduce the first version's cutoffs exactly (510 Hz, 1.7 kHz, 5.9 kHz for 1, 2, 3 of 4). Default max 7: about 1.5 kHz at one of four, 3.6 kHz at two, 8.5 kHz at three, close to the softened clips the user heard (1.8 / 4 / 8.9 kHz).

One render path for every mode: the separator runs, `muffled` plays all four stems through the filter, `both` plays the k stems through it, `instruments` skips the filter. The filter is the first version's Linkwitz-Riley 4th-order low-pass (two cascaded Butterworth biquads per channel), after the stem mix, with the cutoff gliding to a new target over 0.1 s in the log domain. The start-up gap is left as it is: the user calls it buffering time and wants a clear signal there later, not the filter. Cost accepted: in `muffled` mode the separator does work nobody hears.

### 11. The media keys (2026-10-24)

The evidence: in about 17.7 h of an unbroken Now Playing claim with the tap live, the daemon's log held no `transport source=media-key` line, so the keys never reached it. Apple documents how a macOS app becomes Now Playing (handle a remote command and set `playbackState` every time playback starts or halts [1][2][3]; `MPNowPlayingSession` is not on AppKit macOS [5]) but not how the system chooses between two eligible apps [4]; vendors, forums and Chromium report the slot going to the app that most recently played [6][7][8][9][10]. The only other route is an event tap on the keys, which needs the Accessibility or Input Monitoring grant [11][12][13][14].

| Option | For | Against |
| --- | --- | --- |
| A. Keep the claim as is | No work; works if macOS ever routes the keys. | 0 keys in about 17.7 h of live claim. The README promises something that does not happen, and the code is never exercised. |
| B. Change the claim (re-assert after each Spotify event, add duration and elapsed time) | Might win the slot. | Trial and error against undocumented arbitration; each try needs a hand check. |
| C. Drop the claim; keys stay with Spotify, which stemmix follows; the menu covers the rest | Deletes `NowPlaying.swift` and its wiring. Play/pause by key still works through Spotify (choice 6B). | Drops the "Media keys, Control Center and headphone buttons" feature, which never worked. Next and previous on the keys mean Spotify's, not the buffer's. |
| D. An active `CGEventTap` that takes the keys from Spotify | The keys control stemmix exactly. | A new Accessibility grant the installer cannot give. Two key paths, and the tap is lost on every ad hoc rebuild. |

**Pick: A, kept and made to win (choice 18)**, the user's ruling. Reading mediaremoted's log showed the slot goes to the client that most recently changed its playback state into Playing, and stemmix lost it because its own state did not change when Spotify started playing. So the claim stays, and choice 18 makes stemmix's state change after Spotify's.

### 12. Where the menu lives

| Option | For | Against |
| --- | --- | --- |
| A. In the daemon's process, on its existing `NSApplication` | One bundle and one launchd agent (`KeepAlive` already keeps it up). Direct reads of state, no new contract. A status item needs no permission, so the audio grant is untouched. | A crash in menu code takes the tap down with it, and a death with the tap running wedges coreaudiod (plan review item 1). |
| B. A separate menu app; the daemon writes a state file to `~/.local/state/stemmix/`; commands go over the existing distributed notification | A UI crash cannot touch the tap. | A second app to install and keep alive, and a new file shape in `contract/` with two readers. |
| C. A SwiftBar/xbar plugin running `stemmix --status` | Little UI code. | A third-party app to install, polling, and a second install step. |

**Pick: A.** It is the simplest shape and keeps one install command. The con is handled by keeping every decision in pure, tested functions (choice 14) and the AppKit file thin.

### 13. AppKit or SwiftUI

| Option | For | Against |
| --- | --- | --- |
| A. `NSStatusItem` + `NSMenu`, plain `NSMenuItem`s | Fits the existing `NSApplication.run()`. Items can change while the menu is open, and the daemon's timer is in `.common` modes, which include event tracking [15], so `tick` keeps updating it. Background Music, an audio-driver app, does this with template icons [16]. | More lines than SwiftUI. |
| B. SwiftUI `MenuBarExtra`, `.menu` style | Declarative. | A `Scene`: needs the SwiftUI `App` lifecycle in place of `@main enum Main` and its command-line modes. Reported: content not refreshing while open [17], the menu blocking the run loop, no API to the status item [18]. A menu-bar-only app is "automatically terminated" when the user removes the extra [19], bypassing the signal handler's teardown. |
| C. `MenuBarExtra`, `.window` style | Rich layout. | The same lifecycle cost, reported resize bugs [17]; nobody asked for rich layout. |

**Pick: A.**

### 14. How the menu gets its state

| Option | For | Against |
| --- | --- | --- |
| A. Each tick, `Daemon` builds one `MenuSnapshot` (a value, `Equatable`) and hands it to the menu only when it changed; a pure `menuContent(_:)` turns it into what is shown | Every decision can be tested without a runtime. No live objects leave their owners. | One more struct. |
| B. The menu reads `Playback` and `Daemon` fields itself in `menuNeedsUpdate(_:)` | Fewer types. | Stale while the menu is open, and it reaches into other modules' internals. |
| C. Parse the log | Decoupled. | The log is not a contract. |

**Pick: A.** The snapshot is built on every tick, attached or not. Detached, it carries the reason, from the two halves of the attach decision (a session open in the last minute, the player running) and the last refused permission, which a successful attach clears: "No session open", "Spotify is not running", "Needs System Audio Recording permission" or "Attaching". Attached, `Playback.snapshot()` returns a value from one load each of the recording head and the cursor:

- whether stemmix plays: Playback's intent, the last play or pause it sent. The IO thread's own flag changes only inside its render call, a cycle after each command, and never when the IO proc is dead, so the intent is the truth for the menu, for `toggle` and for Now Playing; the `level` line's `state=` keeps the applied flag.
- whether the music player itself is paused (its last reported state), so the state line can say "Spotify is paused", since Play then only plays what is buffered.
- the song under the cursor; seconds behind the live edge (0 at live, not the 2.6 s the `level` line counts).
- which of next, previous and live would act: `availableCommands` maps each through `resolve` with the inputs a command gets, so a greyed item never disagrees with what the command does. The live edge and the "at live" test are one pair of functions in `Transport.swift`, so the menu says "live" exactly when Back to live is greyed.

It never calls `status()`, which drains the meters behind the 10 s `level` line. Beside it the snapshot carries the counts, the player's name, the audible stems and the muffling cutoff, but not `tracks` or `mode`: no line shows `tracks`, and the mode reaches the menu only through the cutoff, which is nil when the mode does not muffle. It also carries the last `level` line's sample count: at 0 the state line reads "No audio from Spotify", because the tap counts every frame it is handed, silent or not, so 0 means no audio reached the daemon at all, whatever the cause. The first `level` line after an attach waits a full interval, so it never reads 0 by construction. Last, the Media keys line: "Media keys: Stemmix" or "Media keys: another app" from the daemon's belief (choice 18), hidden while detached or when the slot observer did not register. The stem names and the cutoff label are the `count` line's words, from the same two functions.

### 15. The status bar icon

| Option | For | Against |
| --- | --- | --- |
| A. Icon only, `NSStatusItem.squareLength` [20] | Fixed width; nothing in the bar jitters. | The song is one click away. |
| B. Icon plus text (k/N or the title) | Visible at a glance. | Variable width that changes every tick or every song, and it takes menu bar space. |
| C. Text only | Most information. | Same as B, and worse. |

**Pick: A**, the user's ruling. Three states, SF Symbols from `NSImage(systemSymbolName:accessibilityDescription:)` [21] marked template [22]: detached `waveform` with `appearsDisabled` [23], playing `waveform`, paused `pause.circle` (names in `Config.swift`).

### 16. Album art

| Option | For | Against |
| --- | --- | --- |
| A. Title and artist only, from the song under the cursor | No new data path. | No picture. |
| B. Art from Spotify's oEmbed endpoint, `open.spotify.com/oembed?url=spotify:track:<id>` [24] | No permission and no key; it returns a 300 px `thumbnail_url` for a track id. | A network call from the daemon for each song, an image cache, Spotify only, and an undocumented rate limit. |
| C. Spotify's AppleScript `artwork url` | Exact. | Needs the Automation permission (choice 7C). |

**Pick: A.** A plain title and artist line was accepted; art needs a network dependency that serves no control need. Spotify's local cache is an opaque browser cache, not addressable by track id, and the notification the daemon reads carries no art.

### 17. Restart and quit

The daemon is a launchd agent with `KeepAlive`, so an ordinary exit is restarted at once.

| Option | For | Against |
| --- | --- | --- |
| A. Restart and Quit. Restart: the signal handler's teardown, then exit; launchd relaunches within its 10 s spawn throttle (`man launchd.plist`, `ThrottleInterval`). Quit: `launchctl bootout gui/<uid>/com.benjaminfeder.stemmix`; launchd sends SIGTERM to the same handler and the daemon stays stopped until the next login or `./install.sh` | One teardown path for both. Quit gives Spotify back mid-session. | After Quit there is no menu to start it from. |
| B. Restart only | No stopped state to explain. | No way to hear Spotify normally while sessions are open. |
| C. Neither | Least code. | A stuck daemon needs a terminal. |

**Pick: A**, the user's ruling. One teardown serves the signals, Restart and Quit. Quit first stops the tick from attaching and tears down, then runs the bootout: otherwise a tick could attach again before launchd's SIGTERM, and that teardown would race launchd's 5 s exit timeout. The label comes from the job's own `XPC_SERVICE_NAME` (`install.sh` stays its one source); outside launchd that is `0` or absent, and Quit just exits. A `launchctl` that fails to start or exits non-zero is a bootout that failed: it is logged as `quit-failed`, and the daemon carries on. An exit 0, or a `launchctl` ended by a signal (launchd ends the job's process group), is the bootout working, so the tick stays stopped until launchd's SIGTERM ends the daemon.

### 18. Winning the media keys (2026-10-24)

How a key travels: keyboard, then `rcd`, then mediaremoted, then the one active Now Playing client. mediaremoted moves that slot to whichever client most recently changed its playback state into Playing. A client that reports Paused keeps the slot; setting the same state again or new track info moves nothing; Spotify never retakes the slot on its own. stemmix won the slot at every claim and lost it when Spotify changed from Paused to Playing while stemmix's own state did not change: after an attach made while Spotify was paused, and while stemmix already played its buffer when Spotify resumed.

| Option | For | Against |
| --- | --- | --- |
| A. A state pulse: on each Spotify change into Playing (the daemon already receives `PlaybackStateChanged`), and at claim, stemmix sets its `playbackState` through Playing and ends on its true state, so mediaremoted sees a fresh change into Playing from stemmix after Spotify's | Public API only, no permission, uses exactly the rule observed; Spotify does not fight back, so no loop. | Whether two sets within one run-loop turn reach mediaremoted as two changes had to be proved first (below). |
| B. Pulse on a timer | Self-healing. | Steals the keys from every other app the user starts; blips Control Center every cycle. |
| C. Event tap on the key | Keys are stemmix's regardless. | Accessibility grant; a second key path. |

**Pick: A.** One pulse per Spotify event, no timer. The pulse keys off the state stemmix last set, because a same-value set never reaches mediaremoted: Paused only when the last set was Playing, then Playing, then Paused when stemmix is paused. So mediaremoted sees exactly one change into Playing, and the last set is the truth (Playback's intent, choice 14). A paused stemmix keeps the slot, and the next key resumes it.

The daemon cannot read who holds the slot without linking MediaRemote, so it keeps a belief. mediaremoted posts the Darwin notification `com.apple.MediaRemote.activePlayerPathDidChange` on every slot move, which the daemon observes through libnotify. A post within 1 s of an own move of the slot is stemmix's own (`now-playing held`): a set into Playing that moved it, or a release while holding it, whose move back to the previous holder posts too, so a detach and an attach in one tick expect both posts. Any other post is a loss unless an own set answers it within 1 s, which covers Spotify's own start: its post comes before the notification that triggers the pulse. A loss logs `now-playing lost` and retakes the slot at most once every 30 s, so an app that also retakes on loss cannot loop with stemmix; a loss inside that time leaves the keys with that app until stemmix next changes into Playing. The menu's Media keys line shows this belief.

Proof, 2026-10-24 on macOS 26.6.2, with a probe accessory app that plays no audio: each pulse, Paused then Playing in the same run-loop turn, on the next turn or 50 ms apart, gave two `setting playback state` lines in mediaremoted's log (19:09:55.243 and .243 for the same-turn pair); a same-value set gave none. The probe's first Playing took the slot at 19:09:52.096, and `notifyutil` saw the `activePlayerPathDidChange` post through libnotify at 19:09:52.108.

## Behaviour summary

- Attached (a live session and the player outputting): Spotify is muted at the source. The recording runs. The cursor starts at the recording head and plays once stems exist (about 2.6 s).
- k = 0: the cursor keeps moving, gain 0. Unchanged from today.
- `mode`: `instruments` thins by stems; `muffled` plays all four stems low-passed; `both` plays the k stems low-passed. The cutoff for k of N runs from `muffling_max` to `muffling_min` (choice 10).
- Pause (key, menu, Spotify, or command): a 10 ms fade, then the cursor stops. The recording continues.
- Play: from the cursor.
- Next: the next song start in the buffer, else the player skips and the cursor plays the new song from its start. Previous: the start of the current song if it's buffered.
- Detach (no live session for 60 s): the tap, the recording and the separator go away, and Spotify sounds normal at its own position. Any time-shift is lost.
- Media keys (attached): the daemon is the Now Playing app with its own play state; each time the player starts playing it pulses its state through Playing to take the keys back, and a loss to another app is answered at most once every 30 s (choice 18).
- Menu bar: one icon (dimmed waveform detached, waveform playing, pause symbol paused) and a menu with the song, the state, the sessions, the stems, the Media keys line, the transport commands greyed when they would do nothing, Open log, Restart and Quit (choices 12 to 17).

## Not built

- Apple Music track boundaries: its `com.apple.Music.playerInfo` notification is parsed with the same shape, but nothing here was verified with Apple Music.

## Proof

- Swift unit tests: k to stems, the separation schedule, crossfade ramps, the timeline rings including wrap and the overflow drop, transport (pause fade, seek, next/previous), notification parsing and skip detection, protocol frames against the `contract/` fixtures.
- Python test: the separator returns the requested slice in the right shape, and drums+bass+vocals+other adds back up to the input.
- Offline end-to-end: `stemmix --simulate <recording.f32> <out.f32> <script>` runs the real timeline, worker, separator and render code on the Blinding Lights recording with a scripted k, pause and resume. Check: k = 4 is the input delayed (exact), and a pause produces silence then resumes at the same sample. With a simulated player over two songs, `next` at the live edge gives exact silence, then the second song from its first sample.
- Live: the installed daemon with Spotify playing and a scripted session file. The log shows attach, separator ready, steady lead, no underruns, an output level, and pause/play/next by command.

## Plan review (2026-10-23), applied

One read by a plan-review agent before building. Each finding and what changed:

1. A separator that dies mid-write raises SIGPIPE, whose default kills the daemon with the tap running, which wedges coreaudiod. **The daemon ignores SIGPIPE, every separator read and write has a timeout, and a hung or dead separator is killed and restarted.**
2. The tap runs at 48 kHz; HTDemucs takes 44.1 kHz. **The separator resamples both ways with soxr (HQ)**, inside the timed request, so the per-window figure in the log includes it. The residual "other" stays at the tap's rate, so all-on remains the original.
3. The last F samples of a slice change when the next slice lands. **The published stems frontier is the slice end minus F; ring slots behind the frontier never change until the next seek.**
4. Tap creation had its permission check at three call sites. **The preflight moves into `ProcessTap.init`, which throws when not authorized.** `--simulate` and `--control` never construct a tap.
5. The Python sum test now sums the model's own four stems (within 20 dB); the exact all-on check belongs to `--simulate` at k = 4.
6. Nothing proved Now Playing. **The daemon runs as an accessory NSApplication; the media-key route is a hand check for the user** (press play/pause with Spotify playing; the log names each command's source). Choice 6B covers pause if the keys never arrive. (Choice 18 proved that the pulse's two sets reach mediaremoted as two changes; that the keys reach the daemon while Spotify plays is still the user's hand check.)
7. N = 4 changes at all five places that say 5: `Config.swift`, `plugin.json`, `register.ts`, `contract/config.json`, README.
8. The macOS 15 floor goes into both `Package.swift` and `Info.plist`.
9. **The recording ring is touched once off the IO thread before the tap starts**, so the IO thread never takes a first-write page fault.
10. The separator writes frames to a private copy of stdout and points fd 1 at stderr.
11. Right context when behind is capped at **2.5 s** (measured), not 3 s.

## Sources for choices 11 to 18

1. https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter/playbackstate
2. https://developer.apple.com/videos/play/wwdc2019/501/
3. https://developer.apple.com/documentation/mediaplayer/becoming-a-now-playable-app (sample, `MacNowPlayableBehavior.swift`)
4. https://developer.apple.com/videos/play/wwdc2022/110338/
5. https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession
6. https://chatgate.ai/post/smartpause
7. https://beamhook.app/media-keys-wrong-app/
8. https://developer.apple.com/forums/thread/685333
9. https://developer.apple.com/forums/thread/799691
10. https://ayakael.net/mirrors/electron/commit/db8644ee7a7e6e80802508a13ee06c6f20ee1a1c
11. https://git.tjdev.de/mirror/mpv/src/commit/4a4d2155d8e76b06380043de73439dc6f80d7d6b/osdep/macosx_events.m
12. https://github.com/nevyn/SPMediaKeyTap
13. https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)
14. https://developer.apple.com/forums/thread/122492 and https://developer.apple.com/forums/thread/828052
15. https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html
16. https://github.com/kyleneideck/BackgroundMusic/blob/master/BGMApp/BGMApp/BGMStatusBarItem.mm
17. https://developer.apple.com/forums/thread/720625
18. https://github.com/orchetect/MenuBarExtraAccess
19. https://developer.apple.com/documentation/swiftui/menubarextra
20. https://developer.apple.com/documentation/appkit/nsstatusitem/squarelength
21. https://developer.apple.com/documentation/appkit/nsimage/init(systemsymbolname:accessibilitydescription:)
22. https://developer.apple.com/documentation/appkit/nsimage/istemplate
23. https://developer.apple.com/documentation/appkit/nsstatusbarbutton/appearsdisabled
24. https://developer.spotify.com/documentation/embeds/reference/oembed
