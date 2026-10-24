import io
import json
from pathlib import Path

import numpy as np

import stemmix_separator as sep

CONTRACT = Path(__file__).resolve().parent.parent / "contract"


def fixture(name):
    return json.loads((CONTRACT / name).read_text())


def frames_of(stream):
    stream.seek(0)
    found = []
    while (frame := sep.read_frame(stream)) is not None:
        found.append(frame)
    return found


def test_protocol_frames_match_the_contract():
    request = fixture("separator-request.json")
    rng = np.random.default_rng(0)
    window = (0.1 * rng.standard_normal((request["frames"], 2))).astype("<f4")
    bad = dict(request, id=8, keepStart=request["frames"])
    inp = io.BytesIO()
    sep.write_frame(inp, request, window.tobytes())
    sep.write_frame(inp, bad, window.tobytes())
    inp.seek(0)
    out = io.BytesIO()

    sep.serve(inp, out)

    (ready, _), (response, payload), (error, _) = frames_of(out)
    assert ready.keys() == fixture("separator-ready.json").keys()
    assert ready["stems"] == fixture("separator-ready.json")["stems"]
    assert response.keys() == fixture("separator-response.json").keys()
    assert (response["id"], response["stems"], response["frames"]) == (7, request["stems"], request["keepFrames"])
    assert len(payload) == response["payloadBytes"] == fixture("separator-response.json")["payloadBytes"]
    assert error.keys() == fixture("separator-error.json").keys()
    assert error["id"] == 8 and "outside window" in error["error"]


def test_all_four_stems_add_back_up_to_the_window():
    rate, frames = 48000, int(7.8 * 48000)
    t = np.arange(frames) / rate
    kick = np.sin(2 * np.pi * 60 * t) * np.exp(-30 * (t % 0.5))
    tone = 0.2 * np.sin(2 * np.pi * 440 * t) * (1 + np.sin(2 * np.pi * 3 * t)) / 2
    window = np.stack([kick + tone, kick + 0.8 * tone], axis=1).astype("<f4") * 0.5
    separator = sep.Separator()
    header = {"rate": rate, "frames": frames, "keepStart": 0, "keepFrames": frames, "stems": separator.sources}

    stems = np.frombuffer(separator.separate(header, window.tobytes()), dtype="<f4").reshape(4, frames, 2)

    middle = slice(rate, frames - rate)
    residual = window[middle] - stems.sum(axis=0)[middle]
    snr = 10 * np.log10(np.sum(window[middle] ** 2) / np.sum(residual ** 2))
    assert snr > 20, snr
