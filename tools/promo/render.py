#!/usr/bin/env python3
"""Orbit 1.0 launch promo.

Renders a ~32s 60fps film where every piece of UI is Orbit's own: window captures and offscreen
renders made by a DEBUG build through its `promo:` debug command (see capture.py / prepare.py), and
the real macOS cursors. On top: a virtual camera that follows the pointer (Screen Studio style),
click ripples, kinetic type cards. The film is laid out on a 120 BPM grid (a bar is 2s, the reveal at
4.0s, the logo hit at 28.0s), and so is its soundtrack (music/tracks.json, soundtrack.py), which is
held until its own ending.

    python3 tools/promo/render.py              # docs/promo/orbit-promo-16x9-{en,ko}.mp4 (--vertical adds a 9:16)
    python3 tools/promo/render.py --lang en    # one language
    python3 tools/promo/render.py --preview    # 640x360 30fps sync check -> tools/promo/build/preview-<lang>.mp4
    python3 tools/promo/render.py --still 5.4 out.png
"""
import math
import os
import subprocess
import sys
from functools import lru_cache
from multiprocessing import Pool

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ASSETS = os.path.join(HERE, "assets")
OUT_DIR = os.path.join(ROOT, "docs", "promo")

W, H = 1920, 1080
FPS = 60
BPM = 120
BEAT = 60 / BPM
DURATION = 32.0
# Per-track cut (set by main() through the environment, so the worker processes see it too):
# film seconds per output second, and the film time where the picture has faded to black.
WARP = float(os.environ.get("PROMO_WARP", 1.0))
END = float(os.environ.get("PROMO_END", DURATION))
LANG = os.environ.get("PROMO_LANG", "en")
PREVIEW = os.environ.get("PROMO_PREVIEW") == "1"  # a small, fast render for checking sync  # the film's language: its copy and the Orbit UI it shows

ORANGE = (255, 107, 53)
WHITE = (255, 255, 255)

SF = "/System/Library/Fonts/SFNS.ttf"
SF_MONO = "/System/Library/Fonts/SFNSMono.ttf"
KO = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
PRETENDARD = os.path.expanduser("~/Library/Fonts/PretendardVariable.ttf")  # the Korean cards (falls back to SD Gothic Neo)

# Everything the film says, per language. The Korean follows the app's own wording (tools/i18n/ko*.json).
COPY = {
    "en": {
        "intro": "Twenty menu bar apps.",
        "one": ("One", "orbit."),
        "verbs": ["Snap windows.", "Translate anything.", "Hide the clutter.", "Keep it awake."],
        "wall": ("Every Mac utility.", "One app."),
        "free": "Free and open source.",
        "tagline": "Every Mac utility, all in one",
        "menus": ["Finder", "File", "Edit", "View", "Go", "Window", "Help"],
        "clock": "Thu Oct 29  10:41 AM",
    },
    "ko": {
        "intro": "메뉴 막대에 앱만 스무 개.",
        "one": ("이제", "Orbit 하나로."),
        "verbs": ["창은 딱 맞게.", "무엇이든 번역.", "메뉴 막대는 깔끔하게.", "Mac은 깨어 있게."],
        "wall": ("모든 유틸리티를", "앱 하나에."),
        "free": "무료 오픈 소스.",
        "tagline": "맥의 모든 유틸리티 앱을 한 번에",
        "menus": ["Finder", "파일", "편집", "보기", "이동", "윈도우", "도움말"],
        "clock": "10월 29일 (목) 오전 10:41",
    },
}[LANG]
CARD = "kr" if LANG == "ko" else "sf"   # the font kind of the title cards
TRACK_K = -0.035 if LANG == "ko" else 0  # Hangul sets tighter than SF at display sizes


# ---------------------------------------------------------------- easing

def clamp(x, a=0.0, b=1.0):
    return max(a, min(b, x))


def prog(t, a, b):
    return clamp((t - a) / (b - a)) if b > a else float(t >= a)


def ease_io(x):
    x = clamp(x)
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def ease_out(x):
    x = clamp(x)
    return 1 - (1 - x) ** 3


def ease_in(x):
    x = clamp(x)
    return x ** 3


def spring(x, overshoot=1.70158):
    """Ease-out-back: a quick spring that settles with one soft overshoot."""
    x = clamp(x)
    c3 = overshoot + 1
    return 1 + c3 * (x - 1) ** 3 + overshoot * (x - 1) ** 2


def lerp(a, b, x):
    return a + (b - a) * x


def lerp2(p, q, x):
    return (lerp(p[0], q[0], x), lerp(p[1], q[1], x))


def keyframes(t, keys, ease=ease_io):
    """keys: [(time, value_tuple)], eased between neighbours, held outside."""
    if t <= keys[0][0]:
        return keys[0][1]
    for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
        if t <= t1:
            x = ease((t - t0) / (t1 - t0)) if t1 > t0 else 1
            return tuple(lerp(a, b, x) for a, b in zip(v0, v1))
    return keys[-1][1]


def bezier(p0, p1, p2, x):
    return ((1 - x) ** 2 * p0[0] + 2 * (1 - x) * x * p1[0] + x * x * p2[0],
            (1 - x) ** 2 * p0[1] + 2 * (1 - x) * x * p1[1] + x * x * p2[1])


# ---------------------------------------------------------------- assets

@lru_cache(None)
def asset(name):
    return Image.open(os.path.join(ASSETS, local(name))).convert("RGBA")


@lru_cache(None)
def font(kind, size, weight=700):
    if kind == "mono":
        f = ImageFont.truetype(SF_MONO, size)
        try:
            f.set_variation_by_axes([weight])
        except Exception:
            pass
        return f
    if kind == "sym":
        return ImageFont.truetype("/System/Library/Fonts/Apple Symbols.ttf", size)
    if kind == "kr" and os.path.exists(PRETENDARD):
        f = ImageFont.truetype(PRETENDARD, size)
        f.set_variation_by_axes([weight])
        return f
    if kind in ("ko", "kr"):
        index = {400: 0, 500: 2, 600: 4, 700: 6}.get(min(700, round(weight / 100) * 100), 6)
        return ImageFont.truetype(KO, size, index=index)
    f = ImageFont.truetype(SF, size)
    # axes: width, optical size, grade, weight
    f.set_variation_by_axes([100, 96 if size > 40 else 28, 400, weight])
    return f


@lru_cache(None)
def text_image(text, size, weight=700, color=WHITE, tracking=0.0, kind="sf", alpha=255):
    f = font(kind, size, weight)
    ascent, descent = f.getmetrics()
    width = 0
    advances = []
    for ch in text:
        a = f.getlength(ch)
        advances.append(a)
        width += a + tracking * size
    width -= tracking * size
    pad = int(size * 0.3)
    im = Image.new("RGBA", (int(width) + pad * 2, ascent + descent + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if tracking == 0:
        d.text((pad, pad), text, font=f, fill=color + (alpha,))
    else:
        x = pad
        for ch, a in zip(text, advances):
            d.text((x, pad), ch, font=f, fill=color + (alpha,))
            x += a + tracking * size
    return im


def card_text(text, size, weight=700, color=WHITE, tracking=0.0, max_w=None):
    """A title-card line in the film's language, shrunk until it fits `max_w` (stage px, ink width)."""
    while True:
        im = text_image(text, size, weight, color=color, tracking=tracking + TRACK_K, kind=CARD)
        if max_w is None or im.size[0] - 0.6 * size <= max_w or size <= 12:
            return im
        size -= 2


def with_alpha(im, a):
    if a >= 0.999:
        return im
    if a <= 0.001:
        return None
    out = im.copy()
    out.putalpha(out.getchannel("A").point([int(i * a) for i in range(256)]))
    return out


@lru_cache(None)
def shadowed(name, blur=40, alpha=150, dy=18, scale=0.25):
    """The capture with a soft drop shadow baked in (built at a quarter size, then scaled up)."""
    im = asset(name)
    pad = int(blur * 2 / scale)
    w, h = im.size
    small = Image.new("L", (int((w + pad * 2) * scale), int((h + pad * 2) * scale)), 0)
    mask = im.getchannel("A").resize((int(w * scale), int(h * scale)))
    small.paste(mask.point(lambda v: alpha if v > 8 else 0), (int(pad * scale), int((pad + dy / scale) * scale)))
    small = small.filter(ImageFilter.GaussianBlur(blur))
    shadow = small.resize((w + pad * 2, h + pad * 2), Image.BILINEAR)
    out = Image.new("RGBA", shadow.size, (0, 0, 0, 0))
    out.putalpha(shadow)
    out.alpha_composite(im, (pad, pad))
    return out, pad


# ---------------------------------------------------------------- stage

SW, SH = 1920, 1080  # stage points: a 1920x1080 display with a notch
MENU_H = 33
REAL = os.path.join(ASSETS, "real")

# Where things sit on the stage, in points, top-left origin.
HOME = (96, 72)              # the Orbit window (its page capture is 1084x949pt)
RING_AT = (1500, 540)        # the ring opens around the pointer here
SEL_A, SEL_B = (350, 300), (1130, 700)  # area capture drag
VISIBLE_H = SH - MENU_H      # NSScreen.visibleFrame height (no Dock on this display)


# Captures that show Orbit's UI text live per language (assets/<lang>/...): the page captures, the
# launcher, and these folders of assets/real. Glyphs, menu bar icons and the cover art are shared.
LOCAL_REAL = ("capture.png", "quickaccess.png", "editor", "toast", "overlay", "ring", "notch", "keys")


def local(name):
    """assets/<lang>/name for language-dependent files; never falls back to the other language."""
    head = name.split("/")[0]
    if head == "screens" or head.startswith("launcher_"):
        return os.path.join(LANG, name)
    if head == "real" and name.split("/")[1] in LOCAL_REAL:
        return os.path.join(LANG, name)
    return name


def real(name):
    return asset(os.path.join("real", name))


def real_path(name):
    return os.path.join(ASSETS, local(os.path.join("real", name)))


@lru_cache(None)
def wallpaper():
    """A deep, soft wallpaper at 2x: black-blue with an orange and a blue glow."""
    w, h = SW * 2, SH * 2
    small = Image.new("RGB", (w // 8, h // 8), (8, 9, 14))
    d = ImageDraw.Draw(small)
    sw, sh = small.size
    for (cx, cy, r, col) in [(0.82, 0.28, 0.55, (255, 107, 53)), (0.12, 0.92, 0.60, (40, 70, 160)),
                             (0.45, 0.55, 0.35, (90, 40, 120))]:
        for i in range(30, 0, -1):
            rr = r * sw * i / 30
            a = (1 - i / 30) ** 2
            c = tuple(int(8 + (v - 8) * a * 0.55) for v in col)
            d.ellipse([cx * sw - rr, cy * sh - rr * 0.8, cx * sw + rr, cy * sh + rr * 0.8], fill=c)
    small = small.filter(ImageFilter.GaussianBlur(18))
    im = small.resize((w, h), Image.BICUBIC)
    d = ImageDraw.Draw(im, "RGBA")
    for i, rad in enumerate([900, 1400, 1950]):
        box = [w * 0.62 - rad, h * 0.42 - rad * 0.36, w * 0.62 + rad, h * 0.42 + rad * 0.36]
        d.ellipse(box, outline=(255, 255, 255, 14 - i * 3), width=4)
    return im


def _is_hangul(ch):
    return "가" <= ch <= "힣" or "㄰" <= ch <= "㆏"


def draw_mixed(d, xy, text, size, weight, fill):
    """System text the way macOS sets it: SF for Latin and digits, Apple SD Gothic Neo for Hangul."""
    x, y = xy
    for ch in text:
        f = font("ko", size, 600 if weight >= 600 else 500) if _is_hangul(ch) else font("sf", size, weight)
        dy = 1 if _is_hangul(ch) else 0
        d.text((x, y + dy), ch, font=f, fill=fill)
        x += f.getlength(ch)
    return x


def mixed_width(text, size, weight):
    return sum((font("ko", size, 600 if weight >= 600 else 500) if _is_hangul(c) else font("sf", size, weight)).getlength(c)
               for c in text)


@lru_cache(None)
def menubar():
    """The macOS 26+ menu bar at 2x: transparent, Finder's menus, Orbit's own status item (its real
    OrbitMark render), then the system's Wi-Fi, battery, Control Center (SF Symbols) and the clock."""
    w, h = SW * 2, MENU_H * 2
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    ink = (255, 255, 255, 240)
    y = 19
    d.text((40, 13), "", font=font("sf", 32, 500), fill=ink)
    x = 100
    for i, word in enumerate(COPY["menus"]):
        x = draw_mixed(d, (x, y), word, 26, 700 if i == 0 else 500, ink) + 40
    clock = COPY["clock"]
    cx = w - 40 - mixed_width(clock, 26, 500)
    draw_mixed(d, (cx, y), clock, 26, 500, ink)
    x = cx - 34
    for name in ["switch.2", "battery.100percent", "wifi"]:
        g = real("menubar/" + name + ".png")
        g = g.resize((g.size[0] // 2, g.size[1] // 2), Image.LANCZOS)  # rendered at 4x
        x -= g.size[0]
        im.alpha_composite(g, (int(x), (h - g.size[1]) // 2))
        x -= 34
    mark = real("menubar-icon.png")  # 20pt at 4x
    mark = mark.resize((40, 40), Image.LANCZOS)
    x -= 40
    im.alpha_composite(mark, (int(x), (h - 40) // 2))
    return im


@lru_cache(None)
def notch_rest():
    """Orbit's notch at rest: its real window capture (closed, nothing beside it)."""
    return real("notch/still_closed.png")


def paste_notch(base2x, im):
    """A notch window capture flush with the top, centred."""
    base2x.alpha_composite(im, (SW - im.size[0] // 2, 0))


@lru_cache(None)
def desktop_base():
    im = wallpaper().copy().convert("RGBA")
    im.alpha_composite(menubar())
    paste_notch(im, notch_rest())
    return im.convert("RGB")


@lru_cache(None)
def home_window():
    return shadowed("screens/home.png", blur=46, alpha=165, dy=22)


@lru_cache(None)
def stage_still():
    """The desktop with the Orbit window, at 2x: what a capture freezes."""
    im = desktop_base().convert("RGBA")
    win, pad = home_window()
    im.alpha_composite(win, (HOME[0] * 2 - pad, HOME[1] * 2 - pad))
    return im.convert("RGB")


class Camera:
    def __init__(self, cx=SW / 2, cy=SH / 2, z=1.0):
        self.z = max(1.0, z)
        vw, vh = W / (self.z * scale_out()), H / (self.z * scale_out())
        # never look past the edge of the desktop
        self.cx = clamp(cx, min(vw / 2, SW / 2), max(SW - vw / 2, SW / 2))
        self.cy = clamp(cy, min(vh / 2, SH / 2), max(SH - vh / 2, SH / 2))

    def to_screen(self, x, y):
        return ((x - self.cx) * self.z * scale_out() + W / 2, (y - self.cy) * self.z * scale_out() + H / 2)


def scale_out():
    return H / SH


def render_base(cam, base):
    k = cam.z * scale_out()
    vw, vh = W / k, H / k
    x0 = clamp(cam.cx - vw / 2, 0, max(0, SW - vw))
    y0 = clamp(cam.cy - vh / 2, 0, max(0, SH - vh))
    sx = base.size[0] / SW
    box = (x0 * sx, y0 * sx, min(SW, x0 + vw) * sx, min(SH, y0 + vh) * sx)
    return base.resize((W, H), Image.BILINEAR, box=box)


def place(frame, im, cam, x, y, w, alpha=1.0, scale=1.0, anchor=(0.5, 0.5), shadow_pad=0, src_w=None):
    """Draws `im` with its content (excluding shadow padding) `w` stage points wide, its anchor at
    stage (x, y), through the camera."""
    if im is None or alpha <= 0.001:
        return
    src_w = src_w or (im.size[0] - shadow_pad * 2)
    k = cam.z * scale_out() * w / src_w * scale
    tw, th = max(1, int(im.size[0] * k)), max(1, int(im.size[1] * k))
    if tw < 2 or th < 2:
        return
    sx, sy = cam.to_screen(x, y)
    cw = (im.size[0] - shadow_pad * 2) * k
    ch = (im.size[1] - shadow_pad * 2) * k
    left = sx - anchor[0] * cw - shadow_pad * k
    top = sy - anchor[1] * ch - shadow_pad * k
    if left > W or top > H or left + tw < 0 or top + th < 0:
        return
    vis_l, vis_t = max(0, -left), max(0, -top)
    vis_r, vis_b = min(tw, W - left), min(th, H - top)
    box = (vis_l / k, vis_t / k, vis_r / k, vis_b / k)
    piece = im.resize((int(vis_r - vis_l) + 1, int(vis_b - vis_t) + 1), Image.BILINEAR, box=box)
    piece = with_alpha(piece, alpha)
    if piece is not None:
        frame.paste(piece, (int(left + vis_l), int(top + vis_t)), piece)


def place2x(frame, im, cam, x, y, alpha=1.0, anchor=(0, 0)):
    """A 2x window capture at its real size, top-left (or `anchor`) at stage (x, y)."""
    place(frame, im, cam, x, y, im.size[0] / 2, alpha=alpha, anchor=anchor, src_w=im.size[0])


def paste_screen(frame, im, x, y, anchor=(0.5, 0.5), alpha=1.0):
    """Screen-space paste (type, overlays)."""
    im = with_alpha(im, alpha)
    if im is None:
        return
    frame.paste(im, (int(x - anchor[0] * im.size[0]), int(y - anchor[1] * im.size[1])), im)


# ---------------------------------------------------------------- Orbit's own motion

def swiftui_spring(t, duration, bounce=0.0):
    """SwiftUI's .spring(duration:bounce:) from 0 to 1."""
    if t <= 0:
        return 0.0
    w0 = 2 * math.pi / duration
    if bounce <= 0:
        return 1 - math.exp(-w0 * t) * (1 + w0 * t)
    z = 1 - bounce
    wd = w0 * math.sqrt(1 - z * z)
    return 1 - math.exp(-z * w0 * t) * (math.cos(wd * t) + z * w0 / wd * math.sin(wd * t))


def cubic_bezier(x1, y1, x2, y2, x):
    """CAMediaTimingFunction(controlPoints:)."""
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    lo, hi = 0.0, 1.0
    for _ in range(40):
        m = (lo + hi) / 2
        bx = 3 * (1 - m) ** 2 * m * x1 + 3 * (1 - m) * m * m * x2 + m ** 3
        lo, hi = (m, hi) if bx < x else (lo, m)
    m = (lo + hi) / 2
    return 3 * (1 - m) ** 2 * m * y1 + 3 * (1 - m) * m * m * y2 + m ** 3


def panel_present(t, t0):
    """FloatingPanel.present: 0.2s fade with a 6pt rise, controlPoints(0.2, 0.8, 0.2, 1).
    Returns (alpha, dy in points)."""
    p = cubic_bezier(0.2, 0.8, 0.2, 1, (t - t0) / 0.2)
    return p, 6 * (1 - p)


def panel_dismiss(t, t0):
    """FloatingPanel.dismiss: 0.12s fade, controlPoints(0.4, 0, 1, 1)."""
    return 1 - cubic_bezier(0.4, 0, 1, 1, (t - t0) / 0.12)


def window_open(t, t0):
    """A titled window ordering front (the editor): AppKit's quick document-window zoom."""
    p = cubic_bezier(0.25, 0.1, 0.25, 1, (t - t0) / 0.18)
    return p, lerp(0.94, 1.0, p)


# ---------------------------------------------------------------- cursor & effects

# The real macOS cursors (NSCursor's largest representation, or the system's vector cursor with
# its info.plist shadow): file, size in points, hot spot in points.
CURSORS = {
    "arrow": ("arrow.png", 28, 40, 5, 5),
    "cross": ("crosshair.png", 32, 32, 15, 15),
    "ibeam": ("ibeam.png", 23, 22, 12, 11),
    "hand": ("pointinghand.png", 40, 40, 16, 12),
}
CURSOR_SCALE = 1.45  # Screen Studio's enlarged pointer


@lru_cache(None)
def cursor_image(kind):
    return asset("cursors/" + CURSORS[kind][0])


def draw_cursor(frame, cam, path_fn, t, kind="arrow", press=0.0):
    """path_fn(t) -> (x, y) stage. Motion blur from a few trailing samples when it moves fast."""
    im = cursor_image(kind)
    _, pw, ph, hx, hy = CURSORS[kind]
    anchor = (hx / pw, hy / ph)
    x, y = path_fn(t)
    px, py = path_fn(t - 1 / FPS)
    speed = math.hypot(x - px, y - py) * FPS  # points per second
    scale = 1 - 0.1 * press
    w = pw * CURSOR_SCALE
    if speed > 700:  # a short smear along the path, like Screen Studio's motion blur
        for i in range(6, 0, -1):
            tx, ty = path_fn(t - i * 0.0025)
            place(frame, im, cam, tx, ty, w, alpha=0.1, scale=scale, anchor=anchor)
    place(frame, im, cam, x, y, w, scale=scale, anchor=anchor)


def ripple(frame, cam, x, y, t, t0, color=WHITE, max_r=40, dur=0.45):
    p = (t - t0) / dur
    if p < 0 or p > 1:
        return
    sx, sy = cam.to_screen(x, y)
    r = (8 + max_r * ease_out(p)) * cam.z * scale_out()
    a = int(150 * (1 - p) ** 1.5)
    ov = Image.new("RGBA", (int(r * 2 + 12), int(r * 2 + 12)), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    c = r + 6
    d.ellipse([c - r, c - r, c + r, c + r], outline=color + (a,), width=max(2, int(3 * cam.z)))
    frame.paste(ov, (int(sx - c), int(sy - c)), ov)


def press_amount(t, clicks):
    v = 0.0
    for c in clicks:
        if c - 0.06 <= t <= c + 0.16:
            v = max(v, 1 - abs(t - (c + 0.02)) / 0.14)
    return clamp(v)


def blur_in(im, p, max_blur=14, rise=18):
    """Returns (image, dy, alpha) for a blur-to-sharp entrance at progress p."""
    if p >= 1:
        return im, 0, 1
    q = ease_out(p)
    r = (1 - q) * max_blur
    out = im.filter(ImageFilter.GaussianBlur(r)) if r > 0.3 else im
    return out, (1 - q) * rise, q


@lru_cache(None)
def _vignette():
    sw, sh = W // 8, H // 8
    m = Image.radial_gradient("L").resize((sw, sh))
    m = m.point(lambda v: int(clamp((v - 150) / 105) ** 1.6 * 170))
    m = m.resize((W, H), Image.BICUBIC)
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.putalpha(m)
    return out


def card_bg(t, glow=True):
    """Black with a slow orange glow, for type cards."""
    return _card_bg(int(t * 10) % 1000 if glow else -1)


@lru_cache(64)
def _card_bg(phase):
    im = Image.new("RGB", (W // 6, H // 6), (4, 4, 6))
    if phase >= 0:
        d = ImageDraw.Draw(im)
        sw, sh = im.size
        ang = phase / 1000 * math.tau * 2
        cx, cy = sw * (0.5 + 0.18 * math.cos(ang)), sh * (0.62 + 0.1 * math.sin(ang))
        for i in range(24, 0, -1):
            rr = sw * 0.45 * i / 24
            a = (1 - i / 24) ** 2
            d.ellipse([cx - rr, cy - rr * 0.55, cx + rr, cy + rr * 0.55],
                      fill=(int(4 + 60 * a), int(4 + 22 * a), int(6 + 8 * a)))
        im = im.filter(ImageFilter.GaussianBlur(10))
    return im.resize((W, H), Image.BICUBIC)


def toast_region(frame, cam, t, t0, name):
    """Orbit's real Toast (captured in one window over this very stage, so its glass is right),
    with FloatingPanel's fade and rise; gone 1.6s later with its 0.12s fade."""
    if t < t0:
        return
    a, dy = panel_present(t, t0)
    if t >= t0 + 1.6:
        a *= panel_dismiss(t, t0 + 1.6)
    if a <= 0.001:
        return
    under, delta, (rx, ry) = _toast_parts(name)
    import numpy as np
    shift = int(round(dy * 2))
    if shift:
        delta = np.roll(delta, shift, axis=0)
        delta[:shift] = 0
    out = np.clip(under + delta * a, 0, 255).astype("uint8")
    im = Image.fromarray(out, "RGB").convert("RGBA")
    place(frame, im, cam, rx, ry, im.size[0] / 2, anchor=(0, 0), src_w=im.size[0])


@lru_cache(None)
def _toast_parts(name):
    import numpy as np
    # The toast's own pixels: its window capture minus the same window with no toast (both went
    # through the same colour pipeline), added onto the stage.
    cap = np.asarray(Image.open(real_path(f"toast/{name}.png")).convert("RGB"), dtype="float32")
    bd = np.asarray(Image.open(real_path("toast/backdrop.png")).convert("RGB"), dtype="float32")
    rx, ry = TOAST_REGION[0], TOAST_REGION[1]
    under = stage_still().crop((int(rx * 2), int(ry * 2), int(rx * 2) + cap.shape[1], int(ry * 2) + cap.shape[0]))
    return np.asarray(under, dtype="float32"), cap - bd, (rx, ry)


# The toast's capture window covers this stage region (points): x, y, w, h.
TOAST_REGION = (SW / 2 - 300, SH - 240, 600, 240)


# ---------------------------------------------------------------- scenes
# Times are absolute seconds. 120 BPM: a beat is 0.5s, a bar 2s. Scene changes sit on beats.

# Orbit's action glyphs (OrbitAction.symbol, rendered by Orbit) for the crowded opening line.
INTRO_GLYPHS = ["captureArea", "clipboard", "winLeft", "launcher", "keepAwake", "colorPicker", "captureText",
                "lockScreen", "winMaximize", "fanBoost", "translate", "winRight", "chargeLimit", "shelf",
                "recentCaptures", "captureScreen", "snippets", "darkMode", "displays", "notchToggle"]


@lru_cache(None)
def intro_glyph(name):
    path = real_path(f"symbols/{name}.png")
    if not os.path.exists(path):
        path = real_path("symbols/captureArea.png")
    im = Image.open(path).convert("RGBA")
    k = 50 / max(im.size)
    return im.resize((max(1, int(im.size[0] * k)), max(1, int(im.size[1] * k))), Image.LANCZOS)


def scene_intro(t):
    """0-4s: a crowded menu bar collapses into one planet. Drop at 4.0."""
    f = card_bg(t).copy()
    cx, cy = W / 2, H * 0.40
    names = [n for n in INTRO_GLYPHS]
    n = len(names)
    gap = 80
    collapse = ease_in(prog(t, 1.85, 2.35))
    for i, g in enumerate(names):
        appear = prog(t, 0.15 + i * 0.045, 0.45 + i * 0.045)
        if appear <= 0:
            continue
        gx = cx + (i - (n - 1) / 2) * gap
        x = lerp(gx, cx, collapse)
        y = cy - 6 * math.sin(t * 6 + i) * (1 - collapse)
        a = ease_out(appear) * (1 - prog(t, 2.2, 2.4))
        paste_screen(f, intro_glyph(g), x, y + (1 - ease_out(appear)) * 16, alpha=a)
    if t < 2.3:
        im = card_text(COPY["intro"], 58, 650, tracking=-0.01, max_w=1500)
        im2, dy, a = blur_in(im, prog(t, 0.55, 1.2))
        paste_screen(f, im2, W / 2, H * 0.56 + dy, alpha=a * (1 - prog(t, 1.9, 2.2)))
    if t >= 2.1:
        p = prog(t, 2.1, 2.75)
        s = spring(p, 1.4)
        size = 230 * s
        icon = asset("icon.png")
        k = size / icon.size[0]
        push = ease_in(prog(t, 3.55, 4.0))  # rushes at the camera into the drop
        k *= 1 + push * 9
        im = icon.resize((max(1, int(icon.size[0] * k)), max(1, int(icon.size[1] * k))), Image.BILINEAR)
        paste_screen(f, im, cx, cy + push * 60, alpha=clamp(p * 3) * (1 - prog(t, 3.85, 4.0)))
        first, second = COPY["one"]
        one = card_text(first, 64, 700, tracking=-0.015)
        orbit_grey = card_text(second, 64, 700, color=(140, 140, 146), tracking=-0.015)
        orbit_white = card_text(second, 64, 700, tracking=-0.015)
        wo = one.size[0] - 30
        total = wo + orbit_white.size[0] - 20
        y = H * 0.62
        fade = 1 - prog(t, 3.5, 3.75)
        im1, dy1, a1 = blur_in(one, prog(t, 2.55, 2.95))
        paste_screen(f, im1, W / 2 - total / 2, y + dy1, anchor=(0, 0.5), alpha=a1 * fade)
        im2, dy2, a2 = blur_in(orbit_grey, prog(t, 2.8, 3.2))
        x2 = W / 2 - total / 2 + wo
        paste_screen(f, im2, x2, y + dy2, anchor=(0, 0.5), alpha=a2 * fade)
        paste_screen(f, orbit_white, x2, y, anchor=(0, 0.5), alpha=prog(t, 3.1, 3.3) * fade)
    return f


# --- 4-10s: the ring, then an area capture ------------------------------------------------

RING_OPEN = 5.0       # middle button: the ring opens around the pointer
RING_HOVER_T = (5.8, 6.45)
RING_CLICK = 6.95     # click the top slot (Capture)
OVERLAY_T = (7.2, 8.72)  # the selection overlay is up (frozen screen)
DRAG_DOWN, DRAG_UP = 7.7, 8.7
CAPTURED = 8.72       # mouse up: the thumbnail comes in
SLOT = (RING_AT[0], RING_AT[1] - 112)  # OrbitRing.itemRadius


def ring_cursor(t):
    keys = [(4.0, (1750, 900)), (4.25, (1750, 900)), (4.95, RING_AT), (RING_HOVER_T[0], RING_AT),
            (RING_HOVER_T[1], SLOT), (RING_CLICK + 0.15, SLOT)]
    if t < RING_CLICK + 0.15:
        return keyframes(t, keys)
    if t < DRAG_DOWN:
        return lerp2(SLOT, SEL_A, ease_io(prog(t, RING_CLICK + 0.25, DRAG_DOWN - 0.08)))
    if t < DRAG_UP:
        return lerp2(SEL_A, SEL_B, ease_io(prog(t, DRAG_DOWN, DRAG_UP)))
    return lerp2(SEL_B, (1240, 860), ease_io(prog(t, 8.9, 9.6)))


def _dead_zone_time():
    # the first moment the pointer is past OrbitRing.deadZone (38pt) from the centre
    t = RING_HOVER_T[0]
    while t < RING_HOVER_T[1]:
        x, y = ring_cursor(t)
        if math.hypot(x - RING_AT[0], y - RING_AT[1]) > 38:
            return t
        t += 1 / 240
    return RING_HOVER_T[1]


RING_DZ = _dead_zone_time()


@lru_cache(64)
def ring_frame(name):
    return real(f"ring/{name}.png")


def ring_layers(t):
    """[(image, alpha)] of the real ring at time t, and its rise in points."""
    if t < RING_OPEN or t >= RING_CLICK + 0.12:
        return [], 0
    a, dy = panel_present(t, RING_OPEN)
    if t >= RING_CLICK:
        i = min(7, int((t - RING_CLICK) * 60))
        return [(ring_frame("close_%02d" % i), panel_dismiss(t, RING_CLICK))], 0
    if t < RING_DZ:
        return [(ring_frame("open_%02d" % min(30, int((t - RING_OPEN) * 60))), a)], dy
    # past the dead zone: the slot is selected (its spring pop shown as a 0.15s cross-fade)
    h = clamp((t - RING_DZ) / 0.15)
    if h >= 1:
        return [(ring_frame("hover"), a)], dy
    return [(ring_frame("open_30"), a), (ring_frame("hover"), a * h)], dy


@lru_cache(128)
def overlay_frame(k):
    return Image.open(real_path("overlay/overlay_%04d.jpg" % k)).convert("RGB")


def overlay_specs():
    """One state per frame while the overlay is up: pointer, drag start, selection (points)."""
    frames = []
    k = 0
    while OVERLAY_T[0] + k / FPS < OVERLAY_T[1]:
        tk = OVERLAY_T[0] + k / FPS
        mx, my = ring_cursor(tk)
        fr = {"mouse": [mx, my]}
        if tk >= DRAG_DOWN:
            fr["start"] = list(SEL_A)
        if tk > DRAG_DOWN:
            x0, y0 = min(SEL_A[0], mx), min(SEL_A[1], my)
            fr["sel"] = [x0, y0, abs(mx - SEL_A[0]), abs(my - SEL_A[1])]
        frames.append(fr)
        k += 1
    return frames


@lru_cache(None)
def quick_access():
    im = real("quickaccess.png")
    h = im.size[1] / 2
    return im, (4, SH - 4 - h)  # Size.edgeOffset - Space.standard from the bottom-left corner


def quick_access_layer(t):
    """The real thumbnail card sliding in from the leading edge: SwiftUI .move(edge: .leading)
    + .opacity at Motion.panelEnter (spring 0.24s, no bounce), inside FloatingPanel.present."""
    im, (x, y) = quick_access()
    s = swiftui_spring(t - CAPTURED, 0.24)
    a, dy = panel_present(t, CAPTURED)
    dx = -(16 + 240) * (1 - s)  # Space.standard + Size.thumbnailWidth
    # the panel clips the card while it slides in
    shifted = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ox = int(round(dx * 2))
    if ox > -im.size[0]:
        shifted.paste(im.crop((-ox, 0, im.size[0], im.size[1])) if ox < 0 else im, (max(0, ox), 0))
    return shifted, (x, y + dy), a * s


def scene_ring(t):
    cam = Camera(*keyframes(t, [(4.0, (SW / 2, SH / 2, 1.0)), (4.85, (SW / 2, SH / 2, 1.0)),
                                (5.45, (RING_AT[0] - 40, RING_AT[1] - 20, 1.75)), (6.4, (RING_AT[0], RING_AT[1] - 60, 1.85)),
                                (7.05, (RING_AT[0], RING_AT[1] - 60, 1.85)), (7.65, (560, 380, 1.45)),
                                (8.6, (820, 560, 1.3)), (9.15, (SW / 2, SH / 2, 1.0)), (9.5, (300, 880, 1.6)),
                                (10.0, (300, 880, 1.8))]))
    overlay = OVERLAY_T[0] <= t < OVERLAY_T[1]
    if overlay:
        # The real selection overlay, drawn by Orbit over the frozen screen.
        k = min(int(round((t - OVERLAY_T[0]) * FPS)), len(os.listdir(real_path("overlay"))) - 2)
        f = render_base(cam, overlay_frame(k))
    else:
        f = render_base(cam, stage_still())
    layers, dy = ring_layers(t)
    for im, a in layers:
        place(f, im, cam, RING_AT[0], RING_AT[1] + dy, 340, alpha=a, src_w=im.size[0])
    if t >= CAPTURED:
        im, (x, y), a = quick_access_layer(t)
        place2x(f, im, cam, x, y, alpha=a)
    kind = "cross" if overlay else "arrow"
    clicks = [RING_OPEN, RING_CLICK]
    if t >= 4.2:
        draw_cursor(f, cam, ring_cursor, t, kind=kind, press=press_amount(t, clicks + [DRAG_DOWN]))
    for c in clicks:
        ripple(f, cam, *ring_cursor(c), t, c)
    return f


# --- 10-13s: the editor, opened on that capture ----------------------------------------------

ED_OPEN = 10.0
ARROW_DOWN, ARROW_UP = 10.55, 11.2
COPY_CLICK = 12.0


@lru_cache(None)
def editor_meta():
    import json
    with open(real_path("editor/meta.json")) as fh:
        return json.load(fh)


def ed_rect():
    """Stage rect of the editor window: centred on the visible frame, at its real size."""
    m = editor_meta()
    w, h = m["size"][0] / 2, m["size"][1] / 2
    cy_cocoa = VISIBLE_H / 2
    return SW / 2 - w / 2, SH - cy_cocoa - h / 2, w, h


def ed_point(px, py):
    """Picture points -> stage points (from the editor's measured canvas mapping)."""
    m = editor_meta()
    x0, y0, _, _ = ed_rect()
    s, ox, oy = m["canvas"]
    return x0 + ox + px * s, y0 + oy + py * s


def editor_cursor(t):
    m = editor_meta()
    a = ed_point(*m["arrow_from"])
    b = ed_point(*m["arrow_to"])
    copy = (ed_rect()[0] + m["copy"][0], ed_rect()[1] + m["copy"][1])
    keys = [(10.0, (1260, 880)), (10.1, (1260, 880)), (ARROW_DOWN - 0.05, a), (ARROW_DOWN, a)]
    if t < ARROW_DOWN:
        return keyframes(t, keys)
    if t < ARROW_UP:
        return lerp2(a, b, ease_io(prog(t, ARROW_DOWN, ARROW_UP)))
    return keyframes(t, [(ARROW_UP, b), (11.4, b), (COPY_CLICK - 0.05, copy), (13.0, copy)])


def editor_cursor_kind(t):
    """Crosshair over the canvas (the arrow tool), the arrow elsewhere — EditorView's own choice."""
    m = editor_meta()
    x, y = editor_cursor(t)
    x0, y0, _, _ = ed_rect()
    cx0, cy0, cw, ch = m["canvas_rect"]
    inside = x0 + cx0 <= x <= x0 + cx0 + cw and y0 + cy0 <= y <= y0 + cy0 + ch
    return "cross" if inside else "arrow"


@lru_cache(64)
def editor_frame(name):
    return real(f"editor/{name}.png")


def scene_editor(t):
    m = editor_meta()
    a = ed_point(*m["arrow_from"])
    b = ed_point(*m["arrow_to"])
    copy = (ed_rect()[0] + m["copy"][0], ed_rect()[1] + m["copy"][1])
    mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    cam = Camera(*keyframes(t, [(10.0, (SW / 2, SH / 2, 1.0)), (10.25, (SW / 2, SH / 2, 1.0)),
                                (10.6, (mid[0], mid[1], 1.55)), (11.3, (mid[0] + 20, mid[1], 1.6)),
                                (11.85, (copy[0] - 160, copy[1] + 90, 2.1)), (12.15, (copy[0] - 160, copy[1] + 90, 2.1)),
                                (12.45, (SW / 2, 700, 1.3)), (13.0, (SW / 2, 720, 1.35))]))
    f = render_base(cam, stage_still())
    if t < ARROW_DOWN:
        name = "base"
    elif t < ARROW_UP + 0.02:
        name = "drag_%02d" % min(m["drag_frames"] - 1, int((t - ARROW_DOWN) * FPS))
    else:
        name = "done"
    p, s = window_open(t, ED_OPEN)
    x0, y0, w, h = ed_rect()
    im = editor_frame(name)
    shadow, pad = _editor_shadow()
    place(f, shadow, cam, x0 + w / 2, y0 + h / 2, w, alpha=p, scale=s, shadow_pad=pad, src_w=shadow.size[0] - pad * 2)
    place(f, im, cam, x0 + w / 2, y0 + h / 2, w, alpha=p, scale=s, src_w=im.size[0])
    toast_region(f, cam, t, COPY_CLICK, "editor")
    draw_cursor(f, cam, editor_cursor, t, kind=editor_cursor_kind(t), press=press_amount(t, [ARROW_DOWN, COPY_CLICK]))
    ripple(f, cam, *copy, t, COPY_CLICK)
    return f


@lru_cache(None)
def _editor_shadow():
    """macOS's window shadow under the editor (the capture is taken without it)."""
    im = editor_frame("base")
    blur, alpha, dy, scale = 46, 170, 22, 0.25
    pad = int(blur * 2 / scale)
    w, h = im.size
    small = Image.new("L", (int((w + pad * 2) * scale), int((h + pad * 2) * scale)), 0)
    mask = im.getchannel("A").resize((int(w * scale), int(h * scale)))
    small.paste(mask.point(lambda v: alpha if v > 8 else 0), (int(pad * scale), int((pad + dy / scale) * scale)))
    small = small.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    out.putalpha(small.resize(out.size, Image.BILINEAR))
    return out, pad


# --- 13-16s: the launcher -----------------------------------------------------------------

LA_SHOW = 13.35
LA_TYPE = [13.95 + i * 0.15 for i in range(6)]
LA_ENTER = 15.2
# After "2" the launcher lists clipboard history (the user's own), so that keystroke keeps the empty state.
LA_STATES = ["launcher_empty.png", "launcher_t2.png", "launcher_t3.png", "launcher_t4.png", "launcher_t6.png",
             "launcher_math.png"]


def la_rect():
    """LauncherPanel.show: Size.launcher (680x480) at 62% up the visible frame, centred."""
    w, h = 680, 480
    cy_cocoa = VISIBLE_H * 0.62
    return SW / 2 - w / 2, SH - cy_cocoa - h / 2, w, h


@lru_cache(None)
def _launcher(name):
    return shadowed(name, blur=50, alpha=170)


@lru_cache(None)
def keycap(name):
    im = real(f"keys/{name}.png")  # Orbit's KeyCap at 8x
    return im.resize((im.size[0] // 2, im.size[1] // 2), Image.LANCZOS)


def scene_launcher(t):
    x0, y0, w, h = la_rect()
    field = (x0 + 0.18 * w, y0 + 0.06 * h)
    result = (x0 + 0.2 * w, y0 + 0.215 * h)
    cam = Camera(*keyframes(t, [(13.0, (SW / 2, SH / 2, 1.0)), (13.6, (SW / 2, y0 + h / 2, 1.1)),
                                (14.0, (field[0] + 140, field[1] + 30, 1.95)), (14.75, (field[0] + 170, field[1] + 30, 1.95)),
                                (15.05, (result[0] + 140, result[1], 2.05)), (15.22, (result[0] + 140, result[1], 2.05)),
                                (15.55, (SW / 2, 700, 1.3)), (16.0, (SW / 2, 720, 1.35))]))
    f = render_base(cam, stage_still())
    if LA_SHOW <= t < LA_ENTER + 0.12:
        n = sum(1 for tt in LA_TYPE if t >= tt)
        name = "launcher_empty.png" if n == 0 else LA_STATES[n - 1]
        a, dy = panel_present(t, LA_SHOW)
        if t >= LA_ENTER:
            a *= panel_dismiss(t, LA_ENTER)
        im, pad = _launcher(name)
        place(f, im, cam, x0, y0 + dy, w, alpha=a, anchor=(0, 0), shadow_pad=pad)
    toast_region(f, cam, t, LA_ENTER, "launcher")
    # keycaps: Orbit's KeyCap, big, as the promo's keystroke callouts
    ka = prog(t, 13.05, 13.18) * (1 - prog(t, 13.7, 13.9))
    if ka > 0:
        kp = press_amount(t, [13.3]) * 5
        c1, c2 = keycap("cmd"), keycap("space")
        total = c1.size[0] + c2.size[0] + 12
        paste_screen(f, c1, W / 2 - total / 2, H * 0.80 + kp, anchor=(0, 0.5), alpha=ka)
        paste_screen(f, c2, W / 2 - total / 2 + c1.size[0] + 12, H * 0.80 + kp, anchor=(0, 0.5), alpha=ka)
    ra = prog(t, LA_ENTER - 0.25, LA_ENTER - 0.12) * (1 - prog(t, LA_ENTER + 0.25, LA_ENTER + 0.4))
    if ra > 0:
        paste_screen(f, keycap("return"), W / 2, H * 0.80 + press_amount(t, [LA_ENTER]) * 5, alpha=ra)
    return f  # no pointer: macOS hides it while you type


# --- 16-20s: the notch --------------------------------------------------------------------

NOTCH_EARS = 16.35      # music starts: the ears grow
NOTCH_OPEN = 17.27      # pointer rests on it (openDelay 0.12s after it arrives)
NOTCH_CLOSE = 18.85     # pointer left 0.35s ago (closeDelay)
NOTCH_PEEK = 19.25      # plugged in: the charging notice


@lru_cache(None)
def notch_burst(name):
    d = real_path(f"notch/{name}")
    fs = sorted(x for x in os.listdir(d) if x.endswith(".png"))
    return [(int(x[:4]) / 1000, os.path.join(d, x)) for x in fs]


@lru_cache(256)
def _notch_img(path):
    return Image.open(path).convert("RGBA")


def notch_at(name, dt):
    frames = notch_burst(name)
    if dt >= frames[-1][0]:
        return _notch_img(frames[-1][1])
    best = min(frames, key=lambda fr: abs(fr[0] - dt))
    return _notch_img(best[1])


def notch_image(t):
    if t < NOTCH_EARS:
        return notch_rest()
    if t < NOTCH_OPEN:
        return notch_at("ears", t - NOTCH_EARS)
    if t < NOTCH_CLOSE:
        return notch_at("open", t - NOTCH_OPEN)
    if t < NOTCH_PEEK:
        return notch_at("close", t - NOTCH_CLOSE)
    return notch_at("charge", t - NOTCH_PEEK)


def notch_cursor(t):
    rest = (SW / 2 + 30, 14)
    return keyframes(t, [(16.0, (1180, 640)), (16.6, (1180, 640)), (NOTCH_OPEN - 0.14, rest), (18.2, rest),
                         (18.5, (SW / 2 + 360, 420)), (20.0, (SW / 2 + 380, 430))])


def scene_notch(t):
    cam = Camera(*keyframes(t, [(16.0, (SW / 2, 300, 1.6)), (16.45, (SW / 2, 0, 3.3)), (17.1, (SW / 2, 0, 3.3)),
                                (17.5, (SW / 2, 0, 2.35)), (18.75, (SW / 2, 0, 2.35)), (19.2, (SW / 2, 0, 3.3)),
                                (20.0, (SW / 2, 0, 3.4))]))
    f = render_base(cam, stage_still())
    im = notch_image(t)
    place2x(f, im, cam, SW / 2, 0, anchor=(0.5, 0))
    if t >= 16.5:
        draw_cursor(f, cam, notch_cursor, t)
    return f


# --- 20-22s: the verb run -----------------------------------------------------------------

VERBS = [(20.0 + i * 0.5, 20.5 + i * 0.5, words, shot, box) for i, (words, (shot, box)) in enumerate(zip(COPY["verbs"], [
    ("windows.png", (0.20, 0.13, 1.0, 0.62)),
    ("translate.png", (0.20, 0.13, 1.0, 0.62)),
    ("menubar.png", (0.20, 0.10, 1.0, 0.66)),
    ("awake.png", (0.20, 0.10, 1.0, 0.70)),
]))]


@lru_cache(None)
def _verb_card(name, box):
    im = asset("screens/" + name)
    w, h = im.size
    crop = im.crop((int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)))
    m = Image.new("L", crop.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, crop.size[0], crop.size[1]], radius=40, fill=255)
    crop.putalpha(ImageChops.multiply(crop.getchannel("A"), m))
    pad = 120
    out = Image.new("RGBA", (crop.size[0] + pad * 2, crop.size[1] + pad * 2), (0, 0, 0, 0))
    sm = Image.new("L", out.size, 0)
    ImageDraw.Draw(sm).rounded_rectangle([pad, pad + 40, pad + crop.size[0], pad + 40 + crop.size[1]], radius=40, fill=190)
    out.putalpha(sm.filter(ImageFilter.GaussianBlur(50)))
    out.alpha_composite(crop, (pad, pad))
    return out, pad


@lru_cache(None)
def _verb_size(words, size=82, max_w=820):
    """One size for the whole line, so it ends before the page card (left edge ~1010)."""
    while size > 40:
        w = sum(card_text(wd, size, 750, tracking=-0.02).size[0] - size * 0.36 for wd in words.split(" ")) - size * 0.24
        if w <= max_w:
            break
        size -= 2
    return size


def scene_verbs(t):
    """One feature per beat (Apple's verb run, GitHub's blur-in)."""
    f = card_bg(t).copy()
    for (a, b, words, shot, box) in VERBS:
        if not (a <= t < b):
            continue
        local = t - a
        card, pad = _verb_card(shot, box)
        p = ease_out(prog(local, 0, 0.22))
        cam = Camera()
        place(f, card, cam, 1440 + (1 - p) * 260 - local * 30, SH / 2, 860, alpha=p, shadow_pad=pad, scale=lerp(1.04, 1, p))
        x = 140
        size = _verb_size(words)
        for i, wd in enumerate(words.split(" ")):
            im = card_text(wd, size, 750, tracking=-0.02)
            im2, dy, al = blur_in(im, prog(local, 0.02 + i * 0.06, 0.24 + i * 0.06), max_blur=10, rise=40)
            paste_screen(f, im2, x, SH / 2 - 10 + dy, anchor=(0, 0.5), alpha=al)
            x += im.size[0] - size * 0.36
    return f


WALL = ["home.png", "ring.png", "capture.png", "windows.png", "translate.png", "battery.png", "menubar.png",
        "awake.png", "system.png", "displays.png", "notch.png", "corners.png"]


@lru_cache(None)
def _wall():
    cols, rows = 6, 4
    tw, th = 1084, 949
    gap = 60
    im = Image.new("RGB", (cols * tw + (cols + 1) * gap, rows * th + (rows + 1) * gap), (6, 6, 8))
    for r in range(rows):
        for c in range(cols):
            name = WALL[(r * cols + c + r * 2) % len(WALL)]
            s = asset("screens/" + name).resize((tw, th), Image.BILINEAR)
            im.paste(s, (gap + c * (tw + gap), gap + r * (th + gap)), s)
    return im


def scene_wall(t):
    """22-26s: pull back from one page to a wall of them (Claude Design's zoom-out)."""
    wall = _wall()
    ww, wh = wall.size
    tile_cx = 60 + 2 * (1084 + 60) + 1084 / 2
    tile_cy = 60 + 1 * (949 + 60) + 949 / 2
    z0 = H / 949 * 0.92
    z1 = max(W / ww, H / wh) * 1.03
    p = ease_io(prog(t, 22.0, 24.2))
    z = math.exp(lerp(math.log(z0), math.log(z1), p))
    vw, vh = W / z, H / z
    cx = clamp(lerp(tile_cx, ww / 2, p), vw / 2, ww - vw / 2)
    cy = clamp(lerp(tile_cy, wh / 2, p), vh / 2, wh - vh / 2)
    f = wall.resize((W, H), Image.BILINEAR, box=(cx - vw / 2, cy - vh / 2, cx + vw / 2, cy + vh / 2))
    dim = prog(t, 23.6, 24.3)
    if dim > 0:
        f = Image.blend(f, f.filter(ImageFilter.GaussianBlur(10)).point(lambda v: int(v * 0.28)), dim)
    if t >= 23.9:
        l1 = card_text(COPY["wall"][0], 96, 750, tracking=-0.02, max_w=1700)
        l2 = card_text(COPY["wall"][1], 96, 750, color=ORANGE, tracking=-0.02, max_w=1700)
        a1 = blur_in(l1, prog(t, 23.9, 24.35), rise=30)
        a2 = blur_in(l2, prog(t, 24.4, 24.85), rise=30)
        fade = 1 - prog(t, 25.6, 25.95)
        paste_screen(f, a1[0], W / 2, H / 2 - 60 + a1[1], alpha=a1[2] * fade)
        paste_screen(f, a2[0], W / 2, H / 2 + 60 + a2[1], alpha=a2[2] * fade)
    return f


CTA = "github.com/3x-haust/Orbit"
CTA_T0, CTA_STEP = 26.35, 0.055


def scene_cta(t):
    """26-28s: typed on with a block cursor (Linear)."""
    f = card_bg(t, glow=False).copy()
    small = card_text(COPY["free"], 34, 500, color=(150, 150, 156))
    im, dy, a = blur_in(small, prog(t, 26.05, 26.45))
    paste_screen(f, im, W / 2, H / 2 - 70 + dy, alpha=a)
    n = int(clamp((t - CTA_T0) / CTA_STEP, 0, len(CTA)))
    shown = CTA[:n]
    size = 64
    txt = text_image(shown or " ", size, 500, kind="mono")
    full = text_image(CTA, size, 500, kind="mono")
    x0 = W / 2 - full.size[0] / 2
    paste_screen(f, txt, x0, H / 2 + 20, anchor=(0, 0.5))
    if (n < len(CTA)) or (int(t * 4) % 2 == 0):
        fm = font("mono", size, 500)
        cx = x0 + size * 0.3 + fm.getlength(shown)
        cur = Image.new("RGBA", (int(size * 0.58), int(size * 1.05)), ORANGE + (255,))
        paste_screen(f, cur, cx + 4, H / 2 + 20 + size * 0.08, anchor=(0, 0.5))
    return f


def scene_logo(t):
    """28-32s: lockup."""
    f = card_bg(t).copy()
    p = spring(prog(t, 28.0, 28.5), 1.2)
    icon = asset("icon.png")
    size = 220
    k = size / icon.size[0] * lerp(0.7, 1, p)
    im = icon.resize((int(icon.size[0] * k), int(icon.size[1] * k)), Image.BICUBIC)
    word = text_image("Orbit", 150, 760, tracking=-0.035)
    fade = 1 - prog(t, END - 0.7, END - 0.05)
    gap = 28
    total = size + gap + word.size[0] - 40
    x0 = W / 2 - total / 2
    paste_screen(f, im, x0 + size / 2, H / 2 - 40, alpha=clamp(p * 2) * fade)
    w2, dy, a = blur_in(word, prog(t, 28.25, 28.7))
    paste_screen(f, w2, x0 + size + gap - 20, H / 2 - 52 + dy, anchor=(0, 0.5), alpha=a * fade)
    ybase = H / 2 + 120
    paste_screen(f, _badge("1.0"), W / 2, ybase, alpha=prog(t, 28.75, 29.05) * fade)
    ko = card_text(COPY["tagline"], 36, 500, color=(170, 170, 176), max_w=1400)
    k2, dy2, a2 = blur_in(ko, prog(t, 29.1, 29.6))
    paste_screen(f, k2, W / 2, ybase + 80 + dy2, alpha=a2 * fade)
    return f


@lru_cache(None)
def _badge(text):
    lab = text_image(text, 30, 700, color=ORANGE)
    w, h = lab.size[0] + 10, 54
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle([0, 0, w - 1, h - 1], radius=27, fill=ORANGE + (38,), outline=ORANGE + (120,), width=2)
    im.alpha_composite(lab, ((w - lab.size[0]) // 2, (h - lab.size[1]) // 2 + 1))
    return im


SCENES = [(0.0, 4.0, scene_intro), (4.0, 10.0, scene_ring), (10.0, 13.0, scene_editor),
          (13.0, 16.0, scene_launcher), (16.0, 20.0, scene_notch), (20.0, 22.0, scene_verbs),
          (22.0, 26.0, scene_wall), (26.0, 28.0, scene_cta), (28.0, 99.0, scene_logo)]  # the logo holds until the track ends

# blur-dissolves into these scene starts (the 4.0 drop is a white flash instead)
DISSOLVE = {10.0: 0.3, 13.0: 0.3, 16.0: 0.3, 20.0: 0.2, 22.0: 0.25, 26.0: 0.3, 28.0: 0.35}

# Sound cues (film seconds) for the UI sounds in soundtrack.py.
CUES = {
    "clicks": [RING_OPEN, RING_CLICK, DRAG_DOWN, CAPTURED, ARROW_DOWN, COPY_CLICK, 13.3, LA_ENTER],
    "keys": LA_TYPE + [CTA_T0 + i * CTA_STEP for i in range(len(CTA))],
    "whoosh": [s - 0.2 for s in DISSOLVE],
    "notch": [NOTCH_EARS, NOTCH_OPEN, NOTCH_CLOSE, NOTCH_PEEK],
}


def scene_at(t):
    for a, b, fn in SCENES:
        if a <= t < b:
            return a, fn
    return SCENES[-1][0], SCENES[-1][2]


def frame_at(t):
    start, fn = scene_at(t)
    f = fn(t).convert("RGB")
    d = DISSOLVE.get(start)
    if d and t < start + d:
        prev = [s for s in SCENES if s[1] == start][0][2]
        x = ease_io((t - start) / d)
        old = prev(start - 1 / FPS).convert("RGB").filter(ImageFilter.GaussianBlur(4 + 14 * x))
        f = Image.blend(old, f, x)
    if 4.0 <= t < 4.35:  # the drop: white flash into the desktop
        a = 1 - ease_out((t - 4.0) / 0.35)
        f.paste(Image.new("RGB", (W, H), (255, 255, 255)), (0, 0), Image.new("L", (W, H), int(255 * a * 0.85)))
    v = _vignette()
    f.paste(v, (0, 0), v)
    if t > END - 0.5:
        f = Image.blend(f, Image.new("RGB", (W, H), (0, 0, 0)), prog(t, END - 0.5, END))
    return f


OUT_FPS = 30 if PREVIEW else FPS
OUT_W, OUT_H = (640, 360) if PREVIEW else (W, H)


def render_frame(i):
    im = frame_at(i / OUT_FPS * WARP).convert("RGB")
    if PREVIEW:
        im = im.resize((OUT_W, OUT_H), Image.BILINEAR)
    return im.tobytes()


# ---------------------------------------------------------------- main

def render_silent(path):
    total = int(round(END / WARP * OUT_FPS))
    ff = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{OUT_W}x{OUT_H}",
                           "-r", str(OUT_FPS), "-i", "-", "-c:v", "libx264", "-preset", "veryfast" if PREVIEW else "slow",
                           "-crf", "23" if PREVIEW else "16",
                           "-pix_fmt", "yuv420p", "-movflags", "+faststart", path], stdin=subprocess.PIPE)
    with Pool(max(1, os.cpu_count() - 1)) as pool:
        for k, data in enumerate(pool.imap(render_frame, range(total), chunksize=6)):
            ff.stdin.write(data)
            if k % 240 == 0:
                print(f"frame {k}/{total}", flush=True)
    ff.stdin.close()
    ff.wait()


# ---------------------------------------------------------------- mux, 9:16

def mux(silent, wav, out, pre=""):
    """Video (through an optional filter `pre` ending in [v]) + the soundtrack."""
    vid = ["-filter_complex", pre, "-map", "[v]", "-c:v", "libx264", "-preset", "slow", "-crf", "16"] if pre \
        else ["-map", "0:v", "-c:v", "copy"]
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", silent, "-i", wav, *vid, "-map", "1:a",
                    "-c:a", "aac", "-b:a", "320k", "-shortest", "-movflags", "+faststart", out], check=True)
    print("wrote", out, flush=True)


# 9:16 for reels: the 16:9 film over a blurred, enlarged copy of itself.
VERTICAL = ("[0:v]split[a][b];[a]scale=-2:1920,crop=1080:1920,gblur=sigma=40,eq=brightness=-0.18[bg];"
            "[b]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]")


# A file from each capture step: if one is missing, that step hasn't run for this language.
REQUIRED = ["icon.png", "cursors/arrow.png", "real/cover.png", "real/menubar-icon.png", "real/symbols/apps.png",
            "screens/home.png", "screens/corners.png", "launcher_empty.png", "launcher_math.png",
            "real/ring/appear.json", "real/keys/space.png", "real/notch/still_closed.png", "real/notch/charge",
            "real/capture.png", "real/quickaccess.png", "real/editor/meta.json", "real/toast/editor.png",
            "real/overlay/done"]


def check_assets():
    missing = [n for n in REQUIRED if not os.path.exists(os.path.join(ASSETS, local(n)))]
    if missing:
        sys.exit(f"render.py: tools/promo/assets is missing {', '.join(local(n) for n in missing)} for '{LANG}'.\n"
                 f"The captured frames aren't in the repo: run capture.py and then prepare.py first, with build-promo's\n"
                 f"DEBUG Orbit running in that language (see docs/promo/README.md).")


def main():
    global WARP, END
    check_assets()
    os.makedirs(OUT_DIR, exist_ok=True)
    if "--still" in sys.argv:
        i = sys.argv.index("--still")
        frame_at(float(sys.argv[i + 1])).save(sys.argv[i + 2])
        return
    args = sys.argv[1:]
    langs = args[args.index("--lang") + 1].split(",") if "--lang" in args else ["en", "ko"]
    want = {"PROMO_LANG": langs[0], "PROMO_PREVIEW": "1" if "--preview" in args else ""}
    if len(langs) > 1 or any(os.environ.get(k, "") != v for k, v in want.items()):
        # one process per language: the copy, the asset folder and the output size are fixed at import
        if "--lang" in args:
            del args[args.index("--lang"):args.index("--lang") + 2]
        for lang in langs:
            env = dict(os.environ, PROMO_LANG=lang, PROMO_PREVIEW=want["PROMO_PREVIEW"])
            subprocess.run([sys.executable, os.path.abspath(__file__), *args, "--lang", lang], env=env, check=True)
        return
    import soundtrack
    build = os.path.join(HERE, "build")
    os.makedirs(build, exist_ok=True)
    slug = next(iter(soundtrack.tracks()))
    WARP, end = soundtrack.timing(slug)
    WARP, end = float(WARP), float(end)  # repr() below must stay a plain float for the workers
    END = end * WARP
    os.environ["PROMO_WARP"], os.environ["PROMO_END"] = repr(WARP), repr(END)
    tag = f"preview-{LANG}" if PREVIEW else LANG
    silent = os.path.join(build, f"silent-{tag}.mp4")
    if "--reuse" not in args or not os.path.exists(silent):
        print(f"{slug} [{tag}]: film x{WARP:.4f}, {end:.2f}s", flush=True)
        render_silent(silent)
    wav = os.path.join(build, f"soundtrack-{slug}.wav")
    if "--reuse" not in args or not os.path.exists(wav):
        soundtrack.render(slug, wav)
    if PREVIEW:
        mux(silent, wav, os.path.join(build, f"preview-{LANG}.mp4"))
        return
    mux(silent, wav, os.path.join(OUT_DIR, f"orbit-promo-16x9-{LANG}.mp4"))
    if "--vertical" in args:
        mux(silent, wav, os.path.join(OUT_DIR, f"orbit-promo-9x16-{LANG}.mp4"), pre=VERTICAL)


if __name__ == "__main__":
    main()
