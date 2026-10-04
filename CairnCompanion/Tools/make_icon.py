#!/usr/bin/env python3
"""Renders the Cairn Companion app icon (light, dark, tinted) into the asset catalog.

A dashboard gauge arc with a navigation-arrow needle: GPS plus the car. The palette is the original
ember design run through hue-rotate(-155deg) saturate(200%) brightness(118%), baked in below.
Requires Pillow and numpy:  python3 Tools/make_icon.py
"""
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE, SS = 1024, 2
N = SIZE * SS
OUT = Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets"

HUE, SAT, BRI = -155, 2.0, 1.18


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


def css_filter(img, hue=HUE, sat=SAT, bri=BRI):
    """Applies CSS hue-rotate, saturate and brightness (in that order) to an RGB image."""
    a = math.radians(hue)
    co, si = math.cos(a), math.sin(a)
    hm = np.array([
        [0.213 + co * 0.787 - si * 0.213, 0.715 - co * 0.715 - si * 0.715, 0.072 - co * 0.072 + si * 0.928],
        [0.213 - co * 0.213 + si * 0.143, 0.715 + co * 0.285 + si * 0.140, 0.072 - co * 0.072 - si * 0.283],
        [0.213 - co * 0.213 - si * 0.787, 0.715 - co * 0.715 + si * 0.715, 0.072 + co * 0.928 + si * 0.072],
    ], dtype=np.float32)
    sm = np.array([
        [0.213 + 0.787 * sat, 0.715 - 0.715 * sat, 0.072 - 0.072 * sat],
        [0.213 - 0.213 * sat, 0.715 + 0.285 * sat, 0.072 - 0.072 * sat],
        [0.213 - 0.213 * sat, 0.715 - 0.715 * sat, 0.072 + 0.928 * sat],
    ], dtype=np.float32)
    px = np.asarray(img.convert("RGB"), dtype=np.float32) / 255
    px = np.clip(px @ hm.T, 0, 1)
    px = np.clip(px @ sm.T, 0, 1)
    px = np.clip(px * bri, 0, 1)
    return Image.fromarray((px * 255 + 0.5).astype(np.uint8))


def gauge(bg_center, bg_edge, ring, arrow_left, arrow_right):
    bg = radial(bg_center, bg_edge, cy=0.45, spread=0.85)
    ring_m = arc(512, 540, 340, 104, 140, 40)
    ring_img = paint(linear(ring[0], ring[1], 0), ring_m)
    whole, left, right = nav_arrow(512, 520, 215, 38)
    return over(bg, shadow(ring_m, 10, 18, 0.5), glow(ring_img, 28, 1.0), ring_img,
                shadow(whole, 14, 20, 0.55), paint(solid(arrow_left), left), paint(solid(arrow_right), right))


def render(variant):
    if variant == "light":
        img = gauge("#23272E", "#07080A", ("#FFC02E", "#FF4A2A"), "#CDD3DB", "#FFFFFF")
    elif variant == "dark":
        img = gauge("#1A1D22", "#040506", ("#FFC02E", "#FF4A2A"), "#CDD3DB", "#FFFFFF")
    else:  # tinted: the system recolors luminance, so clean grayscale on near-black, no hue shift
        img = gauge("#2A2A2A", "#000000", ("#FFFFFF", "#9A9A9A"), "#CFCFCF", "#FFFFFF")
    img = img.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    return img if variant == "tinted" else css_filter(img)


def main():
    icon_dir = OUT / "AppIcon.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    names = {"light": "AppIcon.png", "dark": "AppIcon-Dark.png", "tinted": "AppIcon-Tinted.png"}
    for variant, name in names.items():
        render(variant).save(icon_dir / name, "PNG")
        print("wrote", icon_dir / name)

    contents = {
        "images": [
            {"filename": names["light"], "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": names["dark"], "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
             "filename": names["tinted"], "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (icon_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

    root = {"info": {"author": "xcode", "version": 1}}
    (OUT / "Contents.json").write_text(json.dumps(root, indent=2) + "\n")

    def color_set(name, light, dark):
        d = OUT / f"{name}.colorset"
        d.mkdir(exist_ok=True)

        def entry(hexv, appearance=None):
            h = hexv.lstrip("#")
            comps = {k: f"0x{h[i:i+2].upper()}" for k, i in (("red", 0), ("green", 2), ("blue", 4))}
            comps["alpha"] = "1.000"
            e = {"color": {"color-space": "srgb", "components": comps}, "idiom": "universal"}
            if appearance:
                e["appearances"] = [{"appearance": "luminosity", "value": appearance}]
            return e

        (d / "Contents.json").write_text(json.dumps(
            {"colors": [entry(light), entry(dark, "dark")], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    color_set("AccentColor", "#0A8FE0", "#2DB8FF")
    color_set("LaunchBackground", "#12130A", "#090A04")


if __name__ == "__main__":
    main()
