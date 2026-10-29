#!/usr/bin/env python3
"""Makes the promo's real-component frames that depend on the film's stage, through a running
DEBUG Orbit (build-promo) and its `promo:` debug command:

    python3 tools/promo/prepare.py [snapshot|quickaccess|editor|toasts|overlay|...]

- the frozen screen (the stage at 2x) and the area capture cut from it
- QuickAccess's thumbnail card for that capture (its panel window)
- the editor opened on it: before, while dragging an arrow (one capture per frame), after
- the Copied toasts, each in one window over the stage where it shows (so its glass is right)
- the selection overlay, drawn offscreen by Orbit over the frozen screen, one JPEG per frame
The ring, notch, keycaps, symbols and menu bar glyphs come from capture.py (see its helpers).
"""
import json
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render as R  # noqa: E402
from capture import BUILD, REAL, promo, shoot  # noqa: E402

SNAPSHOT = os.path.join(BUILD, "snapshot.png")
CAPTURE = os.path.join(REAL, "capture.png")
POST = os.path.join(BUILD, "post")


def snapshot():
    R.stage_still().save(SNAPSHOT)
    a, b = R.SEL_A, R.SEL_B
    cut = R.stage_still().crop((a[0] * 2, a[1] * 2, b[0] * 2, b[1] * 2))
    cut.save(CAPTURE, dpi=(144, 144))  # 2x, so AppKit reads it at its size in points
    print("snapshot", cut.size)


def quickaccess():
    wid = promo({"kind": "quickaccess", "image": CAPTURE}, want_wid=True)
    shoot(wid, os.path.join(REAL, "quickaccess.png"), settle=0.9)
    promo({"kind": "quickaccess-close"})
    print("quickaccess", Image.open(os.path.join(REAL, "quickaccess.png")).size)


def _bbox(a, b):
    d = np.abs(np.asarray(a, dtype=int)[..., :3] - np.asarray(b, dtype=int)[..., :3]).sum(axis=2) > 40
    ys, xs = np.nonzero(d)
    return xs.min(), ys.min(), xs.max(), ys.max()


def editor():
    d = os.path.join(REAL, "editor")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        os.remove(os.path.join(d, f))
    promo({"kind": "editor-close"})
    time.sleep(0.4)
    subprocess.run([POST, "editor:" + CAPTURE], check=True)
    time.sleep(1.5)

    def state(kind, frm, to, tool=None, out=None, settle=0.25):
        spec = {"kind": kind, "to": list(to)}
        if frm is not None:
            spec["from"] = list(frm)
        if tool:
            spec["tool"] = tool
        wid = promo(spec, want_wid=True)
        if out:
            shoot(wid, out, settle=settle)
        return wid

    # Measure where the picture sits: two rectangles of known size, against the empty canvas.
    tmp = [os.path.join(BUILD, f"cal{i}.png") for i in range(3)]
    state("editor-drag", None, (0, 0), tool="rect", out=tmp[0], settle=0.6)
    state("editor-drag", (100, 100), (300, 250), out=tmp[1], settle=0.4)
    state("editor-drag", (50, 60), (500, 350), out=tmp[2], settle=0.4)
    state("editor-drag", None, (0, 0), tool="arrow")
    base = Image.open(tmp[0]).convert("RGB")
    b1, b2 = _bbox(Image.open(tmp[1]).convert("RGB"), base), _bbox(Image.open(tmp[2]).convert("RGB"), base)
    sx = ((b2[2] - b2[0]) - (b1[2] - b1[0])) / (450 - 200)
    sy = ((b2[3] - b2[1]) - (b1[3] - b1[1])) / (290 - 150)
    s = (sx + sy) / 2  # capture pixels per picture point
    ox = (b1[0] + b1[2]) / 2 - 200 * s
    oy = (b1[1] + b1[3]) / 2 - 175 * s
    print("canvas scale", sx, sy, "origin", ox, oy)

    arrow_from, arrow_to = (470, 300), (205, 128)  # tail in the open space, tip at the ring
    state("editor-drag", None, (0, 0), out=os.path.join(d, "base.png"), settle=0.4)
    n = int(round((R.ARROW_UP - R.ARROW_DOWN) * R.FPS)) + 1
    for i in range(n):
        x = R.ease_io(min(1, i / (n - 1)))
        p = (arrow_from[0] + (arrow_to[0] - arrow_from[0]) * x, arrow_from[1] + (arrow_to[1] - arrow_from[1]) * x)
        state("editor-drag", arrow_from, p, out=os.path.join(d, "drag_%02d.png" % i), settle=0.12)
    state("editor-end", arrow_from, arrow_to, out=os.path.join(d, "done.png"), settle=0.4)
    size = Image.open(os.path.join(d, "base.png")).size
    meta = {
        "size": list(size),
        "canvas": [s / 2, ox / 2, oy / 2],  # window points per picture point, picture origin in window points
        "canvas_rect": [ox / 2, oy / 2, (R.SEL_B[0] - R.SEL_A[0]) * s / 2, (R.SEL_B[1] - R.SEL_A[1]) * s / 2],
        "arrow_from": list(arrow_from), "arrow_to": list(arrow_to), "drag_frames": n,
        "copy": COPY_BUTTON,
    }
    with open(os.path.join(d, "meta.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
    promo({"kind": "editor-close"})
    print("editor", meta)


# The editor's Copy button, in window points from its top-left (read off base.png).
COPY_BUTTON = [818.5, 27.5]


def toasts():
    d = os.path.join(REAL, "toast")
    os.makedirs(d, exist_ok=True)
    x, y, w, h = R.TOAST_REGION
    bd = os.path.join(BUILD, "toast_backdrop.png")
    R.stage_still().crop((int(x * 2), int(y * 2), int((x + w) * 2), int((y + h) * 2))).save(bd)
    for name, spec in [("backdrop", {"message": ""}), ("editor", {"message": "Copied"}),
                       ("launcher", {"message": "Copied", "detail": "42.5"})]:
        wid = promo(dict({"kind": "toast", "backdrop": bd, "bottom": 64}, **spec), want_wid=True)
        shoot(wid, os.path.join(d, name + ".png"), settle=0.6)
    promo({"kind": "toast-close"})
    print("toasts", Image.open(os.path.join(d, "editor.png")).size)


def overlay():
    d = os.path.join(REAL, "overlay")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        os.remove(os.path.join(d, f))
    frames = R.overlay_specs()
    promo({"kind": "overlay", "shot": SNAPSHOT, "size": [R.SW, R.SH], "scale": 2, "out": d, "frames": frames})
    end = time.time() + 300
    while not os.path.exists(os.path.join(d, "done")) and time.time() < end:
        time.sleep(0.5)
    print("overlay", len(frames))


STEPS = {"snapshot": snapshot, "quickaccess": quickaccess, "editor": editor, "toasts": toasts, "overlay": overlay}

if __name__ == "__main__":
    for name in sys.argv[1:] or list(STEPS):
        STEPS[name]()
