# 4-stem separation models that beat HTDemucs, and which could run on an Apple Silicon Mac

Researched 2026-10-27, as a follow-up to `realtime-stem-separation.md` (read that first; this file does not repeat it). Question: which 4-stem (drums, bass, other, vocals) models beat HTDemucs, and which could run in near real time on an Apple Silicon Mac. Nothing was run, installed or downloaded; every figure comes from a page, paper or file header opened this session. Numbers in brackets are keys into the Sources list. "Derived" marks my own arithmetic. "Unverified" marks a claim I could not trace to its owner. Confidence is stated where a claim is a prediction.

## Short answer

- **Yes, several public models beat HTDemucs on quality. None has a published timing on any Apple chip except one 228M-parameter vocals model on an 8 GB M3 Air.** Every speed statement below about a new model on this Mac is a prediction or a recipe, not a measurement.
- **Premise fix: the "9.0 dB" figure is `htdemucs_ft`, and it used 800 extra training songs.** The Demucs paper's Table 1 gives base `htdemucs` 8.80 dB and the fine-tuned bag 9.00 dB, both with 800 extra songs [1][2]. So MUSDB-only models that reach 9.0-9.8 dB (SCNet, BS-RoFormer) are stronger than the headline suggests: they match or beat it without the extra data.
- **Best public 4-stem model on a single yardstick: BS-Roformer-SW (jarredou, 6 stems).** On MVSEP's Multisong set it averages 12.19 dB over bass/drums/other/vocals (derived) against 9.16 for `htdemucs` and 9.35 for `htdemucs_ft` [3][4]. Its weights are public but their licence is "unknown" [5], it has about 170M parameters (derived), and it was trained on 13.35 s chunks. An MLX loader for it exists on PyPI (`mlx-audio-separator`, MIT, same author as `demucs-mlx`) [6].
- **Best model trained on MUSDB18-HQ only, with a stated licence on its code: SCNet XL IHF (ZFTurbo).** 10.08 dB on the MUSDB18-HQ test set, 9.93 dB on Multisong (derived), one checkpoint for all four stems, about 53M parameters (derived) [7][8]. PyTorch only; no MLX or Core ML port found. The weights carry no stated licence.
- **Mel-Band RoFormer has no good public 4-stem checkpoint.** The paper's numbers are real, but no weights were released, and ZFTurbo's best community 4-stem run reached 8.94 dB and is flagged undertrained [9][10].
- **HTDemucs plus extra cost is the zero-integration step up:** `htdemucs_ft` in `demucs-mlx` is +0.2 dB on Multisong at 4x the compute [3][11].
- **Do not trust the Mini-BS-RoFormer SDR claims (10.09 dB).** The author trained the V2 and V2.5 models on the MUSDB18-HQ train and test sets [12][13].

## 1. What the numbers mean (read before comparing)

Three different yardsticks appear below. They do not mix.

| Yardstick | What it is | Who computes it | Caveat |
|---|---|---|---|
| Paper tables, MUSDB18-HQ test | museval-style SDR, 50 test songs; "Extra data" column says how many extra songs | The paper's authors | HTDemucs paper numbers use 800 extra songs [1]. BS-RoFormer's paper says 9.80 dB for the 72.2M model without extra data [14], while the Mel-RoFormer paper's own table gives that same model 9.92 dB [15]. The two papers evaluate differently or retrained. |
| ZFTurbo's "MUSDB test avg" | Mean over tracks, with std; the checkpoints are "trained only on MUSDB18HQ (100 songs train data)" [8] | Repo owner | Agrees with the SCNet paper to 0.01-0.03 dB (SCNet small 9.03 vs 9.00, large 9.70 vs 9.69), so it is comparable to paper numbers [8][16][7]. |
| MVSEP "Multisong" | 100 songs, bass/drums/other/vocals; the only place where `htdemucs`, SCNet, BS-RoFormer and BS-Roformer-SW were all scored on the same files | MVSEP quality checker | Hosted at mvsep.com; I could not see how its "other" stem is defined for 6-stem models (the Quatra entry says "other is the residual" [17]). Entries are self-submitted; MVSEP's own models are not downloadable. |

## 2. Candidates

### 2.1 HTDemucs, `htdemucs_ft` (the baseline)

| Item | Value | Source |
|---|---|---|
| SDR, MUSDB18-HQ test (All / drums / bass / other / vocals), 800 extra songs | `htdemucs` 8.80 / 10.05 / 9.78 / 6.42 / 8.93. `htdemucs_ft` 9.00 / 10.08 / 10.39 / 6.32 / 9.20. Sparse attention + fine-tune 9.20 / 10.83 / 10.47 / 6.41 / 9.37 | [1] |
| Public weights | `htdemucs`, `htdemucs_ft`, `htdemucs_6s` in the Demucs repo. No sparse-attention checkpoint is in the README's model list (unverified: I did not list the model registry) | [2] |
| Download location | `htdemucs`: https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th . `htdemucs_ft` is four files: drums `f7e0c4bc-ba3fe64a.th`, bass `d12395a8-e57c48e6.th`, other `92cfc3b6-ef3bcb9c.th`, vocals `04573f0d-f3cf25b2.th` (same base URL) | [8] |
| Licence | Code and weights: "Demucs is released under the MIT license as found in the LICENSE file." | [2] |
| Parameters, segment | 42M (as listed in a comparison table [18]); 7.8 s maximum segment | [18][2] |
| One checkpoint for 4 stems? | `htdemucs`: yes. `htdemucs_ft`: four specialist models, each outputs 4 stems but only its target stem is good; "separation will take 4 times more time" | [2][8] |
| Apple Silicon | `demucs-mlx` 1.6.1 (MIT): `htdemucs` 114x real time, 120 s in 1.05 s warm, M4 Max 40-core GPU, MLX 0.32.3. PyTorch MPS 42x, CPU 6x. `--stem` runs one `htdemucs_ft` specialist only | [11] |
| Multisong (bass / drums / other / vocals, avg derived) | `htdemucs4` 11.77 / 10.89 / 5.74 / 8.25, avg 9.16. `htdemucs_ft` 12.04 / 11.26 / 5.75 / 8.34, avg 9.35 | [4] |

### 2.2 SCNet

| Item | Value | Source |
|---|---|---|
| SDR, MUSDB18-HQ test, no extra data (All / drums / bass / other / vocals) | SCNet 9.00 / 10.51 / 8.82 / 6.76 / 9.89 (10.08M params). SCNet-large 9.69 / 10.98 / 9.49 / 7.44 / 10.86 (41.2M) | [16] |
| With extra data | SCNet +235 songs 9.25. SCNet-large +235 songs 9.92 / 11.23 / 9.86 / 7.51 / 11.1 | [16] |
| MSST community checkpoints, MUSDB-only (avg: bass / drums / vocals / other) | Small 9.03: 8.89 / 10.44 / 9.90 / 6.89. Large (starrytong) 9.70: 9.38 / 11.15 / 10.94 / 7.31. XL 9.80: 9.23 / 11.51 / 11.05 / 7.41. **XL IHF 10.08: 9.23 / 11.81 / 11.42 / 7.88**. Masked XL IHF 9.82 | [8][19] |
| Weights, 4 stems | Yes, one checkpoint with all four stems. Official: Google Drive links for SCNet and SCNet-large in https://github.com/starrytong/SCNet . Community: MSST releases | [20][8] |
| Download location (XL IHF) | https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.15/model_scnet_ep_36_sdr_10.0891.ckpt (214,063,778 bytes) and config https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.15/config_musdb18_scnet_xl_more_wide_v5.yaml | [19] |
| Licence | Code (starrytong): "MIT License, Copyright (c) 2024 starrytong". MSST code: "MIT License, Copyright (c) 2024 Roman Solovyev (ZFTurbo)". **Weights: no licence stated** in the MSST README, pretrained-models doc or release notes I read, nor on the SCNet page | [20][21][8][19] |
| Parameters, segment | XL IHF about 53M (derived: 214 MB checkpoint / 4.1 bytes per parameter, calibrated on SCNet-large's 168.9 MB / 41.2M). Training chunk 485,100 samples = 11.0 s; the paper also trains on 11 s segments | [19][16] |
| Architecture note | The separation module is a bidirectional LSTM dual-path (`models/scnet/separation.py`). A transformer variant (`scnet_tran`) exists | [22] |
| Speed | Paper: CPU RTF 0.669 s for SCNet (small) vs 1.38 s for HT Demucs, so 48% of HT Demucs time; hardware not stated in the text I read. No figure for large or XL. **No Apple Silicon timing, no MLX or Core ML port of the MUSDB SCNet found.** MSST's `inference.py` selects `mps` when CUDA is absent | [16][23] |
| Multisong (bass / drums / other / vocals, avg derived) | XL IHF 4 stems: 11.94 / 11.58 / 6.49 / 9.69, avg 9.93. `scnet_xl_4stem_starrytong` 11.77 / 11.41 / 6.10 / 9.25, avg 9.63 | [4][24] |

Other SCNet checkpoints on Hugging Face, none with published scores: `Aname-Tommy/Huge-SCNet-4stems` (Apache-2.0 on the card, five 395 MB checkpoints, about 96M parameters derived, config chunk 661,500 = 15 s) [25]. `Ocean82/scnet-base` (Core ML, MIT on the card, "~10M params", "Est. RTF 0.6"; the card links a framework repo that now returns 404, so the RTF is unverified) [26].

### 2.3 BS-RoFormer

| Item | Value | Source |
|---|---|---|
| SDR, MUSDB18-HQ test (paper) | No extra data, LL=6 (72.2M): 9.80 avg; vocals 10.66, bass 11.31, drums 9.49, other 7.73. With 500 extra songs, LL=12 (93.4M): 11.99 avg; 12.72 / 13.32 / 12.91 / 9.01 (V/B/D/O). The paper says the extra-data system "ranked the first place" in SDX'23; I read the 9.97 dB SAMI-ByteDance entry on Leaderboard C (a different test set) as that system, which the paper's text does not state outright | [14][27] |
| Weights, 4 stems | **None official that I found.** The paper makes no release statement [14], and the lucidrains README credits ZFTurbo for the public weights [28]. Community: ZFTurbo `model_bs_roformer_ep_17_sdr_9.6568.ckpt`, one checkpoint for 4 stems | [8] |
| Community 4-stem metrics | ZFTurbo, MUSDB-only: 9.65 avg on MUSDB test (bass 8.48, drums 11.61, vocals 11.08, other 7.44); Multisong 9.38 | [8] |
| Download location | https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.12/model_bs_roformer_ep_17_sdr_9.6568.ckpt (527,385,512 bytes) and config `.../v1.0.12/config_bs_roformer_384_8_2_485100.yaml` | [29] |
| Licence | lucidrains code: "MIT License, Copyright (c) 2023 Phil Wang". MSST code MIT. Weights: none stated | [30][21] |
| Parameters, segment | Paper: 72.2M per stem model, 8 s segments, 4 s hop; the SDX'23 system trained separate models for vocals, bass and drums and derived other by subtraction. ZFTurbo 4-stem model: dim 384, depth 8, 11.0 s chunk, about 129M parameters (derived from file size) | [14][29] |
| One checkpoint for 4 stems? | Paper: no, one model per stem. ZFTurbo's: yes (`num_stems: 4`) | [14][29] |
| Apple Silicon | No timing for any 4-stem BS-RoFormer. `mlx-audio-separator` reports MLX 2.16x faster than `audio-separator` for a 12.97-SDR vocals BS-RoFormer on an M4 mini, but no absolute times | [6] |

**BS-Roformer-SW (jarredou), 6 stems: bass, drums, other, vocals, guitar, piano.**

| Item | Value | Source |
|---|---|---|
| Quality | Multisong: bass 14.62, drums 14.11, other 8.72, vocals 11.30 (avg 12.19, derived). Added 2025-06-05, single model, chunk size listed as 882,000. MUSDB18-HQ test: **no published figure** | [3] |
| Training data | Not stated anywhere I found (unverified). MVSEP's earlier note says its BS-Roformer was fine-tuned "on our dataset" | [31] |
| Weights | Yes. `BS-Roformer-SW.ckpt` (699,412,152 bytes) and `BS-Roformer-SW.yaml` (4,653 bytes) at https://github.com/nomadkaraoke/python-audio-separator/releases/download/model-configs/BS-Roformer-SW.ckpt . Same bytes at https://huggingface.co/enerjazzer/BS-ROFO-SW-Fixed (a mirror of jarredou's `BS-ROFO-SW-Fixed`, which returns 401 to me) | [32][5] |
| Licence | Mirror card: `license: unknown`; text: "Edited version of that checkpoint to allow its use with UVR and MSST." A toolkit that recommends it warns that its own MIT code licence "should not be read as permission to use that checkpoint commercially". An ONNX conversion of it carries `license: mit` on its own card, which cannot override the upstream's unknown | [5][33][34] |
| Parameters, segment | Config: dim 256, depth 12, 6 stems, `chunk_size: 588800` (13.35 s; `#882000` left as a comment), STFT 2048 / hop 512, inference `num_overlap: 2`. About 170M parameters (derived from file size). An ONNX export traces a fixed 4 s chunk; its card says smaller T is faster per second but "quality drops" | [32][34] |
| 4 stems from one checkpoint? | One checkpoint gives all six; fold guitar and piano into "other", or take other = mix - vocals - bass - drums (what the Quatra MVSEP entry does [17]) | [17] |
| Apple Silicon | `mlx-audio-separator` lists `BS-Roformer-SW.ckpt` as supported and ships SW-specific tuning scripts, but publishes **no SW timing**. MVSEP entry 10674 "Quatra - BS-RoFormer SW (MLX, 13.35 s / 75 % overlap / TTA)" scored 14.74 / 14.20 / 8.81 / 11.37 on Multisong (avg 12.28, derived) on Apple Silicon (chip not named, no timing, no repo link) | [6][17] |
| My cost estimate (**derived, low confidence**) | From the config: about 6.8 TFLOP for one 13.35 s chunk, which is about 3.5 TFLOP for a 7.8 s window (transformer layers, quadratic time attention and 6 mask heads, counted by hand). The budget is 0.76 s per window, so this needs roughly 5 TFLOP/s of sustained fp32 matmul. I did not look up the M5 Pro's rate, so the real answer could be on either side | derived from [32] |

### 2.4 Mel-Band RoFormer

| Item | Value | Source |
|---|---|---|
| SDR, MUSDB18-HQ test, no extra data (paper) | LL=6 (84.2M): vocals 11.21, bass 9.64, drums 9.91, other 7.81, avg 9.64. LL=9 (94.8M): vocals 11.60, drums 9.34, other 7.93; bass and average not reported | [15] |
| Weights, 4 stems | None official. Community: ZFTurbo's experiment table, best run 8.94 avg (dim 384, depth 8, 485,100-sample chunk, skip connection), flagged "probably undertrained", "Very big file", weights in two zip parts. `AEmotionStudio/roformer-models` mirrors a `mel_band_roformer/4stems_large` (dim 384, depth 8, chunk 661,500 = 15 s) with no stated metrics (unverified that it is the 8.94 run) | [9][35] |
| Licence | Code via lucidrains (MIT). Kimberley's vocals checkpoint card: `license: mit`. The mirror card: "MIT, same as all upstream model releases" (the mirror's claim, not the weights' owners') | [30][36][35] |
| Parameters, segment | Kimberley's vocals checkpoint: 228M parameters, 8 s chunk (352,800 samples) | [37][38] |
| Apple Silicon | **Only measured Apple data for any RoFormer.** `fast-melroformer` (MIT): that 228M vocals checkpoint, 3-minute clip, 8 GB fanless M3 MacBook Air, macOS 15: stock PyTorch fp32 on MPS 1.08x real time; fp16 1.35x; RoPE/RMSNorm fixes 2.19x; custom Metal kernels 2.62x; transformer stack on the Neural Engine 4.19x. Output differs from fp32 (56.5 dB SDR vs fp32). One vocals stem only | [37] |

Conclusion: no public Mel-Band 4-stem checkpoint beats HTDemucs. Mel-Band RoFormer is a vocals specialist in practice.

### 2.5 Newer 2025-2026 models

| Model | 4-stem claim | Weights and licence | Verdict |
|---|---|---|---|
| Moises-Light (WASPAA 2025, arXiv 2510.06785) | 9.96 avg on MUSDB-HQ, no extra data (vocals 10.92, drums 10.93, bass 10.04, other 7.95), 5M parameters per stem x 4 models, 9 s chunks. With 235 extra MoisesDB songs the paper shows per-stem values only | **No official code or weights** ("The paper does not release code"). An unofficial MIT PyTorch reimplementation exists (`pip install moises-light`), without pretrained weights | Not usable [39][40] |
| Mini-BS-RoFormer 18M / V2 46.8M / V2.5 46.2M (HiDolen, 2025-2026) | Card SDR 9.01 / 10.03 / 10.09 on "the val set of MUSDB18HQ". 4 stems from one checkpoint. V2.5: 8 s chunk | 18M and V2.5: `license: mit`. V2 46.8M: `cc-by-nc-4.0`. **V2 and V2.5 were trained on the train and test sets of MUSDB18-HQ** [12][13], so their scores cannot be compared with held-out numbers. 18M's card says only "trained with MUSDB18HQ" | Interesting size, unproven quality. V2 reports 8,343 GFLOPs per 30 s (author's count) [12] |
| BS-Roformer-FNO-SC (EXVERIA1015, 2026-04) | MVSEP Multisong 13.41 / 13.03 / 8.13 / 10.59 (avg 11.29, derived), 4-stem | I found no weights or repo (MVSEP page only) | Not usable [41] |
| MLSLABS WCJ V2, "BS²", "Superoformer rev2" | Multisong avg 12.1-12.3 (derived), 2025-2026 | Entry pages carry only a name and no links; these appear to be BS-Roformer-SW derivatives | Not usable [4][17] |
| Band-SCNet (Interspeech 2025), RT-STT, HS-TasNet | Causal real-time models; 7.79 dB with 2.59M parameters (search snippet only, **unverified** (PDF unreadable)) | See earlier doc for the other two | Below HTDemucs [42] |
| "Demucs 5" row on the Multisong leaderboard | 12.01 / 11.14 / 5.63 / 8.32, i.e. htdemucs_ft-level | I found no Demucs v5 release; the row's provenance is unknown (unverified) | Ignore [4] |

### 2.6 MVSEP and Ultimate Vocal Remover

- **MVSEP is a web service.** Its algorithms page lists exactly one plain 4-stem single model, Demucs4 HT (`htdemucs_ft` 12.05 / 11.24 / 5.74 / 8.33 on Multisong), plus ensembles that call `htdemucs`-family models. The ensemble (2025.06.30) scores 14.85 / 14.33 / 9.01 / 11.93 on Multisong. It states no weight licence or download links [3][43]. Its leaderboard cites public models by name where they exist (see §3).
- **UVR** (Ultimate Vocal Remover): "UVR's core developers trained all of the models provided in this package (except for the Demucs v3 and v4 4-stem models)" [44]. UVR's own trained models are 2-stem. Its download list (`download_checks.json` in TRvlvr/application_data, `other_network_list_new`, checked 2026-10-27) also offers four third-party 4-stem SCNet checkpoints hosted on ZFTurbo's releases: SCNet_MUSDB18 (starrytong), SCNet Large (starrytong), SCNet Large `model_scnet_sdr_9.3244`, and SCNet-XL `model_scnet_ep_54_sdr_9.8051` (216 MB). So UVR's 4-stem output is Demucs or SCNet. Licence text: "The Ultimate Vocal Remover GUI code is MIT-licensed... please honor the MIT license by providing credit to UVR and its developers" [44]. `python-audio-separator`'s model catalogue lists one multi-stem roformer, BS-Roformer-SW [32]; the other roformers there are 2-stem.
- **SDX'23 (the last major challenge with a 4-stem leaderboard):** Leaderboard C, any training data: SAMI-ByteDance (BS-RoFormer) 9.97, ZFTurbo 9.26, kimberley_jensen 9.18, kuielab 8.97. Only ZFTurbo's code is stated to be public [27]. I found no newer public 4-stem challenge with weights.

## 3. Same-benchmark comparison (MVSEP Multisong, bass / drums / other / vocals, SDR dB)

All rows are from the quality-checker entries cited; averages are mine. "Public" means I found downloadable weights.

| Model | Bass | Drums | Other | Vocals | Avg | Public weights | Trained on |
|---|---|---|---|---|---|---|---|
| `htdemucs` (Demucs4) | 11.77 | 10.89 | 5.74 | 8.25 | 9.16 | yes (MIT) | MUSDB + 800 extra |
| `htdemucs_ft` | 12.04 | 11.26 | 5.75 | 8.34 | 9.35 | yes (MIT) | same |
| ZFTurbo BS Roformer (MUSDB18) | 11.08 | 11.29 | 5.96 | 9.19 | 9.38 | yes (no weight licence) | MUSDB only |
| `scnet_xl_4stem_starrytong` | 11.77 | 11.41 | 6.10 | 9.25 | 9.63 | yes (no weight licence) | MUSDB only (unverified) |
| **SCNet XL IHF 4 stems** | 11.94 | 11.58 | 6.49 | 9.69 | **9.93** | yes (no weight licence) | MUSDB only [19] |
| BS-Roformer-FNO-SC | 13.41 | 13.03 | 8.13 | 10.59 | 11.29 | no | not stated |
| **BS Roformer SW (6 stems)** | 14.62 | 14.11 | 8.72 | 11.30 | **12.19** | yes (licence unknown) | not stated |
| Quatra BS-RoFormer SW (MLX, TTA x3, 75% overlap) | 14.74 | 14.20 | 8.81 | 11.37 | 12.28 | no | same as SW |

Reading: the gap from `htdemucs_ft` to SCNet XL IHF is +0.6 dB, mostly vocals (+1.35) and other (+0.74). The gap to SW is +2.8 dB, spread evenly over the stems (+2.6 bass, +2.9 drums, +3.0 other, +3.0 vocals). SW's training data is undisclosed, and Multisong is MVSEP's own set, so some of that gap may be a data advantage or leakage; I cannot rule that out. The SW row is also not tied to any paper (unverified beyond MVSEP's page).

## 4. What exists for Apple Silicon (measured vs claimed)

| What | Hardware named | Result | Kind |
|---|---|---|---|
| `demucs-mlx`, `htdemucs` | M4 Max 40-core | 114x real time (1.05 s per 120 s) | measured, README [11] |
| `mlx-audio-separator` embedded Demucs, 2 shifts | M4 Max | 30 s in 0.931 s, 60 s in 1.742 s | measured, tuning doc [45] |
| `mlx-audio-separator`, MLX vs `audio-separator`, 12-song MUSDB subset | M4 mini | `htdemucs_ft` 1.40x, BS-Roformer (vocals) 2.16x, Mel-Band (instrumental) 2.50x faster | relative only [6][46] |
| 228M Mel-Band vocals, PyTorch MPS stock | 8 GB M3 Air | 1.08x real time; 4.19x with Neural Engine port | measured, one machine [37] |
| `mlx-audio-separator`, BS-Roformer compile switch | "Apple silicon, 128 GB" | 9.038 s without vs 7.343 s with `mx.compile`; input length not stated, so unusable as a rate | [45] |
| SCNet, any | none | none published | gap |
| BS-Roformer-SW, any | none | none published (MVSEP MLX entry has no timing) | gap |
| Mini-BS-RoFormer Core ML / MLX (schism-audio) | n/a | the Hugging Face repos no longer resolve (API returns no model) | gone [47] |

`mlx-audio-separator` 0.1.20 is MIT, needs macOS 13+, Python 3.10+, and states a 163-model catalogue test pass [6][46]. It works on files, not buffers (its documented Python API is `Separator().load_model(); separate("song.mp3")`), so per-window use needs 7.8 s WAV snippets or its undocumented internals [46].

## 5. Licence summary

| Candidate | Code | Weights | Usable for a personal, undistributed install? |
|---|---|---|---|
| `htdemucs`, `htdemucs_ft` | MIT [2] | MIT [2] | yes |
| SCNet (starrytong, MSST) | MIT [20][21] | not stated | personal use is low risk; unclear for redistribution (not legal advice) |
| ZFTurbo BS Roformer, SCNet checkpoints | MIT [21] | not stated | same |
| BS-Roformer-SW | MIT (lucidrains / toolkits) | `unknown` [5] | personal yes; cannot be shipped in the repo or fetched by a public installer without asking the author |
| Mini-BS-RoFormer 18M, V2.5 | n/a | MIT [12][13] | licence fine; quality unproven |
| Mini-BS-RoFormer V2 | n/a | CC-BY-NC-4.0 [12] | non-commercial only |
| Moises-Light | MIT (unofficial reimplementation) [40] | none exist | no |
| UVR models | MIT GUI [44] | credit required for third-party apps [44] | own models 2-stem; 4-stem via Demucs or third-party SCNet |

For a public repo, keep every weight out of git and fetch at install time, as the earlier doc already recommends. The weights with no stated licence should not be fetched by a public installer without confirming with their author.

## 6. Ranked shortlist: what to time on this Mac

Target: 7.8 s window, 1 s hop, budget about 0.76 s of compute per hop (4x the current 0.19 s). Time warm, after one discarded call, with the GPU otherwise idle (`demucs-mlx` lost 40% of throughput to other apps [11]). Cut a test window first: `ffmpeg -ss 30 -t 7.8 -i song.wav win.wav`.

### 1. BS-Roformer-SW via `mlx-audio-separator`

Why first: largest quality gap (+2.8 dB on Multisong), the only high-quality candidate with an MLX loader on PyPI, and the install is two commands. What would rule it out: >0.76 s per 7.8 s window, or poor quality when run on a 7.8 s window instead of 13.35 s (never measured). Risk: weights licence is `unknown`.

```
uv venv --python 3.12 /tmp/sw-test            # any Python >= 3.10
uv pip install --python /tmp/sw-test/bin/python "mlx-audio-separator[convert]"
/tmp/sw-test/bin/mlx-audio-separator --list_models | grep -i "SW"
# first run downloads and converts the checkpoint into ~/.cache/mlx-audio-separator/models
/tmp/sw-test/bin/mlx-audio-separator win.wav -m BS-Roformer-SW.ckpt --output_format FLAC
# timing: its own harness
/tmp/sw-test/bin/mlx-audio-separator --benchmark win.wav --benchmark_warmup 1 --benchmark_repeats 3 --benchmark_profile -m BS-Roformer-SW.ckpt
```

Checkpoint if fetching by hand: https://github.com/nomadkaraoke/python-audio-separator/releases/download/model-configs/BS-Roformer-SW.ckpt plus `.../BS-Roformer-SW.yaml` (same bytes at https://huggingface.co/enerjazzer/BS-ROFO-SW-Fixed/resolve/main/BS-Rofo-SW-Fixed.ckpt). The config sets `chunk_size: 588800`, so a 7.8 s snippet is padded to 13.35 s unless you lower it in the YAML (untested; shorter T is faster but RoPE and training length are 13.35 s). Output is six stems; sum guitar and piano into other. Unverified: the `--benchmark` flags are quoted from the README and I did not check they accept `-m`.

### 2. SCNet XL IHF via ZFTurbo's MSST (PyTorch MPS)

Why second: the best MUSDB-only 4-stem model (10.08 dB; +0.6 dB over `htdemucs_ft` on Multisong), one checkpoint, about 53M parameters, an 11 s window close to 7.8 s. Costs: no MLX port, so it runs on PyTorch MPS with bidirectional LSTMs (speed on MPS unknown); no weight licence. What would flip the order: if SW misses the budget by more than 2x, this becomes first.

```
git clone https://github.com/ZFTurbo/Music-Source-Separation-Training.git
cd Music-Source-Separation-Training
uv venv --python 3.11 /tmp/msst-test
# Do not install requirements.txt wholesale: it pins wxpython, pyaudio, sageattention, bitsandbytes.
# Minimal set below is inferred from the imports of inference.py / utils (UNVERIFIED, nothing was installed):
uv pip install --python /tmp/msst-test/bin/python torch torchaudio numpy soundfile librosa pyyaml omegaconf ml_collections einops tqdm matplotlib
curl -L -o scnet_xl_ihf.yaml https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.15/config_musdb18_scnet_xl_more_wide_v5.yaml
curl -L -o scnet_xl_ihf.ckpt https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.15/model_scnet_ep_36_sdr_10.0891.ckpt
mkdir win_in && cp win.wav win_in/
/tmp/msst-test/bin/python inference.py --model_type scnet --config_path scnet_xl_ihf.yaml --start_check_point scnet_xl_ihf.ckpt --input_folder win_in --store_dir out
```

`inference.py` picks `mps` itself when CUDA is absent [23]. The `demix` function reads `config.inference.chunk_size` if present, else `audio.chunk_size` (485,100 here); to test a 7.8 s window add `chunk_size: 343980` under `inference:` and set `num_overlap: 1` (SCNet's padding at that length is untested). The config's `inference.num_overlap: 4` runs four passes per chunk, so time with `num_overlap: 1` to match a streaming hop. Dependency conflicts on macOS are my expectation, not an observation.

### 3. `htdemucs_ft` in `demucs-mlx` (already integrated)

Why third: it measures the 4x ceiling directly and needs no new code. +0.19 dB on Multisong (+0.2 dB in the paper), so it is the weakest of the three, and it is the model-family fallback if both new ones miss the budget.

```
demucs-mlx -n htdemucs_ft win.wav        # four specialist models, about 4x the htdemucs cost
```

**Not shortlisted:** Mini-BS-RoFormer V2.5-46.2M (https://huggingface.co/HiDolen/Mini-BS-RoFormer-V2.5-46.2M, MIT, 8 s chunk, 4 stems): trained on MUSDB18-HQ train+test, so there is no honest quality number; worth timing only if you want MIT weights and will measure quality yourself on songs outside MUSDB. ZFTurbo's BS Roformer MUSDB (9.38 Multisong) is no better than `htdemucs_ft` and about 129M parameters.

## 7. Unverified, and where the evidence is thin

- No timing exists for SCNet or BS-Roformer-SW on any Apple chip. The SW cost estimate in §2.3 is my hand count and could be off by 3x either way.
- No quality measurement of any candidate on a 7.8 s window. SCNet trained on 11 s, SW on 13.35 s, BS-RoFormer on 8 s.
- SW's training data and licence are unknown. Multisong is MVSEP's own set and SW could have seen similar material.
- SCNet XL IHF's training set is stated as MUSDB18 only on its release page [19]; I did not check for leakage between MUSDB train and the Multisong files.
- Several figures came through a fetch tool that summarised pages (Mel-RoFormer and SCNet and HT Demucs paper tables, MSST pretrained table). The MSST table I read raw; the arXiv tables I did not. The BS-RoFormer LL=6 value differs between two papers (9.80 vs 9.92), which I could not reconcile.
- The Band-SCNet figure is from a search snippet; the PDF would not parse.
- `Ocean82/scnet-base`'s "Est. RTF 0.6" and the schism-audio Core ML ports cannot be checked (repos gone).
- The Apple Logic Pro Stem Splitter appears to be a BS-RoFormer: a Hugging Face repo (`ChanTrail/BS-RoFormer`) holds a 699.4 MB `logic_bs_roformer.ckpt`, and MVSEP has a "Logic BS Roformer" entry at 14.57 / 14.05 / 8.66 / 11.27 [4][48]. Those would be weights taken from a proprietary app; I did not pursue them and recommend against using them.

## Sources

1. Rouard, Massa, Défossez, "Hybrid Transformers for Music Source Separation", Table 1 — https://arxiv.org/html/2211.08553
2. facebookresearch/demucs README (SDR statement, model list, "4 times more time", license) — https://github.com/facebookresearch/demucs/blob/main/README.md
3. MVSEP algorithms page (Demucs4 HT row, ensemble row, BS Roformer SW row) — https://mvsep.com/en/algorithms ; SW entry 8374 — https://mvsep.com/quality_checker/entry/8374
4. MVSEP Multisong leaderboard, pages 1 and 8 — https://www.mvsep.com/quality_checker/multisong_leaderboard and https://www.mvsep.com/quality_checker/multisong_leaderboard?page=8
5. `enerjazzer/BS-ROFO-SW-Fixed` model card (`license: unknown`, 699,412,152-byte checkpoint) — https://huggingface.co/enerjazzer/BS-ROFO-SW-Fixed (API: https://huggingface.co/api/models/enerjazzer/BS-ROFO-SW-Fixed?blobs=true)
6. ssmall256/mlx-audio-separator README and PyPI page — https://github.com/ssmall256/mlx-audio-separator , https://pypi.org/project/mlx-audio-separator/
7. SCNet XL IHF release v1.0.15 (training on MUSDB18 only, metrics) — https://api.github.com/repos/ZFTurbo/Music-Source-Separation-Training/releases/tags/v1.0.15
8. MSST pretrained models doc — https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/main/docs/pretrained_models.md
9. MSST Mel-RoFormer experiments table — https://github.com/ZFTurbo/Music-Source-Separation-Training/blob/main/docs/mel_roformer_experiments.md
10. MSST README (supported model types) — https://github.com/ZFTurbo/Music-Source-Separation-Training
11. ssmall256/demucs-mlx README (114x, model list, `--stem`) — https://github.com/ssmall256/demucs-mlx ; PyPI https://pypi.org/project/demucs-mlx/
12. `HiDolen/Mini-BS-RoFormer-V2-46.8M` card (CC-BY-NC-4.0, GFLOPs, train+test training) — https://huggingface.co/HiDolen/Mini-BS-RoFormer-V2-46.8M ; 18M card https://huggingface.co/HiDolen/Mini-BS-RoFormer-18M
13. `HiDolen/Mini-BS-RoFormer-V2.5-46.2M` card (MIT, 8 s chunk, train+test) — https://huggingface.co/HiDolen/Mini-BS-RoFormer-V2.5-46.2M
14. Lu et al., "Music Source Separation with Band-Split RoPE Transformer" — https://arxiv.org/html/2309.02612 (abstract https://arxiv.org/abs/2309.02612)
15. Wang et al., "Mel-Band RoFormer for Music Source Separation" — https://arxiv.org/html/2310.01809
16. Tong et al., "SCNet: Sparse Compression Network for Music Source Separation" — https://arxiv.org/html/2401.13276 (abstract https://arxiv.org/abs/2401.13276)
17. MVSEP Quatra SW (MLX) entry 10674 — https://mvsep.com/quality_checker/entry/10674 ; entries 8377 https://mvsep.com/quality_checker/entry/8377 , 10913 https://mvsep.com/quality_checker/entry/10913 , 10791 https://mvsep.com/quality_checker/entry/10791
18. Moises-Light paper, Tables 4 and 5 (HT Demucs 42M) — https://arxiv.org/html/2510.06785v1
19. MSST releases: v1.0.15 config/checkpoint — https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/tag/v1.0.15 ; v1.0.13 (XL), v1.0.17 (masked XL IHF) via https://api.github.com/repos/ZFTurbo/Music-Source-Separation-Training/releases
20. starrytong/SCNet README and LICENSE — https://github.com/starrytong/SCNet
21. MSST LICENSE — https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/main/LICENSE
22. MSST SCNet source (LSTM dual-path) — https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/main/models/scnet/separation.py
23. MSST `inference.py` (MPS device selection) and `utils/model_utils.py` (`demix` chunking) — https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/main/inference.py
24. MVSEP SCNet XL IHF 4 stems entry 8446 — https://mvsep.com/quality_checker/entry/8446
25. `Aname-Tommy/Huge-SCNet-4stems` — https://huggingface.co/Aname-Tommy/Huge-SCNet-4stems
26. `Ocean82/scnet-base` (Core ML) — https://huggingface.co/Ocean82/scnet-base
27. Fabbro et al., Sound Demixing Challenge 2023 – Music Demixing Track — https://arxiv.org/html/2308.06979
28. lucidrains/BS-RoFormer README (credits ZFTurbo for weights) — https://github.com/lucidrains/BS-RoFormer
29. MSST release v1.0.12 (BS Roformer MUSDB18HQ) — https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/tag/v1.0.12
30. lucidrains/BS-RoFormer LICENSE — https://raw.githubusercontent.com/lucidrains/BS-RoFormer/main/LICENSE
31. MVSEP news 43 (BS Roformer fine-tuned on MVSEP's dataset) — https://mvsep.com/news/43
32. `BS-Roformer-SW.yaml` and checkpoint release assets; python-audio-separator catalogue — https://github.com/nomadkaraoke/python-audio-separator/releases/tag/model-configs ; https://raw.githubusercontent.com/nomadkaraoke/python-audio-separator/main/audio_separator/models.json
33. openmirlab/bs-roformer-infer (licence warning, SW as default) — https://github.com/openmirlab/bs-roformer-infer
34. `elicwhite/bs-roformer-sw-6stem-onnx` (MIT card, 4 s trace, 6 stems) — https://huggingface.co/elicwhite/bs-roformer-sw-6stem-onnx
35. `AEmotionStudio/roformer-models` — https://huggingface.co/AEmotionStudio/roformer-models
36. KimberleyJensen/Mel-Band-Roformer-Vocal-Model README; HF card `KimberleyJSN/melbandroformer` — https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model , https://huggingface.co/KimberleyJSN/melbandroformer
37. aipdv/fast-melroformer (M3 Air timings, 228M, MIT) — https://github.com/aipdv/fast-melroformer ; issue https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model/issues/23
38. Kimberley README (chunk_size 352800 = 8 s) — see 36
39. Moises-Light paper — see 18 ; abstract https://arxiv.org/abs/2510.06785
40. crlandsc/moises-light README and LICENSE — https://github.com/crlandsc/moises-light
41. MVSEP BS-Roformer-FNO-SC entry 9933 — https://mvsep.com/quality_checker/entry/9933
42. Band-SCNet, Interspeech 2025 — https://www.isca-archive.org/interspeech_2025/yang25d_interspeech.pdf (PDF not parsed; figures from a search snippet)
43. MVSEP quality checker landing — https://de.mvsep.com/en/quality_checker
44. Anjok07/ultimatevocalremovergui README (licence, 4-stem = Demucs) — https://github.com/Anjok07/ultimatevocalremovergui
45. mlx-audio-separator tuning doc — https://github.com/ssmall256/mlx-audio-separator/blob/main/docs/tuning.md
46. mlx-audio-separator release validation — https://github.com/ssmall256/mlx-audio-separator/blob/main/docs/release-validation.md
47. schism-audio MLX / Core ML repos (not resolvable) — https://huggingface.co/schism-audio/mini-bs-roformer-18m-mlx , https://huggingface.co/schism-audio/mini-bs-roformer-v2-coreml
48. `ChanTrail/BS-RoFormer` (file list incl. `logic_bs_roformer.ckpt`) — https://huggingface.co/ChanTrail/BS-RoFormer

## Measured on the author's Mac (M5 Pro), 2026-10-27

Offline, in a scratch folder; nothing of stemmix touched. Speed is one separation of a 7.8 s stereo window (stemmix's window), warm, median of 10-20 runs; stemmix runs one window per second of music. Quality is median SDR on the 50 MUSDB18 test songs of the free 7-second preview set (`musdb` package, compressed audio), each clip separated in one window; simple SDR = 10·log10(Σref² / Σ(ref−est)²). Absolute numbers are rougher than published MUSDB18-HQ figures; the comparison between rows is the point.

| Model (source) | Runtime | Params | ms per 7.8 s window | vs htdemucs | Drums | Bass | Other | Vocals |
|---|---|---|---|---|---|---|---|---|
| `htdemucs` (current) | demucs-mlx (MLX) | ~42 M | 162 | 1.0x | 9.5 | 9.1 | 5.2 | 8.9 |
| `htdemucs_ft` | demucs-mlx (MLX) | 4 × ~42 M | 646 | 4.0x | 9.8 | 9.1 | 5.2 | 8.4 |
| SCNet base, starrytong (UVR list) | PyTorch 2.14 MPS | 10.6 M | 121 | 0.75x | 9.3 | 8.3 | 6.3 | 9.6 |
| SCNet Large `sdr_9.3244` (UVR list) | PyTorch 2.14 MPS | 42.2 M | 431 | 2.7x | 10.2 | 7.9 | 6.8 | 10.8 |
| SCNet XL IHF `sdr_10.0891` | PyTorch 2.14 MPS | 53.5 M | 969 (fp16: 883) | 6.0x | 10.9 | 8.4 | 7.3 | 11.4 |

- stemmix plays "other" as the mix minus the other three; that residual scored within 0.2 dB of each model's own "other".
- SCNet's time is mostly its LSTM layers (about half of a run in the profiler), which step through the audio one frame at a time; half precision saved 8%. An MLX port would not obviously remove that cost.
- Every SCNet loses 0.8-1.2 dB on bass against htdemucs, and gains on vocals and "other".
- Not measured: BS-Roformer-SW (699 MB, ~175 M parameters, licence unknown), expected far slower than the 4x limit the author set ("if the model is 4x slower its not usable").
