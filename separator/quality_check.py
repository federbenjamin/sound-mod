"""Audio quality check over a `stemmix --simulate` run with `"stemsOut"` set and no song skips.

Usage: uv run --project separator python separator/quality_check.py <input.f32> <output.f32> <stemsOut prefix>

Prints three measures:
- null: with all four stems audible the output must equal the recording it played (other = mix - the rest);
  the largest difference after the stem ramp and the transport fade have settled.
- sdr: each stem as streamed (7.8 s windows, 1 s slices) against the same model separating the whole recording
  at once, in dB (higher is closer; this is what the sliding window costs, not the model's own error).
- seams: streamed-vs-whole error energy by position inside the 1 s slice, in 10 ms bins: the loudest bin against
  the median. A spike near 0 ms would be a slice boundary heard as a click.
"""
import sys

import numpy as np
import soxr

from stemmix_separator import MODEL_RATE, Separator, fit

RATE = 48000
HOP = RATE  # Config.hopSeconds
SETTLE = int(1.5 * RATE)  # stem ramp (1 s) and transport fade, with margin
NAMES = ["drums", "bass", "vocals"]


def load(path, dtype, width):
    data = np.fromfile(path, dtype=dtype)
    return data.reshape(-1, *width) if width else data


def whole_song_stems(mix):
    model = Separator().model
    at_model = soxr.resample(mix, RATE, MODEL_RATE, quality="HQ")
    _, separated = model.separate_tensor(np.ascontiguousarray(at_model.T))
    return {name: fit(soxr.resample(np.ascontiguousarray(separated[name].T), MODEL_RATE, RATE, quality="HQ"), len(mix)) for name in NAMES}


def sdr(reference, estimate):
    noise = np.sum((reference - estimate) ** 2)
    return float("inf") if noise == 0 else 10 * np.log10(np.sum(reference**2) / noise)


def main(input_path, output_path, prefix):
    mix = load(input_path, "<f4", (2,))
    out = load(output_path, "<f4", (2,))
    pos = load(prefix + ".pos.i32", "<i4", None)
    streamed = load(prefix + ".stems.f32", "<f4", (3, 2))

    played = np.nonzero(pos >= 0)[0]
    played = played[played >= played[0] + SETTLE]
    src = pos[played]
    print(f"played {len(played) / RATE:.1f} s after settling, recording frames {src[0]}..{src[-1]}")

    print(f"null: max |output - recording| = {np.abs(out[played] - mix[src]).max():.2e}")

    reference = whole_song_stems(mix)
    error = np.zeros(len(played))
    for i, name in enumerate(NAMES):
        ref, est = reference[name][src], streamed[played, i]
        print(f"sdr {name}: {sdr(ref, est):.1f} dB")
        error += np.sum((ref - est) ** 2, axis=1)
    ref_other = mix[src] - sum(reference[n][src] for n in NAMES)
    est_other = mix[src] - streamed[played].sum(axis=1)
    print(f"sdr other: {sdr(ref_other, est_other):.1f} dB")

    phase = (src - pos[pos >= 0][0]) % HOP
    bins = np.bincount(phase * 100 // HOP, weights=error, minlength=100) / np.maximum(np.bincount(phase * 100 // HOP, minlength=100), 1)
    loudest = int(np.argmax(bins))
    print(f"seams: loudest 10 ms bin at {loudest * 10} ms into the slice, {bins[loudest] / np.median(bins):.2f}x the median bin")


if __name__ == "__main__":
    main(*sys.argv[1:4])
