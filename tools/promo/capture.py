"""Captures Orbit's real components for the promo, through a DEBUG build's `promo:` debug command.

Needs a DEBUG Orbit running (build-promo) in the film's language, and PROMO_LANG set to match:

    pkill -x Orbit; open build-promo/Build/Products/Debug/Orbit.app --args -AppleLanguages "(ko)"
    PROMO_LANG=ko python3 tools/promo/capture.py [shared|ring|keys|notch|screens|launcher ...]
    PROMO_LANG=ko python3 tools/promo/prepare.py

Everything with UI text goes to assets/<lang>/ (see render.LOCAL_REAL); glyphs and the cover art stay
in assets/real. Window kinds come back as a window number and are captured with
`screencapture -o -l <id>` (that window only); render kinds write PNGs themselves.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
LANG = os.environ.get("PROMO_LANG", "en")
SHARED = os.path.join(HERE, "assets", "real")
LOCAL = os.path.join(HERE, "assets", LANG)
REAL = os.path.join(LOCAL, "real")
POST = os.path.join(BUILD, "post")
_n = [0]


def promo(spec, want_wid=False, timeout=6.0):
    """Sends one spec; returns the window number for window kinds."""
    os.makedirs(BUILD, exist_ok=True)
    _n[0] += 1
    path = os.path.join(BUILD, f"spec_{_n[0]}.json")
    wid_path = path + ".wid"
    if want_wid:
        spec = dict(spec, wid=wid_path)
        if os.path.exists(wid_path):
            os.remove(wid_path)
    with open(path, "w") as f:
        json.dump(spec, f)
    subprocess.run([POST, "promo:" + path], check=True)
    if not want_wid:
        return None
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(wid_path):
            with open(wid_path) as f:
                s = f.read().strip()
            if s:
                return int(s)
        time.sleep(0.03)
    raise TimeoutError(spec["kind"])


def shoot(wid, out, settle=0.35):
    time.sleep(settle)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), out], check=True)


# Placeholder track and event only: the notch must never show the user's own music or calendar.
NOTCH_BASE = {"kind": "notch", "title": "Into Orbit", "artist": "Orbit", "duration": 214, "elapsed": 71,
              "artwork": os.path.join(SHARED, "cover.png"), "percent": 75,
              "events": [{"title": {"ko": "Orbit 1.0 출시"}.get(LANG, "Orbit 1.0 launch"),
                          "hour": 14, "minute": 0, "minutes": 60}]}


def notch_burst(name, start_state, end_state, speed=0.04, anim_len=0.75):
    """Captures one notch morph from `start_state` to `end_state`, slowed by `speed`, as a burst of
    window captures; writes <name>/<anim ms>.png. The morph's own spring plays out in slow motion."""
    d = os.path.join(REAL, "notch", name)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        os.remove(os.path.join(d, f))
    wid = promo(dict(NOTCH_BASE, state=start_state, speed=1), want_wid=True)
    time.sleep(1.2)
    t0 = time.time()
    wid = promo(dict(NOTCH_BASE, state=end_state, speed=speed), want_wid=True)
    end = t0 + anim_len / speed
    shots = []
    while time.time() < end:
        a = time.time()
        tmp = os.path.join(d, f"tmp_{len(shots)}.png")
        subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), tmp], check=True)
        b = time.time()
        shots.append((((a + b) / 2 - t0) * speed, tmp))
    for at, tmp in shots:
        os.rename(tmp, os.path.join(d, "%04d.png" % round(at * 1000)))
    promo(dict(NOTCH_BASE, state=end_state, speed=1))
    return len(shots)


def fresh(d):
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        os.remove(os.path.join(d, f))
    return d


def orbit_window(w, h, timeout=4.0):
    """The number of Orbit's on-screen window of w x h points (for windows the debug hook doesn't report)."""
    import Quartz
    end = time.time() + timeout
    while time.time() < end:
        for info in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
            b = info.get("kCGWindowBounds", {})
            if info.get("kCGWindowOwnerName") == "Orbit" and abs(b.get("Width", 0) - w) < 2 and abs(b.get("Height", 0) - h) < 2:
                return int(info["kCGWindowNumber"])
        time.sleep(0.1)
    raise TimeoutError(f"no {w}x{h} Orbit window")


def ring():
    """The ring opening (its own spring, sampled at 60 fps), with the top slot (Capture) hovered, closing."""
    d = fresh(os.path.join(REAL, "ring"))
    with open(os.path.join(HERE, "assets", "ring-appear.json")) as f:
        appear = json.load(f)
    for name, a in appear.items():
        wid = promo({"kind": "ring", "appear": a, **({"angle": 0} if name == "hover" else {})}, want_wid=True)
        shoot(wid, os.path.join(d, name + ".png"), settle=0.25)
    with open(os.path.join(d, "appear.json"), "w") as f:
        json.dump(appear, f, indent=1)
    promo({"kind": "ring-close"})


# The keystroke callouts, labelled the way Orbit's shortcut text names the keys in each language.
KEYS = {"cmd": "⌘", "return": "↩", "space": {"ko": "빈칸"}.get(LANG, "Space")}


def keys():
    d = os.path.join(REAL, "keys")
    os.makedirs(d, exist_ok=True)
    for name, label in KEYS.items():
        promo({"kind": "keycap", "label": label, "scale": 8, "out": os.path.join(d, name + ".png")})
    time.sleep(1)


def notch():
    """Stills of each state the film rests on, then the four morphs as slowed-down bursts."""
    d = os.path.join(REAL, "notch")
    os.makedirs(d, exist_ok=True)
    for state in ["closed", "ears-music", "expanded-home", "charging"]:
        wid = promo(dict(NOTCH_BASE, state=state, speed=1), want_wid=True)
        shoot(wid, os.path.join(d, f"still_{state}.png"), settle=1.5)
    for name, a, b in [("ears", "closed", "ears-music"), ("open", "ears-music", "expanded-home"),
                       ("close", "expanded-home", "ears-music"), ("charge", "ears-music", "charging")]:
        print(name, notch_burst(name, a, b), "frames")
    promo(dict(NOTCH_BASE, state="reset", speed=1))


# The main window's pages the film shows, captured at its default size (1084x949pt).
PAGES = {"home": "home", "ring": "ring", "capture": "capture", "windows": "windows", "translate": "translate",
         "menubar": "menubar", "awake": "awake", "sound": "sound", "system": "system", "displays": "displays",
         "battery": "battery", "notch": "notch", "spell": "spell", "corners": "corners"}


# ---------------------------------------------------------------- privacy

def frost(path, boxes, radius=16):
    """Frosted blur (gaussian sigma 18 at 2x, a little darker) over each (x0, y0, x1, y1) px box, in its
    own rounded shape: what a page shows of the user's own data never reaches the film."""
    from PIL import Image, ImageDraw, ImageFilter
    im = Image.open(path).convert("RGBA")
    for box in boxes:
        x0, y0, x1, y1 = [int(v) for v in box]
        m = 40
        crop = im.crop((x0 - m, y0 - m, x1 + m, y1 + m))
        blur = crop.filter(ImageFilter.GaussianBlur(18))
        blur = Image.blend(Image.new("RGBA", blur.size, (0, 0, 0, 255)), blur, 0.82)
        blur.putalpha(crop.getchannel("A"))
        mask = Image.new("L", crop.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([m, m, m + x1 - x0, m + y1 - y0], radius=radius, fill=255)
        im.paste(blur, (x0 - m, y0 - m), mask)
    im.save(path)


def thumbs(top, bottom):
    """The five recent-capture cards of a page row (px of the 2x capture; the last one runs off the edge)."""
    return [(553 + i * 324, top, min(2046, 553 + i * 324 + 300), bottom) for i in range(5)]


# What each capture shows of the user's own Mac, in px of its 2x capture: blurred right after the shot.
SENSITIVE = {
    "home": lambda p: thumbs(1603, 1805),      # recent captures (the user's screenshots)
    "capture": lambda p: thumbs(618, 819),     # recent captures
    "menubar": lambda p: [(592, 940, 2000, 1028), (592, 1097, 2000, 1184)],  # the user's menu bar icons
    "sound": lambda p: [(670, 335, 1060, 400), (595, 760, 1010, 1700)],      # output device name, the apps playing
}


def screens():
    d = os.path.join(LOCAL, "screens")
    os.makedirs(d, exist_ok=True)
    for out, page in PAGES.items():
        subprocess.run([POST, "page:" + page], check=True)
        path = os.path.join(d, out + ".png")
        shoot(orbit_window(1084, 949), path, settle=1.2)
        if out in SENSITIVE:
            boxes = SENSITIVE[out](path)
            frost(path, boxes, radius=44 if out == "menubar" else 16)
            print(out, "blurred", boxes)


# What the launcher shows as "2*21+0.5" is typed (the film keeps the empty state for "2": with one
# digit the launcher lists clipboard history, which is the user's own).
# launcher_empty's "Recent apps" row is blurred (see launcher()).
LAUNCHER = [("launcher_empty", "", 0.8), ("launcher_t2", "2*", 0.5), ("launcher_t3", "2*2", 0.5),
            ("launcher_t4", "2*21", 0.5), ("launcher_t6", "2*21+0.5", 0.04), ("launcher_math", "2*21+0.5", 0.8)]


def launcher():
    subprocess.run([POST, "launcher"], check=True)
    wid = orbit_window(680, 480)
    for out, text, settle in LAUNCHER:
        subprocess.run([POST, "type:" + text], check=True)
        shoot(wid, os.path.join(LOCAL, out + ".png"), settle=settle)
        if out == "launcher_empty":
            frost(os.path.join(LOCAL, out + ".png"), [(24, 792, 1336, 860)], radius=14)  # recent apps
    subprocess.run([POST, "close"], check=True)
    print("launcher: check that no frame lists clipboard history before using them")


def shared():
    """The language-neutral assets: Orbit's action glyphs, the menu bar's glyphs and Orbit mark, the app icon,
    a placeholder cover for the notch's track, macOS's cursors. Kept when they exist."""
    from PIL import Image, ImageDraw, ImageFilter
    assets = os.path.join(HERE, "assets")
    sym = os.path.join(SHARED, "symbols")
    if not os.path.isdir(sym):
        os.makedirs(sym)
        promo({"kind": "symbols", "out": sym})
    mb = os.path.join(SHARED, "menubar")
    os.makedirs(mb, exist_ok=True)
    for name in ["wifi", "battery.100percent", "switch.2", "magnifyingglass"]:
        if not os.path.exists(os.path.join(mb, name + ".png")):
            promo({"kind": "symbol", "name": name, "size": 15, "out": os.path.join(mb, name + ".png")})
    if not os.path.exists(os.path.join(SHARED, "menubar-icon.png")):
        promo({"kind": "menubar-icon", "scale": 4, "out": os.path.join(SHARED, "menubar-icon.png")})
    icon = os.path.join(assets, "icon.png")
    if not os.path.exists(icon):
        app = os.path.join(HERE, "..", "..", "build-promo", "Build", "Products", "Debug", "Orbit.app")
        subprocess.run(["sips", "-s", "format", "png", "-z", "512", "512",
                        os.path.join(app, "Contents", "Resources", "AppIcon.icns"), "--out", icon], check=True)
    cover = os.path.join(SHARED, "cover.png")
    if not os.path.exists(cover):  # an abstract orange/violet blur: no real album art
        im = Image.new("RGB", (600, 600), (40, 30, 90))
        d = ImageDraw.Draw(im)
        d.ellipse([-120, -140, 360, 330], fill=(232, 112, 64))
        d.ellipse([260, 250, 720, 720], fill=(84, 52, 190))
        im.filter(ImageFilter.GaussianBlur(70)).save(cover)
    cur = os.path.join(assets, "cursors")
    if not os.path.isdir(cur):
        os.makedirs(cur)
        tool = os.path.join(BUILD, "cursors")
        subprocess.run(["swiftc", "-O", os.path.join(HERE, "cursors.swift"), "-o", tool], check=True)
        subprocess.run([tool, cur], check=True)
    time.sleep(1)


STEPS = {"shared": shared, "ring": ring, "keys": keys, "notch": notch, "screens": screens, "launcher": launcher}

if __name__ == "__main__":
    for name in sys.argv[1:] or list(STEPS):
        STEPS[name]()
