#!/usr/bin/env python3
"""The promo's soundtrack: our own track (music/tracks.json) laid on the film, plus quiet UI sounds.

The track is placed on its own bar grid: each `edit` entry starts playing a track bar from a film bar,
with a 25ms crossfade that finishes just before the downbeat so the new bar's transient stays intact
(orbit-original-a is arranged on the film's grid already, so it is one segment from bar -2).
The film is time-scaled by bpm/120 (render.WARP), so the 120 BPM film grid becomes the track's grid.
The UI sounds (clicks, key ticks, whooshes, notch chimes in the track's key) sit about 20 dB under the
music. Mastered to -14 LUFS integrated with a 4x-oversampled true-peak limiter at -1 dBTP.

    python3 tools/promo/soundtrack.py orbit-original-a out.wav
"""
import json
import os
import re
import subprocess
import sys
import wave

import numpy as np
from scipy.ndimage import minimum_filter1d, uniform_filter1d
from scipy.signal import butter, lfilter, resample_poly, sosfilt, sosfilt_zi

HERE = os.path.dirname(os.path.abspath(__file__))
MUSIC = os.path.join(HERE, "music")
SR = 48000
RNG = np.random.default_rng(20261029)
XFADE = 0.025      # seconds, ending XF_LEAD before the downbeat
XF_LEAD = 0.004
UI_GAIN_DB = -6.0  # the UI bus against its old level; the music is far louder than the synth takes were


def tracks():
    d = json.load(open(os.path.join(MUSIC, "tracks.json")))
    return {k: v for k, v in d.items() if not k.startswith("_")}


def timing(slug):
    """Film-seconds per output second, and where the film should end (output seconds) for this track."""
    tr = tracks()[slug]
    _, end = edit(tr, decode(os.path.join(MUSIC, tr["file"])))
    return tr["bpm"] / 120.0, end


# ---------------------------------------------------------------- audio io

def decode(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, "<f4").reshape(-1, 2).astype(np.float64)


def write(path, x):
    x = np.clip(x, -1, 1)
    dither = (RNG.random(x.shape) - RNG.random(x.shape)) / 32768
    pcm = np.clip((x + dither) * 32767, -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def measure(path):
    """Integrated loudness (LUFS) and true peak (dBTP) by ffmpeg's EBU R128 scanner."""
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    txt = r.stderr[r.stderr.rfind("Summary:"):]
    lufs = float(re.search(r"I:\s+(-?[\d.]+) LUFS", txt).group(1))
    tp = float(re.search(r"Peak:\s+(-?[\d.]+) dBFS", txt).group(1))
    return lufs, tp


# ---------------------------------------------------------------- the edit

def edit(tr, x):
    """Returns the re-cut music (output timeline) and the output time where the film should end."""
    k = tr["bpm"] / 120.0
    bar = 4 * 60 / tr["bpm"]
    film_bar = lambda b: (4 + 2 * b) / k              # output seconds
    track_bar = lambda b: tr["downbeat"] + b * bar   # track seconds
    segs = [(film_bar(f), track_bar(t)) for f, t in tr["edit"]]
    assert segs[0][0] == 0 and segs[0][1] >= 0, "the first segment must start the film inside the track"
    last_u, last_s = segs[-1]
    n = int((last_u + len(x) / SR - last_s) * SR) + 1
    out = np.zeros((n, 2))
    xf, lead = int(XFADE * SR), int(XF_LEAD * SR)
    ramp = np.sin(np.linspace(0, np.pi / 2, xf)) ** 2   # with its mirror, an equal-power pair
    for i, (u, s) in enumerate(segs):
        last = i + 1 == len(segs)
        # each segment fades in over [cut - lead - xf, cut - lead]; the one before fades out there
        a = int(round(u * SR)) - (lead + xf if i else 0)
        b = n if last else int(round(segs[i + 1][0] * SR)) - lead
        src = int(round(s * SR)) - (int(round(u * SR)) - a)
        seg = x[src:src + (b - a)]
        assert last or len(seg) == b - a, "a segment runs past the end of the track"
        g = np.ones(len(seg))
        if i:
            g[:xf] = ramp
        if not last:
            g[-xf:] *= ramp[::-1]
        out[a:a + len(seg)] += seg * g[:, None]
    if tr.get("fade_in"):
        m = int(tr["fade_in"] * SR)
        out[:m] *= (np.linspace(0, 1, m) ** 2)[:, None]
    else:
        out[:96] *= np.linspace(0, 1, 96)[:, None]
    # the end: where the track's own ending has decayed to -50 dBFS (short-term), plus a breath
    win = int(0.05 * SR)
    rms = np.sqrt(uniform_filter1d((out ** 2).mean(axis=1), win))
    loud = np.nonzero(rms > 10 ** (-50 / 20))[0]
    stop = loud[-1] / SR if len(loud) else n / SR
    end = stop + 0.6
    out = out[: int(end * SR)]
    tail = int(0.3 * SR)
    out[-tail:] *= np.linspace(1, 0, tail)[:, None] ** 2
    return out, end


# ---------------------------------------------------------------- UI sounds

def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tt(n):
    return np.arange(n) / SR


def noise(n):
    return RNG.standard_normal(n)


def sos(kind, f, order=2):
    f = np.clip(np.atleast_1d(f), 20, SR / 2 * 0.95)
    return butter(order, f if len(f) > 1 else f[0], btype=kind, fs=SR, output="sos")


def filt(x, kind, f, order=2):
    return sosfilt(sos(kind, f, order), x, axis=0)


def sweep(x, kind, f0, f1, curve=2.0, block=256, order=2, q_band=None):
    """A filter whose cutoff glides from f0 to f1 (exponentially), processed in short blocks."""
    n = len(x)
    out = np.zeros_like(x)
    zi = None
    for b in range(0, n, block):
        p = (b / max(1, n - 1)) ** curve
        f = f0 * (f1 / f0) ** p
        s = sos(kind, [f / q_band, f * q_band] if q_band else f, order)
        if zi is None:
            zi = sosfilt_zi(s) * 0
        seg, zi = sosfilt(s, x[b:b + block], axis=0, zi=zi)
        out[b:b + block] = seg
    return out


def put(buf, sig, at, pan=0.0, gain=1.0):
    """Adds mono `sig` at `at` seconds, constant-power panned -1..1."""
    i = int(round(at * SR))
    if i >= len(buf) or len(sig) == 0:
        return
    j = min(len(buf), i + len(sig))
    s = sig[: j - i] * gain
    a = (pan + 1) * np.pi / 4
    buf[i:j, 0] += s * np.cos(a)
    buf[i:j, 1] += s * np.sin(a)


def ui_click(m):
    """A soft pitched tick."""
    n = int(0.06 * SR)
    t = tt(n)
    y = np.sin(2 * np.pi * midi(m) * t) * np.exp(-t * 90) + 0.3 * np.sin(2 * np.pi * midi(m + 12) * t) * np.exp(-t * 160)
    y += filt(noise(n), "highpass", 5000) * np.exp(-t * 700) * 0.2
    return y * np.minimum(1, t / 0.0008) * 0.22


def key_tick():
    n = int(0.03 * SR)
    t = tt(n)
    y = filt(noise(n), "bandpass", [2500, 7000]) * np.exp(-t * 500) * 0.35
    return y * 0.5


def whoosh(length=0.45):
    n = int(length * SR)
    t = tt(n)
    x = sweep(noise(n), "bandpass", 500, 3500, curve=1.0, q_band=1.5)
    return x * np.sin(np.pi * t / length) ** 2 * 0.25


def bell(m, length=1.0, vel=1.0):
    """A small FM bell."""
    n = int(length * SR)
    t = tt(n)
    f = midi(m)
    idx = 3.2 * np.exp(-t * 2.4)
    y = np.sin(2 * np.pi * f * t + idx * np.sin(2 * np.pi * f * 3.5 * t))
    return y * np.exp(-t * 2.0) * np.minimum(1, t / 0.002) * 0.16 * vel


def ui_bus(n, cues, k, root):
    """The film's cues (film seconds) at output time t / k. Pitched sounds sit on the track's key."""
    fx = np.zeros((n, 2))
    tonic = 84 + root if root < 6 else 72 + root      # an octave around C6
    fifth = tonic + 7
    for c in cues["clicks"]:
        put(fx, ui_click(tonic + 12), c / k, pan=0.1)
    for c in cues["keys"]:
        put(fx, key_tick(), c / k, pan=RNG.uniform(-0.25, 0.25), gain=0.7)
    for c in cues["whoosh"]:
        put(fx, whoosh(), c / k, pan=RNG.uniform(-0.3, 0.3), gain=0.3)
    notes = [(tonic, fifth), (fifth, tonic + 12), (fifth, tonic), (tonic + 4, fifth + 5)]  # ears, open, close, charge
    for c, (a, b) in zip(cues["notch"], notes):
        put(fx, bell(a, vel=0.35), c / k, pan=-0.15)
        put(fx, bell(b, vel=0.3), c / k + 0.07, pan=0.15)
    return fx


# ---------------------------------------------------------------- master

def true_peak_limit(x, ceiling_db=-1.0, lookahead=0.004, release=0.09):
    """Gain from the 4x-oversampled peak, held from `lookahead` before each peak, released smoothly."""
    c = 10 ** (ceiling_db / 20) * 0.985
    up = resample_poly(x, 4, 1, axis=0)
    peak = np.abs(up).max(axis=1)
    peak = peak[: len(peak) // 4 * 4].reshape(-1, 4).max(axis=1)
    peak = np.pad(peak, (0, len(x) - len(peak)), mode="edge")
    g = np.minimum(1, c / np.maximum(peak, 1e-9))
    L = max(1, int(lookahead * SR))
    g = minimum_filter1d(g, size=2 * L + 1)
    g = uniform_filter1d(g, size=L)
    a = np.exp(-1 / (release * SR))
    rel = lfilter([1 - a], [1, -a], g - 1) + 1
    g = np.minimum(g, rel)
    return x * g[:, None]


def render(slug, path, target=-14.0):
    import render as film
    tr = tracks()[slug]
    k = tr["bpm"] / 120.0
    music, end = edit(tr, decode(os.path.join(MUSIC, tr["file"])))
    mix = music + ui_bus(len(music), film.CUES, k, tr.get("key_root", 0)) * 10 ** (UI_GAIN_DB / 20)
    gain_db = 0.0
    tmp = path + ".tmp.wav"
    for _ in range(5):
        y = true_peak_limit(mix * 10 ** (gain_db / 20), -1.0)
        write(tmp, y)
        lufs, tp = measure(tmp)
        if abs(lufs - target) < 0.15:
            break
        gain_db += target - lufs
    os.replace(tmp, path)
    print(f"soundtrack {slug}: {len(y) / SR:.2f}s, {lufs:.1f} LUFS, {tp:.1f} dBTP -> {path}", flush=True)
    return end


if __name__ == "__main__":
    render(sys.argv[1], sys.argv[2])
