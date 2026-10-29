"""Beat grid, energy curve and brightness of candidate tracks (librosa).

    venv/bin/python analyze.py track.mp3 [...]  -> prints a summary, writes <track>.json and <track>.png

The JSON holds what render.py needs to re-time the edit: beat times, the bar phase,
per-beat loudness and "entries" (beats where the next bar is much louder than the last).
"""
import json, sys
import numpy as np
import librosa

SR = 22050


def db(x):
    return 20 * np.log10(np.maximum(x, 1e-6))


def analyse(path):
    y, sr = librosa.load(path, sr=SR, mono=True)
    dur = len(y) / sr
    hop = 512
    onset = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
    tempo, beats = librosa.beat.beat_track(onset_envelope=onset, sr=sr, hop_length=hop, tightness=400)
    bt = librosa.frames_to_time(beats, sr=sr, hop_length=hop)
    # library tracks are click-locked: fit one straight grid through the tracked beats
    # (the tracker's own times are quantised to the 23ms hop)
    per, off = float(np.median(np.diff(bt))), float(bt[0])
    for n in (16, 32, 64, 128, 256, 100000):   # widen the fit as the period sharpens
        sub = bt[:n]
        idx = np.round((sub - off) / per)
        keep = np.abs(sub - (off + per * idx)) < per * 0.25
        per, off = np.polyfit(idx[keep], sub[keep], 1)
    idx = np.round((bt - off) / per)
    resid = float(np.abs(bt - (off + per * idx)).mean())
    bt = off + per * np.arange(int(np.floor((dur - off) / per)) + 1)
    bpm = 60 / per

    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=hop))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    rms = librosa.feature.rms(S=S)[0]
    low = np.sqrt((S[freqs < 150] ** 2).mean(0))
    hi = np.sqrt((S[(freqs > 2000) & (freqs < 8000)] ** 2).mean(0))
    cent = librosa.feature.spectral_centroid(S=S, sr=sr)[0]
    t = librosa.frames_to_time(np.arange(len(rms)), sr=sr, hop_length=hop)

    def per_beat(v):
        out = []
        for a, b in zip(bt, list(bt[1:]) + [dur]):
            m = (t >= a) & (t < b)
            out.append(float(np.sqrt((v[m] ** 2).mean())) if m.any() else 0.0)
        return np.array(out)

    rb, lb = db(per_beat(rms)), db(per_beat(low))
    # bar phase: which beat (mod 4) carries the most low end + onset -> downbeat
    ob = np.array([onset[(t >= a) & (t < a + 0.08)].max(initial=0) for a in bt])
    score = [ob[p::4].mean() + 0.02 * lb[p::4].mean() for p in range(4)]
    phase = int(np.argmax(score))
    # entries: loudness of the next bar vs the previous bar, in dB (full band and low band)
    ent = []
    for i in range(4, len(bt) - 4):
        dfull = rb[i:i + 4].mean() - rb[i - 4:i].mean()
        dlow = lb[i:i + 4].mean() - lb[i - 4:i].mean()
        if dfull > 3 or dlow > 5:
            ent.append(dict(beat=i, t=round(float(bt[i]), 3), down=(i - phase) % 4 == 0,
                            dfull=round(float(dfull), 1), dlow=round(float(dlow), 1)))
    # keep the strongest per 2-bar window
    ent.sort(key=lambda e: -(e['dfull'] + 0.5 * e['dlow']))
    keep = []
    for e in ent:
        if all(abs(e['beat'] - k['beat']) >= 8 for k in keep): keep.append(e)
    keep.sort(key=lambda e: e['t'])
    # how the track ends: last beat above -30 dB relative to its loudest bar
    loud = rb.max()
    tail = [i for i in range(len(rb)) if rb[i] > loud - 30]
    return dict(path=path, dur=round(dur, 2), bpm=round(bpm, 2), grid_resid=round(resid, 4), beats=[round(float(x), 4) for x in bt],
                phase=phase, beat_db=[round(float(x), 1) for x in rb], beat_low_db=[round(float(x), 1) for x in lb],
                entries=keep, centroid=round(float(np.median(cent[rms > rms.max() * 0.1])), 0),
                hi_ratio=round(float(db(hi.mean()) - db(rms.mean())), 1),
                last_loud=round(float(bt[tail[-1]]), 2) if tail else dur,
                curve=[round(float(x), 1) for x in db(np.array([rms[(t >= s) & (t < s + 0.5)].mean() for s in np.arange(0, dur, 0.5)]))])


def plot(a, out):
    from PIL import Image, ImageDraw
    W, H = 1400, 260
    im = Image.new('RGB', (W, H), 'white'); d = ImageDraw.Draw(im)
    c = np.array(a['curve']); xs = np.arange(len(c)) * 0.5
    sx = W / max(a['dur'], 1)
    def y(v): return H - 20 - (np.clip(v, -50, 0) + 50) / 50 * (H - 40)
    for s in range(0, int(a['dur']), 4):
        d.line([(s * sx, 0), (s * sx, H)], fill=(235, 235, 235))
        if s % 8 == 0: d.text((s * sx + 2, H - 14), str(s), fill=(120, 120, 120))
    d.line([(x * sx, y(v)) for x, v in zip(xs, c)], fill=(30, 30, 30), width=2)
    for e in a['entries']:
        d.line([(e['t'] * sx, 0), (e['t'] * sx, H)], fill=(230, 80, 40) if e['down'] else (240, 180, 150), width=2)
        d.text((e['t'] * sx + 3, 4), f"{e['dfull']:+.0f}", fill=(200, 60, 30))
    d.text((W - 300, 4), f"{a['bpm']} bpm  centroid {a['centroid']:.0f}Hz", fill=(0, 0, 0))
    im.save(out)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        a = analyse(p)
        json.dump(a, open(p.rsplit('.', 1)[0] + '.json', 'w'))
        plot(a, p.rsplit('.', 1)[0] + '.png')
        print(f"{p.split('/')[-1][:58]:58s} {a['dur']:6.1f}s {a['bpm']:6.1f}bpm ±{a['grid_resid']*1000:.0f}ms cent {a['centroid']:5.0f} hi {a['hi_ratio']:5.1f} "
              f"entries " + ' '.join(f"{e['t']:.1f}{'*' if e['down'] else ''}({e['dfull']:+.0f}/{e['dlow']:+.0f})" for e in a['entries'][:8]))
