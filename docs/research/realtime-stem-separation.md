# Real-time stem separation for sound-mod

Researched 2026-10-23 for the daemon that taps Spotify (48 kHz stereo float32, ~512-frame callbacks) on an Apple M5 Pro, macOS 26, Swift 6.4. Every figure names its source in brackets (keys in the Sources list) and the hardware it was measured on. "Derived" marks my own arithmetic from a sourced figure. "Unconfirmed" marks a claim I found only second-hand or could not open.

## Short answer

- **No pure-DSP method gives drums / bass / vocals / other.** HPSS, mid/side, REPET and NMF give harmonic vs percussive, centre vs sides, or repeating vs non-repeating layers. They run live with about 0.1–0.3 s lookahead, but they are not instrument stems (§1).
- **HTDemucs (4 stems, MIT code and weights) is the practical choice.** It needs a 7.8 s window, so live use means a sliding window with a few seconds of fixed delay. A shipping macOS app already does this: Youka Live separates system audio into vocals/drums/bass/other with "about three seconds of delay" and silences the original output [youka]. Moises Live does the same for system audio, with no published delay [moises].
- **Speed is not the problem on paper.** HTDemucs runs at 112–114x real time warm on an M4 Max through MLX [dmlx, dmlx-swift]. One unbatched 7.8 s segment takes 0.685 s warm on an iPhone 15 Pro GPU [dmlx-swift-val]. **No one has published per-window timings on an M5 Pro.** Measure that first.
- **True low-latency models (23 ms) exist only as papers.** HS-TasNet and RT-STT have no public weights, and their quality is far lower (SDR 4.6–5.5 dB vs 9.0 dB for HTDemucs) [hstasnet, rtstt].
- **Integration:** the in-process Swift path is `demucs-mlx-swift` (MIT), which runs on MLX Swift. Its main obstacle: MLX's Metal shaders cannot be built by `swift build`, which is what `install.sh` runs today [mlx-swift]. The fallback is a Python `demucs-mlx` sidecar over a pipe (§5).

## 1. Fourier/STFT methods with no trained model

| Method | Separates | Cleanliness (evidence) | Lookahead | CPU | Live block by block? |
|---|---|---|---|---|---|
| Median-filter HPSS [fitz] | harmonic vs percussive. A third "residual" layer when margin > 1 [librosa-src, Driedger 2014] | Guitar and piano attacks land in the percussive part. Some drum traces stay in the harmonic part [fitz §3]. Vocals split between both parts. | Centred time median of length l needs (l−1)/2 future frames. Paper settings (FFT 4096, hop 1024, l = 17, 44.1 kHz) [fitz §3] at 48 kHz: 8 × 1024 / 48000 ≈ 0.17 s plus a 0.085 s window, about 0.26 s (derived). | Python/MATLAB: about 5–10 ms per 10 ms hop. CUDA: about 160 µs per 10 ms buffer [zen]. Hardware not stated. | Yes. Sliding-STFT real-time versions exist [rt-hpss, zen]. librosa's `hpss` (default kernel 31) works on a whole spectrogram (offline) [librosa-src]. |
| Mid/side; panning-index centre extraction [avendano] | centre-panned content (often vocals, kick, bass) vs side content | Depends entirely on how the song is panned. I found no measured quality for music stems. | One STFT frame (or zero for plain L−R) | negligible | Yes |
| REPET [repet] | repeating background vs non-repeating foreground (music vs voice) | Evaluated for music/voice separation [repet]. I did not find numbers comparable to the neural models. | Original REPET estimates a period from the beat spectrum of the analysed excerpt: offline. Adaptive REPET works locally; window size not found. | low | Original: no |
| REPET-SIM / online REPET-SIM [repet] | same, using a similarity matrix | The online variant was evaluated on speech enhancement (speech plus noise), not on music stems [repet] | The online version uses only a buffer of past frames, so it is causal. Buffer length not stated on the project page. | low | Online variant: yes. librosa `nn_filter` implements the offline REPET-SIM-style filter [librosa-src]. |
| NMF | parts-based components with no labels. With fixed templates (supervised): named sources | Real-time supervised NMF separates kick, snare and hi-hat in **drum-only** recordings, with templates learned from isolated hits [nmf-drums]. No evidence for full mixes. | Measured delay of about 6 ms (hop 512, spectrum 2048) [nmf-drums §5.4] | low per frame | Supervised only. Unsupervised NMF (librosa `decompose`) is offline [librosa-src]. |

**Verdict.** DSP can give the owner 2–3 audibly different layers with almost no delay: percussive, harmonic-centre, and harmonic-sides (plus a low band). It cannot give stems that sound like "the drums" or "the bass" in a full mix. REPET's original MATLAB code states no license [repet]. librosa is ISC [librosa-src].

## 2. Neural separators

The window length sets the minimum delay: a non-causal model needs future audio up to its window edge.

| Model | Stems | Window (min. latency) | Quality (MUSDB SDR) | Measured speed | Code / weights license |
|---|---|---|---|---|---|
| HTDemucs `htdemucs` | drums, bass, other, vocals | 7.8 s max segment [demucs]. The Core ML export has a fixed input of 343,980 samples = 7.8 s at 44.1 kHz [cml-conv]. | 9.00 dB [demucs]. 9.20 dB with sparse attention and fine-tuning [htdemucs] | On M4 Max (40-core GPU), 120 s of audio, warm [dmlx]: PyTorch CPU 6x, PyTorch MPS 42x, MLX 114x. Swift MLX 112x warm [dmlx-swift]. Upstream: CPU "roughly 1.5 times the duration of the track", hardware not stated [demucs]. iPhone 15 Pro GPU: 0.685 s warm for one padded 7.8 s segment [dmlx-swift-val]. | MIT / MIT [demucs LICENSE] |
| `htdemucs_ft` | 4 | 7.8 s | slightly better | "4 times more time" than htdemucs [demucs] | MIT |
| `htdemucs_6s` | + guitar, piano | 7.8 s | "piano source is not working great" [demucs] | about htdemucs speed (not measured) | MIT |
| Open-Unmix (umxhq, umxl) | 4 | Whole track: a bidirectional LSTM that "cannot be used in an online/real-time manner" [umx] | vocals 6.32 dB [spleeter-joss table] | — | MIT code. umxhq weights MIT, **umxl weights CC BY-NC-SA 4.0** [umx, zenodo] |
| Spleeter | 2 / 4 / 5 (adds piano) | Needs buffering: "cannot be applied in real-time" [spleeter-joss] | vocals 6.55–6.86 dB [spleeter-joss] | 100 s of audio in under 1 s on an RTX 2080 plus a Xeon Gold 6134 [spleeter-joss]. No Apple figure. TensorFlow. | MIT code and models [spleeter-joss] |
| MDX-Net (UVR checkpoints) | vocals / instrumental only | Core ML input dim_t = 256 frames × hop 1024 = 262,144 samples ≈ 5.9 s at 44.1 kHz (derived from [uvr-coreml]) | — | none published | MIT, according to the redistributor's card [uvr-coreml] |
| BS-RoFormer / Mel-RoFormer | 4 (one model per stem in the paper) | 8 s segments, 4 s hop [bsrof] | 9.80 dB without extra data. 11.99 dB with 500 extra songs [bsrof] | Not reported. 72–93 M parameters [bsrof]. `audio-separator` runs them on MPS but publishes no Apple timings [audio-sep]. | No official weights. lucidrains code MIT. Community weights come from ZFTurbo (repo MIT, weight license not stated) [bsrof-lucid, msst]. |
| **HS-TasNet** (L-Acoustics, 2024) | 4 | **23 ms** (1024 samples at 44.1 kHz) [hstasnet] | 4.65 dB, or 5.55 dB with 150 extra songs. MUSHRA 37 vs 66 for HTDemucs [hstasnet] | 4.26 ms per 23 ms block on 4 cores of an i7-12850HX. Small (16 M params): 1.83 ms [hstasnet] | No official code or weights. lucidrains reimplementation (MIT) is training code only [hstasnet-lucid]. |
| **RT-STT** (ICME 2025) | 4 | 23 ms (window 1024, hop 512) [rtstt] | 5.17 dB with 383 K params [rtstt] | 1.01 ms per block, fp16, RTX 3080 Ti [rtstt] | "Code will be released soon" [rtstt-repo] |

HS-TasNet's own comparison table lists HTDemucs's latency as 7,800 ms [hstasnet]. I found no "real-time Demucs" checkpoint with a short window. The Demucs README points to Neutone's "realtime Demucs" plugin model [demucs], but I found no latency figure for it.

**Ports that run on macOS**

| Port | Runtime | License | Measured speed | Notes |
|---|---|---|---|---|
| ssmall256/demucs-mlx [dmlx] | Python + MLX/Metal | MIT | 114x warm on M4 Max | All 8 Demucs models. 72–83 dB SNR agreement with PyTorch [dmlx]. |
| ssmall256/demucs-mlx-swift [dmlx-swift] | Swift 6.3+, MLX Swift 0.32.3, macOS 14+ | MIT | 112x warm on M4 Max. 0.685 s per segment on iPhone 15 Pro | First validation run dated 2026-10-02; 0 GitHub stars. Tensor inputs must be at `separator.sampleRate` (44.1 kHz). |
| andrade0/demucs-mlx [admlx] | Python + MLX | MIT | 26–34x on M4 Max (MLX 0.21) | Older and slower than ssmall256's. |
| mlboydaisuke/HTDemucs-CoreML [cml] | Core ML `.mlpackage`, FP32 | MIT | none published | Verified **cpuOnly**. Its card warns that moving to GPU/ANE "can silently change the numerics (FP16 attention overflow) or crash". |
| gyoom/UVR-MDX-CoreML [uvr-coreml] | Core ML fp16, ANE/GPU/CPU | MIT (per card) | none published | 2 stems only. STFT is left to the app (vDSP). |
| nikhilunni/demucs-rs [drs] | Rust, Burn, Metal | Apache-2.0 | none published | Offline: a DAW plugin that separates a dropped file. |
| sevagh/demucs.cpp [dcpp] | C++17 / Eigen, CPU | MIT | none published | Built for low memory, "sacrificing speed" (per search snippet). |
| schism-audio/htdemucs-coreml | Core ML fp16 (ANE) | MIT (per search snippet) | — | **Unconfirmed:** Hugging Face returned 401 for every schism-audio repo, so the repos look removed or private. |

## 3. Shipping products on Apple devices

| Product | Stems | Live or pre-analysed | Technique / latency published |
|---|---|---|---|
| Algoriddim djay (Neural Mix) | "beats, instruments, and vocals" [algo-help] | Live: "Neural Engine for real-time stem separation". Maximum quality on Apple Silicon Macs [algo-help]. | 2020: Core ML, "ultra low latency", no number [algo-pr]. Deezer says Algoriddim used Spleeter models [spleeter]. Current model unknown. |
| Serato DJ Pro Stems | vocals, melody, bass, drums | Vendor page says "real time" [serato] | None. Support page (403 to me): a start delay when first triggered and heavy CPU use (unconfirmed). |
| Apple Music Sing | vocal level only | Live during playback | The slider "does not fully remove vocals" [apple-sing]. "On-device ML in real time" comes only from a spokesperson quote relayed by press (unconfirmed). iPhone 11 or later, iOS 16.2 (support guide, via search). |
| rekordbox Track Separation | Vocal / Drums / Inst [rb-faq]. A 4th stem (bass) in v7.2.8 (secondary only). | FAQ mentions an "analysis process" and memory settings. Says nothing either way about live use [rb-faq]. | None |
| VirtualDJ Stems 2.0 | vocals, melody/instruments, bass, drums [vdj] | **Real time** on Apple Silicon M1+ (macOS 13+), or "prepared" stems saved at about 4x the file size. "On-Demand" mode has a small start delay [vdj]. | The fallback for unprepared tracks is the faster "stems 1.0" algorithm [vdj]. No latency number. |
| Logic Pro Stem Splitter | vocals, drums, bass, guitar, piano, other | Offline: Processing > Stem Splitter on a region. Apple silicon only (support guide via search. Its body did not render for me.) | None |
| Ableton Live 12 Stem Separation | — | Offline. Uses the GPU on Apple silicon (FAQ snippet. The page returned 403.) | None |
| Traktor Pro 4 | 4 | Conflicting: retailers say real time, reviews say per-track preparation (secondary only) | iZotope-based (secondary) |
| zplane PEEL STEMS 2 (plugin) | drums, bass, vocals, other | Live in a DAW | **245 ms at 44.1 kHz, 238 ms at 48 kHz on Apple Silicon. 385 ms on Intel Macs** (DAW-compensated) [zplane] |
| Moises Live | "dialogue, effects, instruments", vocals | Live on system audio, on-device, Mac and Windows [moises] | Neural Engine claimed "up to 35 times" faster than CPUs (press clipping, vendor claim). No latency. |
| **Youka Live** | vocals, drums, bass, other | Live on system audio. macOS 15.6+, menu-bar app [youka] | "about three seconds of delay". Silences the original audio while running. Turns itself off rather than let the delay grow if the Mac can't keep up [youka]. Model not named. |

The pattern: products that must respond in milliseconds (DJ decks, plugins) either pre-analyse or accept lower quality (zplane: 245 ms, VirtualDJ: a fallback algorithm). Listen-only system-audio products accept seconds of delay. That is this tool's case.

## 4. Licensing

| Candidate | Code | Weights | Personal, not distributed | Source published on GitHub |
|---|---|---|---|---|
| Demucs / HTDemucs (all variants) | MIT [demucs] | MIT. The README and LICENSE make no separate weight carve-out. One ONNX card claims "CC BY-NC 4.0" for the v3/v4 checkpoints but links the same MIT LICENSE [dmlx-onnx-card]. I treat that claim as wrong but unconfirmed. | fine | Fine. Download weights at install time and keep the MIT notice. |
| demucs-mlx / demucs-mlx-swift | MIT | MIT conversion of the Meta weights | fine | fine |
| HTDemucs Core ML (mlboydaisuke) | MIT | MIT | fine | fine |
| Open-Unmix | MIT | umxhq MIT. **umxl CC BY-NC-SA 4.0** | fine | Code fine. umxl only non-commercially, with share-alike. |
| Spleeter | MIT | MIT [spleeter-joss] | fine | fine |
| UVR MDX-Net | — | MIT per redistributor [uvr-coreml] | fine | fine (secondary) |
| BS/Mel-RoFormer | MIT (lucidrains, ZFTurbo) | License not stated for community weights | fine for personal use | Risky until the weight terms are known |
| HS-TasNet / RT-STT | MIT training code / none | none exist | must train yourself | — |
| HPSS (librosa) | ISC | — | fine | fine |
| REPET MATLAB | no license stated | — | fine to read | Re-implement rather than copy |

For a public repo: keep weights out of git and fetch them in `install.sh`. That keeps the repo's own license clean whichever MIT weights are used.

## 5. Recommendation

**Approach: HTDemucs `htdemucs`, 4 stems, run as a sliding window with a fixed output delay of about 3–4 s.**

- **Pipeline (design, not measured):**
  1. Resample the tap from 48 kHz to 44.1 kHz with AVAudioConverter (the model and the Swift port expect 44.1 kHz) [dmlx-swift].
  2. Keep a ring buffer. Every hop H (1–2 s), separate the latest 7.8 s window.
  3. Keep the H-long slice that ends R seconds (≈1–2 s) before the window's right edge, and crossfade it into the previous slice.
  4. Resample back to 48 kHz and play everything delayed by D ≈ H + R + compute.
- **How much quality the 1–2 s right context costs versus the offline result is unmeasured.** Youka Live's ~3 s delay [youka] suggests it is acceptable, but that is indirect evidence.
- **Cost (derived):** each hop processes one full 7.8 s segment. Batched, the M4 Max does about 21 segments in 1.07 s, about 50 ms per segment [dmlx-swift]. Unbatched on an iPhone 15 Pro it takes 0.685 s [dmlx-swift-val]. An M5 Pro should land between those, so at H = 1 s the GPU would be busy roughly 5–40% of the time. **Not measured on this Mac.** GPU contention matters too: throughput fell to 70x "while other apps were busy" [dmlx].
- **N ≈ 5 sessions on 4 stems:** step through the 4 stems, or use `htdemucs_6s` (6 stems, weak piano) and group them. Either way, consider making "other" the residual (mix minus the other stems). Then "all on" equals the delayed original exactly, whatever the model outputs sum to. That residual is my suggestion; I did not check how closely HTDemucs stems sum to the mix.
- **Integration, in order of preference:**
  1. **In-process Swift via `demucs-mlx-swift`** (MIT; Swift 6.3+, and this Mac has 6.4; macOS 14 target, and the daemon targets 14.2).
     - Blocker: MLX Swift's README says "SwiftPM (command line) cannot build the Metal shaders", so `install.sh` must switch from `swift build` to `xcodebuild` [mlx-swift].
     - Risk: the package is weeks old (validated 2026-10-02, 0 stars), and its API is built around whole files and tensors, not streaming. Each window call is a fixed shape, which suits its per-shape compilation.
  2. **Python sidecar running `demucs-mlx`** (MIT): float32 PCM in on stdin, 4 × stereo out on stdout.
     - Simplest to prototype, and the quickest way to measure per-window time on the M5 Pro before committing to the Swift build change.
     - Cost: a Python environment inside the one install command.
  3. **Core ML (`HTDemucs-CoreML`)**: Swift-native with no MLX. But it is verified only on CPU. HTDemucs on PyTorch CPU runs at 6x on an M4 Max [dmlx], and a 1 s hop needs more than 7.8x, so it is too tight. Moving it to GPU/ANE risks FP16 overflow, per its own card [cml]. Not the first choice.
- **Main risk:** the window, right-context and hop trade-off (delay vs edge quality vs GPU load) has no published numbers for streaming use. Everything above about streaming is my design inference from offline measurements.
- **Not recommended:** HS-TasNet or RT-STT (no weights; training needs MUSDB plus GPU time, and quality is about 4 dB SDR worse). DSP-only (no instrument stems). It does remain a zero-dependency fallback that gives layers, not stems.

**Where the evidence is thin:**
- No per-segment HTDemucs timing on any M-series Pro chip, and none on M5.
- No Neural Engine timing for any open separation model.
- No measured quality loss for streaming HTDemucs with limited right context.
- No published latency for djay, Serato, rekordbox, VirtualDJ or Moises.
- The schism-audio Core ML ports could not be opened.

## Sources

- [fitz] FitzGerald, "Harmonic/Percussive Separation using Median Filtering", DAFx-10 — https://www.audiolabs-erlangen.com/resources/aps-w23/papers/2010_FitzGerald_HarmonicPercussiveSep_DAFx.pdf
- [librosa-src] librosa `decompose.py` (hpss, nn_filter, decompose; ISC) — https://github.com/librosa/librosa/blob/main/librosa/decompose.py
- [rt-hpss] sevagh/Real-Time-HPSS — https://github.com/sevagh/Real-Time-HPSS ; [zen] sevagh/Zen — https://github.com/sevagh/Zen
- [avendano] Avendano & Jot, "A Frequency-Domain Approach to Multichannel Upmix", JAES 52(7/8), 2004 — https://aes2.org/publications/elibrary-page/?id=13016 (abstract only)
- [repet] Rafii, REPET project page (REPET, adaptive, REPET-SIM, online REPET-SIM, code) — https://users.cs.northwestern.edu/~zra446/repet.html
- [nmf-drums] Dittmar & Gärtner, "Real-time transcription and separation of drum recordings based on NMF decomposition", DAFx-14 — https://dafx14.fau.de/papers/dafx14_christian_dittmar_real_time_transcription_a.pdf
- [demucs] facebookresearch/demucs README and LICENSE (archived 2025-01-01) — https://github.com/facebookresearch/demucs ; fork https://github.com/adefossez/demucs
- [htdemucs] Rouard, Massa, Défossez, "Hybrid Transformers for Music Source Separation" — https://arxiv.org/abs/2211.08553
- [cml] mlboydaisuke/HTDemucs-CoreML — https://huggingface.co/mlboydaisuke/HTDemucs-CoreML ; [cml-conv] conversion script — https://github.com/john-rocky/CoreML-Models/blob/master/conversion_scripts/convert_htdemucs.py
- [dmlx] ssmall256/demucs-mlx — https://github.com/ssmall256/demucs-mlx ; weights https://huggingface.co/ssmall256/demucs-mlx
- [dmlx-swift] ssmall256/demucs-mlx-swift — https://github.com/ssmall256/demucs-mlx-swift ; [dmlx-swift-val] https://github.com/ssmall256/demucs-mlx-swift/blob/main/docs/validation.md
- [admlx] andrade0/demucs-mlx — https://github.com/andrade0/demucs-mlx
- [mlx-swift] ml-explore/mlx-swift README (SwiftPM and Metal shaders) — https://github.com/ml-explore/mlx-swift
- [drs] nikhilunni/demucs-rs — https://github.com/nikhilunni/demucs-rs ; [dcpp] sevagh/demucs.cpp — https://github.com/sevagh/demucs.cpp
- [dmlx-onnx-card] HRSadeghi/demucs-onnx — https://huggingface.co/HRSadeghi/demucs-onnx
- [umx] sigsep/open-unmix-pytorch — https://github.com/sigsep/open-unmix-pytorch ; [zenodo] https://zenodo.org/records/3370489 (umxhq), https://zenodo.org/records/5069601 (umxl)
- [spleeter-joss] Hennequin et al., JOSS 5(50) 2154, 2020 — https://joss.theoj.org/papers/10.21105/joss.02154 ; [spleeter] https://github.com/deezer/spleeter
- [uvr-coreml] gyoom/UVR-MDX-CoreML — https://huggingface.co/gyoom/UVR-MDX-CoreML
- [bsrof] Lu et al., "Music Source Separation with Band-Split RoPE Transformer" — https://arxiv.org/abs/2309.02612 ; Mel-RoFormer — https://arxiv.org/abs/2310.01809
- [bsrof-lucid] https://github.com/lucidrains/BS-RoFormer ; [msst] https://github.com/ZFTurbo/Music-Source-Separation-Training ; [audio-sep] https://github.com/nomadkaraoke/python-audio-separator
- [hstasnet] Venkatesh et al., "Real-time Low-latency Music Source Separation using Hybrid Spectrogram-TasNet" — https://arxiv.org/abs/2402.17701 ; [hstasnet-lucid] https://github.com/lucidrains/HS-TasNet
- [rtstt] Wu et al., "Towards Practical Real-Time Low-Latency Music Source Separation" — https://arxiv.org/abs/2511.13146 ; [rtstt-repo] https://github.com/Jundo26/RT-STT
- [algo-help] https://help.algoriddim.com/topic/using-djay/neuralmix-compatibility ; [algo-pr] https://www.algoriddim.com/press_releases/362-algoriddim-reinvents-djing-with-world-s-first-real-time-vocal-and-instrumental-separation-on-new-djay-pro-ai
- [serato] https://serato.com/dj/pro/stems ; [apple-sing] https://www.apple.com/newsroom/2022/12/apple-introduces-apple-music-sing/
- [rb-faq] https://rekordbox.com/en/support/faq/trackseperation-6/ ; [vdj] https://www.virtualdj.com/manuals/virtualdj/interface/stems2/index.html
- Logic Stem Splitter guide — https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac ; Ableton FAQ — https://help.ableton.com/hc/en-us/articles/23730994755996
- [zplane] https://products.zplane.de/peel-stems/ ; [moises] https://moises.ai/products/live/ ; [youka] https://docs.youka.io/en/live
