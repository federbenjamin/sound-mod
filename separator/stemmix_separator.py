"""The stemmix separator: HTDemucs (demucs-mlx) behind a stateless pipe protocol.

The daemon spawns this process and owns all audio. Each request carries one whole window and names the slice
and stems it wants back; nothing is kept between requests. Frame layout and header shapes: contract/README.md.
"""
import json
import os
import struct
import sys
import time

import numpy as np
import soxr

MODEL = "htdemucs"
MODEL_RATE = 44100


def read_exact(stream, n):
    chunks = []
    while n > 0:
        chunk = stream.read(n)
        if not chunk:
            return None
        chunks.append(chunk)
        n -= len(chunk)
    return b"".join(chunks)


def read_frame(stream):
    """One frame: (header dict, payload bytes), or None at end of input."""
    raw = read_exact(stream, 4)
    if raw is None:
        return None
    (length,) = struct.unpack("<I", raw)
    header = json.loads(read_exact(stream, length))
    size = header.get("payloadBytes", 0)
    payload = read_exact(stream, size) if size else b""
    return header, payload


def write_frame(stream, header, payload=b""):
    header = dict(header, payloadBytes=len(payload))
    encoded = json.dumps(header, separators=(",", ":")).encode()
    stream.write(struct.pack("<I", len(encoded)) + encoded + payload)
    stream.flush()


def fit(x, frames):
    """Trims or zero-pads the first axis to `frames` (resampling can be off by a sample)."""
    if x.shape[0] >= frames:
        return x[:frames]
    return np.pad(x, [(0, frames - x.shape[0])] + [(0, 0)] * (x.ndim - 1))


class Separator:
    def __init__(self):
        from demucs_mlx import Separator as Demucs

        self.model = Demucs(MODEL, shifts=0, overlap=0.25, progress=False)
        assert self.model.samplerate == MODEL_RATE, self.model.samplerate
        self.sources = list(self.model.model.sources)
        # The first call compiles the model for the window's shape (about 1 s); do it before reporting ready.
        self.model.separate_tensor(np.zeros((2, int(7.8 * MODEL_RATE)), dtype="<f4"))

    def separate(self, header, payload):
        """Separates one interleaved stereo float32 window at `rate`; returns the requested stems' slice,
        stem after stem, each interleaved stereo float32."""
        rate, frames = header["rate"], header["frames"]
        start, keep = header["keepStart"], header["keepFrames"]
        stems = header["stems"]
        unknown = [s for s in stems if s not in self.sources]
        if unknown:
            raise ValueError(f"unknown stems {unknown}; model has {self.sources}")
        if not 0 <= start <= start + keep <= frames:
            raise ValueError(f"slice {start}+{keep} outside window of {frames}")
        if len(payload) != frames * 2 * 4:
            raise ValueError(f"payload is {len(payload)} bytes, expected {frames * 8}")
        window = np.frombuffer(payload, dtype="<f4").reshape(frames, 2)
        at_model = window if rate == MODEL_RATE else soxr.resample(window, rate, MODEL_RATE, quality="HQ")
        _, separated = self.model.separate_tensor(np.ascontiguousarray(at_model.T))
        out = np.empty((len(stems), keep, 2), dtype="<f4")
        for i, name in enumerate(stems):
            stem = np.ascontiguousarray(separated[name].T)  # (samples, 2)
            if rate != MODEL_RATE:
                stem = soxr.resample(stem, MODEL_RATE, rate, quality="HQ")
            out[i] = fit(stem, frames)[start:start + keep]
        return out.tobytes()


def serve(inp, out):
    separator = Separator()
    write_frame(out, {"ready": True, "model": MODEL, "stems": separator.sources})
    while True:
        frame = read_frame(inp)
        if frame is None:
            return
        header, payload = frame
        began = time.perf_counter()
        try:
            stems = separator.separate(header, payload)
            write_frame(out, {"id": header["id"], "stems": header["stems"], "frames": header["keepFrames"],
                              "ms": round((time.perf_counter() - began) * 1000, 1)}, stems)
        except Exception as error:  # one bad request is reported, not fatal
            write_frame(out, {"id": header.get("id"), "error": f"{type(error).__name__}: {error}"})


def self_test():
    """Loads the model (downloading weights on first run) and times one 7.8 s window at 48 kHz."""
    rate, frames = 48000, int(7.8 * 48000)
    t = np.arange(frames) / rate
    window = np.stack([0.3 * np.sin(2 * np.pi * 110 * t), 0.3 * np.sin(2 * np.pi * 220 * t)], axis=1).astype("<f4")
    separator = Separator()
    header = {"id": 0, "rate": rate, "frames": frames, "keepStart": 0, "keepFrames": frames, "stems": separator.sources}
    separator.separate(header, window.tobytes())
    began = time.perf_counter()
    separator.separate(header, window.tobytes())
    print(f"separator ok: {MODEL} stems={separator.sources} window_ms={(time.perf_counter() - began) * 1000:.0f}")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        # The protocol owns stdout; anything a library prints goes to stderr instead.
        protocol_out = os.fdopen(os.dup(1), "wb")
        os.dup2(2, 1)
        serve(sys.stdin.buffer, protocol_out)
