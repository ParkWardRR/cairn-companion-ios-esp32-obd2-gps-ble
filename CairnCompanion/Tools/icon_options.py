#!/usr/bin/env python3
"""Renders five alternative Cairn Companion icon directions into Tools/icon-options/ for comparison.

Flat, bold, rounded shapes with restrained gradients: the system adds glass, light and edge highlights.
"""
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE, SS = 1024, 2
N = SIZE * SS
HERE = Path(__file__).resolve().parent
OUT = HERE / "icon-options"


def rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)


def solid(h, a=255):
    return Image.new("RGBA", (N, N), tuple(int(v) for v in rgb(h)) + (a,))


def linear(c0, c1, angle=90):
    """Gradient from c0 to c1; angle 90 = top to bottom, 45 = top-left to bottom-right."""
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) / N
    a = math.radians(angle)
    t = np.clip((xx - 0.5) * math.cos(a) + (yy - 0.5) * math.sin(a) + 0.5, 0, 1)[..., None]
    c = rgb(c0) * (1 - t) + rgb(c1) * t
    return Image.fromarray(np.clip(c, 0, 255).astype(np.uint8)).convert("RGBA")


def radial(center_hex, edge_hex, cx=0.5, cy=0.4, spread=0.8):
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) / N
    t = np.clip(np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / spread, 0, 1)[..., None] ** 1.2
    c = rgb(center_hex) * (1 - t) + rgb(edge_hex) * t
    return Image.fromarray(np.clip(c, 0, 255).astype(np.uint8)).convert("RGBA")


def paint(fill, mask):
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.paste(fill, (0, 0), mask)
    return out


def over(base, *layers):
    for layer in layers:
        base = Image.alpha_composite(base, layer)
    return base


def P(x, y):
    return (x * SS, y * SS)


def poly(points):
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).polygon([P(*p) for p in points], fill=255)
    return m


def disc(cx, cy, r):
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).ellipse([P(cx - r, cy - r), P(cx + r, cy + r)], fill=255)
    return m


def soften(m, radius):
    """Rounds convex corners and anti-aliases: blur, threshold, blur."""
    return m.filter(ImageFilter.GaussianBlur(radius * SS)).point(lambda p: 255 if p > 128 else 0).filter(
        ImageFilter.GaussianBlur(0.8 * SS))


def arc(cx, cy, r, w, start, end, caps=True):
    """Arc stroke, PIL angles clockwise from 3 o'clock. start > end wraps through 0."""
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    spans = [(start, end)] if start <= end else [(start, 360), (0, end)]
    Ro = (r + w / 2) * SS
    for s, e in spans:
        d.arc([cx * SS - Ro, cy * SS - Ro, cx * SS + Ro, cy * SS + Ro], s, e, fill=255, width=int(w * SS))
    if caps:
        for ang in (start, end):
            px = cx + r * math.cos(math.radians(ang))
            py = cy + r * math.sin(math.radians(ang))
            d.ellipse([P(px - w / 2, py - w / 2), P(px + w / 2, py + w / 2)], fill=255)
    return m


def shadow(mask, dy=14, blur=22, opacity=0.4):
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    m = ImageChops.offset(mask, 0, dy * SS).filter(ImageFilter.GaussianBlur(blur * SS)).point(lambda p: int(p * opacity))
    sh.paste(solid("#000000"), (0, 0), m)
    return sh


def glow(layer, blur, gain):
    g = layer.filter(ImageFilter.GaussianBlur(blur * SS))
    r, gch, b, a = g.split()
    return Image.merge("RGBA", (r, gch, b, a.point(lambda p: min(255, int(p * gain)))))


def nav_arrow(cx, cy, scale, tilt):
    """Navigation arrowhead as (whole, left facet, right facet) masks."""
    t = math.radians(tilt)

    def pt(x, y):
        return (cx + (x * math.cos(t) - y * math.sin(t)) * scale, cy + (x * math.sin(t) + y * math.cos(t)) * scale)

    tip, br, notch, bl = pt(0, -1), pt(0.72, 0.92), pt(0, 0.46), pt(-0.72, 0.92)
    whole = soften(poly([tip, br, notch, bl]), 9)
    return whole, ImageChops.multiply(whole, poly([tip, bl, notch])), ImageChops.multiply(whole, poly([tip, br, notch]))


# ---------------------------------------------------------------- the five directions

def waypoint():
    """Faceted trail-marker peak with a beacon above it. Earthy green: stands out from the sea of blue."""
    bg = radial("#1F7A55", "#06201A", cy=0.3)
    apex, bl, br, base_mid = (512, 300), (190, 830), (834, 830), (512, 830)
    whole = soften(poly([apex, br, bl]), 40)
    left = ImageChops.multiply(whole, poly([apex, bl, base_mid]))
    right = ImageChops.multiply(whole, poly([apex, br, base_mid]))
    beacon = paint(solid("#E8FF7A"), disc(512, 168, 64))
    return over(bg, shadow(whole, 18, 26, 0.45), paint(solid("#E8F8A8"), left), paint(solid("#A9E063"), right),
                glow(beacon, 26, 1.8), beacon)


def pin():
    """Bold map pin, sunset gradient. Warm and high-contrast; reads as location instantly."""
    bg = linear("#FF9A3D", "#D8246F", 60)
    cx, cy, r, tip = 512, 440, 250, 860
    d = tip - cy
    a = math.acos(r / d)
    pts = []
    for s in (-1, 1):
        ang = s * a
        ux, uy = math.sin(ang), math.cos(ang)  # rotate (0,1) by ang
        pts.append((cx + r * ux, cy + r * uy))
    body = disc(cx, cy, r)
    tail = poly([pts[0], (cx, tip), pts[1], (cx, cy)])
    whole = soften(ImageChops.lighter(body, tail), 14)
    whole = ImageChops.subtract(whole, disc(cx, cy, 104))
    ground = Image.new("L", (N, N), 0)
    ImageDraw.Draw(ground).ellipse([P(cx - 150, tip + 12), P(cx + 150, tip + 52)], fill=255)
    return over(bg, shadow(ground, 0, 14, 0.35), shadow(whole, 16, 24, 0.35), paint(solid("#FFFFFF"), whole))


def gauge():
    """Dashboard gauge with a navigation-arrow needle. Black and ember: car-dash feel, own color space."""
    bg = radial("#23272E", "#07080A", cy=0.45, spread=0.85)
    ring = arc(512, 540, 340, 104, 140, 40)
    ring_img = paint(linear("#FFC02E", "#FF4A2A", 0), ring)
    whole, left, right = nav_arrow(512, 520, 215, 38)
    hub = disc(512, 560, 0)
    return over(bg, shadow(ring, 10, 18, 0.5), glow(ring_img, 28, 1.0), ring_img,
                shadow(whole, 14, 20, 0.55), paint(solid("#CDD3DB"), left), paint(solid("#FFFFFF"), right))


def signal_c():
    """Nested open arcs forming a C and a broadcast mark. Light pearl base: the odd one out on a dark wallpaper."""
    bg = linear("#FFFFFF", "#DDE3EC", 80)
    fills = linear("#0B1F3A", "#145A6E", 70)
    arcs = ImageChops.lighter(ImageChops.lighter(arc(520, 512, 125, 78, 48, 312), arc(520, 512, 250, 78, 48, 312)),
                              arc(520, 512, 375, 78, 48, 312))
    dot = disc(520, 512, 66)
    return over(bg, shadow(arcs, 8, 16, 0.15), paint(fills, arcs), paint(solid("#FF5A4E"), dot))


def link():
    """Two overlapping discs: phone and dongle, with the connection highlighted. Violet, flat Venn."""
    bg = linear("#1E1472", "#6B2FE0", 55)
    a, b = disc(394, 512, 240), disc(630, 512, 240)
    lens = ImageChops.multiply(a, b)
    return over(bg, shadow(ImageChops.lighter(a, b), 14, 24, 0.4),
                paint(solid("#FFFFFF"), a), paint(solid("#D4C4FF"), b), paint(solid("#4DF0CF"), lens))


OPTIONS = [
    ("1", "Waypoint", waypoint, "Faceted trail-marker peak with a beacon above it. A nod to the cairn (a trail marker) without stacked stones; forest green stands out from blue GPS apps."),
    ("2", "Pin", pin, "Chunky white map pin on a sunset gradient. The most instantly legible 'location' symbol, one focal point, warm and high-contrast."),
    ("3", "Gauge", gauge, "Ember dash gauge with a navigation-arrow needle. Speaks to the OBD-II side; black base keeps it premium and distinct."),
    ("4", "Signal C", signal_c, "Nested open arcs read as a C and as broadcast, with a coral beacon. Light pearl background pops against dark wallpapers."),
    ("5", "Link", link, "Two overlapping discs, phone and dongle, with the connection lit mint. Simple Venn, deep violet, very readable at 60 px."),
]


def main():
    OUT.mkdir(exist_ok=True)
    for key, name, fn, _ in OPTIONS:
        img = fn().convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
        img.save(OUT / f"option-{key}.png")
        print("wrote", key, name)
    cur = HERE.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    if cur.exists():
        shutil.copy(cur, OUT / "current.png")


if __name__ == "__main__":
    main()
