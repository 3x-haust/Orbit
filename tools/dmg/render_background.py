"""Draws the DMG window background: background.png (660x400) and background@2x.png (1320x800).

    python3 render_background.py <out-dir> [space|horizon|minimal] [--mockup app.png folder.png]

"space" (the one in use): near-black with star dust and a soft spotlight, one orbit through both
icon centres, and the orange satellite streaking along it towards Applications. "horizon" and
"minimal" are the other two directions that were tried.

Finder draws the icon labels in black on any custom background and, on a Mac with the path and
status bars turned on, covers the bottom 80pt of the window — so labels sit on something light
and everything that has to be seen stays in the top 320pt.

--mockup also writes mockup.png: the background with the real icons and labels where Finder
puts them, for judging the design without building a DMG.
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

args = list(sys.argv[1:])
MOCK = None
if "--mockup" in args:
    i = args.index("--mockup")
    MOCK = (args[i + 1], args[i + 2])
    del args[i:i + 3]
OUT = args[0] if args else os.path.dirname(os.path.abspath(__file__))
STYLE = args[1] if len(args) > 1 else "space"

PT_W, PT_H = 660, 400
SS = 4                                   # draw at 4x, scale down to 2x and 1x
W, H = PT_W * SS, PT_H * SS
APP, DIR = (170, 172), (490, 172)        # icon centres in points (match dmg_settings.py)
ICON = 128
LABEL_Y = APP[1] + ICON / 2 + 26         # centre of Finder's label line, in points (measured)

INK = (14, 14, 15)
ORANGE = (255, 107, 53)


def P(x):
    return x * SS


# ---------------------------------------------------------------- type

SF = "/System/Library/Fonts/SFNS.ttf"
KO = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
KO_INDEX = {"Regular": 0, "Medium": 2, "SemiBold": 4, "Bold": 6}


def sf(size, weight):
    f = ImageFont.truetype(SF, P(size))
    try:
        values = []
        for a in f.get_variation_axes():
            if a["name"] == b"Weight":
                values.append(weight)
            elif a["name"] == b"Optical Size":
                values.append(max(a["minimum"], min(a["maximum"], size)))
            else:
                values.append(a["default"])
        f.set_variation_by_axes(values)
    except Exception:
        pass
    return f


def ko(size, weight="Regular"):
    return ImageFont.truetype(KO, P(size), index=KO_INDEX[weight])


def text_width(s, f, tracking=0):
    return f.getlength(s) + P(tracking) * (len(s) - 1)


def draw_text(d, xy, s, f, fill, tracking=0):
    """Text with tracking, keeping the font's own kerning between pairs."""
    if tracking == 0:
        d.text(xy, s, font=f, fill=fill)
        return
    x, y = xy
    for i, ch in enumerate(s):
        d.text((x + f.getlength(s[:i]) + P(tracking) * i, y), ch, font=f, fill=fill)


def centered(d, y, s, f, fill, tracking=0, cx=PT_W / 2):
    draw_text(d, (P(cx) - text_width(s, f, tracking) / 2, P(y)), s, f, fill, tracking)


# ---------------------------------------------------------------- shapes

def layer():
    return Image.new("RGBA", (W, H), (0, 0, 0, 0))


def over(base, top):
    base.alpha_composite(top)


def bezier(p0, p1, p2, t):
    u = 1 - t
    return (u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0], u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1])


def stroke_path(d, pts, width, color_at):
    """A smooth round-capped stroke along points; colour (with alpha) can change along it."""
    r = width / 2
    for i in range(len(pts) - 1):
        (x0, y0), (x1, y1) = pts[i], pts[i + 1]
        n = max(1, int(math.dist(pts[i], pts[i + 1]) / (width / 5)))
        for k in range(n):
            t = k / n
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            d.ellipse((x - r, y - r, x + r, y + r), fill=color_at((i + t) / (len(pts) - 1)))


def arrowhead(d, tip, angle, size, color):
    a, s = angle, size
    left = (tip[0] - s * math.cos(a - 0.42), tip[1] - s * math.sin(a - 0.42))
    right = (tip[0] - s * math.cos(a + 0.42), tip[1] - s * math.sin(a + 0.42))
    back = (tip[0] - s * 0.62 * math.cos(a), tip[1] - s * 0.62 * math.sin(a))
    d.polygon([tip, left, back, right], fill=color)


def drag_arc(img, color, width=2.2, lift=30):
    """The path from Orbit.app to Applications: one smooth arc fading in, an arrowhead, and the
    satellite leaving a 4-step trail along it."""
    p0 = (P(APP[0] + 82), P(APP[1] - 10))
    p2 = (P(DIR[0] - 86), P(DIR[1] - 10))
    p1 = ((p0[0] + p2[0]) / 2, P(APP[1] - 10 - lift * 2))
    pts = [bezier(p0, p1, p2, i / 120) for i in range(121)]
    l = layer()
    d = ImageDraw.Draw(l)
    stroke_path(d, pts[:113], P(width), lambda t: color + (int(255 * min(1, 0.06 + t * 1.15)),))
    ang = math.atan2(pts[120][1] - pts[112][1], pts[120][0] - pts[112][0])
    arrowhead(d, pts[120], ang, P(10), color + (255,))
    over(img, l)
    sat = layer()
    ds = ImageDraw.Draw(sat)
    for t, a, r in [(0.52, 0.16, 2.4), (0.61, 0.32, 3.0), (0.70, 0.56, 3.7), (0.79, 1.0, 4.8)]:
        x, y = bezier(p0, p1, p2, t)
        ds.ellipse((x - P(r), y - P(r), x + P(r), y + P(r)), fill=ORANGE + (int(255 * a),))
    x, y = bezier(p0, p1, p2, 0.79)
    g = layer()
    ImageDraw.Draw(g).ellipse((x - P(13), y - P(13), x + P(13), y + P(13)), fill=ORANGE + (95,))
    over(img, g.filter(ImageFilter.GaussianBlur(P(6))))
    over(img, sat)


# ---------------------------------------------------------------- styles

def horizon():
    top, low = (250, 248, 244), (240, 234, 225)
    ramp = Image.linear_gradient("L").resize((W, H))
    img = Image.composite(Image.new("RGBA", (W, H), low + (255,)), Image.new("RGBA", (W, H), top + (255,)), ramp)

    # A huge black planet rising from the bottom edge; its top sits at 300pt, under the labels.
    R = P(1300)
    cx, cy = P(330), P(300) + R
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse((cx - R, cy - R, cx + R, cy + R), fill=255)

    halo = layer()
    ImageDraw.Draw(halo).ellipse((cx - R - P(26), cy - R - P(26), cx + R + P(26), cy + R + P(26)), fill=(255, 158, 110, 80))
    over(img, halo.filter(ImageFilter.GaussianBlur(P(20))))

    body = Image.new("RGBA", (W, H), (17, 17, 19, 255))
    # Faint bands across the surface, then grain.
    bd = ImageDraw.Draw(body)
    rnd = random.Random(3)
    for i in range(12):
        y = cy - R + P(5) + i * P(8) + rnd.randint(-P(2), P(2))
        bd.rectangle((0, y, W, y + P(3)), fill=(17 + rnd.randint(3, 9),) * 3 + (255,))
    body = body.filter(ImageFilter.GaussianBlur(P(2.5)))
    noise = Image.effect_noise((W, H), 28)
    body = Image.blend(body, Image.merge("RGBA", (noise, noise, noise, Image.new("L", (W, H), 255))), 0.07)
    # Shade towards the bottom so it reads as a sphere.
    shade = Image.linear_gradient("L").resize((W, H)).point(lambda v: int(v * 0.55))
    body = Image.composite(Image.new("RGBA", (W, H), (4, 4, 5, 255)), body, shade)
    img = Image.composite(body, img, mask)

    # Rim light on the edge, brightest at the top centre.
    rim = layer()
    ImageDraw.Draw(rim).ellipse((cx - R, cy - R, cx + R, cy + R), outline=(255, 222, 200, 230), width=round(P(1.4)))
    fade = Image.new("L", (W, H), 0)
    ImageDraw.Draw(fade).ellipse((P(60), P(250), P(600), P(350)), fill=255)
    fade = fade.filter(ImageFilter.GaussianBlur(P(40)))
    rim.putalpha(ImageChops.multiply(rim.getchannel("A"), fade))
    over(img, rim.filter(ImageFilter.GaussianBlur(P(0.4))))

    # The white ring, sweeping in front of the planet low in the window; its far side is hidden.
    ring = layer()
    rd = ImageDraw.Draw(ring)
    rcx, rcy, rx, ry = P(330), P(326), P(600), P(40)
    rd.ellipse((rcx - rx, rcy - ry, rcx + rx, rcy + ry), outline=(255, 255, 255, 240), width=round(P(2.6)))
    rd.ellipse((rcx - rx - P(16), rcy - ry - P(5), rcx + rx + P(16), rcy + ry + P(5)), outline=(255, 255, 255, 80), width=round(P(0.9)))
    ring = ring.rotate(-3, center=(rcx, rcy), resample=Image.BICUBIC)
    far = Image.new("L", (W, H), 0)
    ImageDraw.Draw(far).rectangle((0, 0, W, rcy), fill=255)
    ring.putalpha(ImageChops.subtract(ring.getchannel("A"), ImageChops.multiply(far, mask)))
    over(img, ring)

    d = ImageDraw.Draw(img)
    centered(d, 28, "Welcome to Orbit", sf(30, 760), INK, tracking=-0.7)
    centered(d, 72, "Drag Orbit to Applications", sf(12.5, 510), (112, 108, 102), tracking=0.05)
    centered(d, 91, "응용 프로그램으로 끌어 넣으세요", ko(11, "Medium"), (158, 152, 144))
    drag_arc(img, ORANGE)
    return img


def space():
    img = Image.new("RGBA", (W, H), (8, 8, 10, 255))
    spot = layer()
    ImageDraw.Draw(spot).ellipse((P(70), P(50), P(590), P(320)), fill=(255, 255, 255, 30))
    over(img, spot.filter(ImageFilter.GaussianBlur(P(60))))
    warm = layer()
    ImageDraw.Draw(warm).ellipse((P(390), P(110), P(590), P(240)), fill=ORANGE + (24,))
    over(img, warm.filter(ImageFilter.GaussianBlur(P(46))))
    rnd = random.Random(11)
    stars = layer()
    sd = ImageDraw.Draw(stars)
    for _ in range(240):
        x, y = rnd.uniform(0, W), rnd.uniform(0, H)
        r = rnd.choice([0.35, 0.45, 0.6, 0.8]) * SS
        sd.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, rnd.randint(30, 140)))
    over(img, stars)

    cx, cy = P((APP[0] + DIR[0]) / 2), P(APP[1])
    rx, ry = P((DIR[0] - APP[0]) / 2), P(46)
    orbit = layer()
    ImageDraw.Draw(orbit).ellipse((cx - rx, cy - ry, cx + rx, cy + ry), outline=(255, 255, 255, 110), width=round(P(1.2)))
    # The near (lower) half a little dimmer, for depth.
    depth = Image.new("L", (W, H), 255)
    ImageDraw.Draw(depth).rectangle((0, cy, W, H), fill=120)
    orbit.putalpha(ImageChops.multiply(orbit.getchannel("A"), depth.filter(ImageFilter.GaussianBlur(P(18)))))
    over(img, orbit)

    streak = layer()
    st = ImageDraw.Draw(streak)
    a0, a1 = math.radians(212), math.radians(296)
    for i in range(90):
        a = a0 + (a1 - a0) * i / 90
        x, y = cx + rx * math.cos(a), cy + ry * math.sin(a)
        f = i / 90
        r = P(0.9 + 2.6 * f)
        st.ellipse((x - r, y - r, x + r, y + r), fill=ORANGE + (int(220 * f ** 2.2),))
    over(img, streak)
    x, y = cx + rx * math.cos(a1), cy + ry * math.sin(a1)
    g = layer()
    ImageDraw.Draw(g).ellipse((x - P(16), y - P(16), x + P(16), y + P(16)), fill=ORANGE + (120,))
    over(img, g.filter(ImageFilter.GaussianBlur(P(8))))
    dot = layer()
    ImageDraw.Draw(dot).ellipse((x - P(5.5), y - P(5.5), x + P(5.5), y + P(5.5)), fill=ORANGE + (255,))
    over(img, dot)

    d = ImageDraw.Draw(img)
    for c, name in ((APP, "Orbit.app"), (DIR, "Applications")):
        w = text_width(name, sf(13, 400)) / SS + 34
        d.rounded_rectangle((P(c[0] - w / 2), P(LABEL_Y - 14), P(c[0] + w / 2), P(LABEL_Y + 14)), radius=P(14), fill=(242, 242, 244, 255))
    centered(d, 28, "Orbit", sf(32, 760), (255, 255, 255), tracking=-0.8)
    centered(d, 70, "Drag to Applications", sf(12.5, 510), (160, 160, 168), tracking=0.05)
    centered(d, 88, "응용 프로그램으로 끌어 넣으세요", ko(11, "Medium"), (105, 105, 112))
    return img


def minimal():
    img = Image.new("RGBA", (W, H), (250, 250, 248, 255))
    d = ImageDraw.Draw(img)
    for gx in range(8, PT_W, 16):
        for gy in range(8, PT_H, 16):
            r = 0.55 * SS
            d.ellipse((P(gx) - r, P(gy) - r, P(gx) + r, P(gy) + r), fill=(0, 0, 0, 24))
    clear = layer()
    for c in (APP, DIR):
        ImageDraw.Draw(clear).rounded_rectangle((P(c[0] - 86), P(c[1] - 80), P(c[0] + 86), P(LABEL_Y + 18)), P(28), fill=(250, 250, 248, 235))
    over(img, clear.filter(ImageFilter.GaussianBlur(P(10))))
    for i, a in enumerate((70, 150, 255)):
        x, y, s = P(PT_W / 2 - 20 + i * 20), P(APP[1] - 6), P(7)
        l = layer()
        stroke_path(ImageDraw.Draw(l), [(x - s, y - s * 1.3), (x + s * 0.4, y), (x - s, y + s * 1.3)], P(2.6), lambda t, a=a: ORANGE + (a,))
        over(img, l)
    d = ImageDraw.Draw(img)
    gx, gy = P(30), P(32)
    d.ellipse((gx - P(7), gy - P(7), gx + P(7), gy + P(7)), fill=INK)
    ring = layer()
    ImageDraw.Draw(ring).ellipse((gx - P(13), gy - P(4), gx + P(13), gy + P(4)), outline=INK + (255,), width=round(P(1.6)))
    over(img, ring.rotate(18, center=(gx, gy), resample=Image.BICUBIC))
    d = ImageDraw.Draw(img)
    d.ellipse((gx - P(14), gy + P(2), gx - P(8), gy + P(8)), fill=ORANGE)
    draw_text(d, (P(50), P(22)), "Orbit", sf(16, 700), INK, tracking=-0.3)
    centered(d, 282, "Drag Orbit to Applications", sf(12, 510), (130, 130, 128), tracking=0.05)
    centered(d, 299, "응용 프로그램으로 끌어 넣으세요", ko(10.5, "Medium"), (170, 170, 166))
    return img


img = {"horizon": horizon, "space": space, "minimal": minimal}[STYLE]().convert("RGB")
os.makedirs(OUT, exist_ok=True)
x2 = img.resize((PT_W * 2, PT_H * 2), Image.LANCZOS)
x2.save(os.path.join(OUT, "background@2x.png"), optimize=True)
img.resize((PT_W, PT_H), Image.LANCZOS).save(os.path.join(OUT, "background.png"), optimize=True)

if MOCK:
    m = x2.copy()
    d = ImageDraw.Draw(m)
    f = ImageFont.truetype(SF, 26)
    for c, path, label in ((APP, MOCK[0], "Orbit.app"), (DIR, MOCK[1], "Applications")):
        icon = Image.open(path).convert("RGBA").resize((ICON * 2, ICON * 2), Image.LANCZOS)
        m.paste(icon, (int(c[0] * 2 - ICON), int(c[1] * 2 - ICON)), icon)
        d.text((c[0] * 2 - d.textlength(label, font=f) / 2, LABEL_Y * 2 - 16), label, font=f, fill=(0, 0, 0))
    m.save(os.path.join(OUT, "mockup.png"))
print("background:", STYLE, OUT)
