#!/usr/bin/env python3
"""Renders the Cairn Companion app icon (light, dark, tinted) into the asset catalog.

A navigation arrowhead inside an open "C" ring with a beacon in the gap: the phone feeding GPS to the dongle.
Requires Pillow and numpy:  python3 Tools/make_icon.py
"""
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersample factor
N = SIZE * SS

OUT = Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets"


def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)


def background(top_glow, mid, edge):
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) / N
    d = np.sqrt((xx - 0.5) ** 2 + ((yy - 0.36) * 1.05) ** 2)
    t = np.clip(d / 0.78, 0, 1)[..., None]
    t = t ** 1.15
    c = hex_rgb(top_glow) * (1 - t) + hex_rgb(mid) * t
    t2 = np.clip((yy - 0.55) / 0.45, 0, 1)[..., None] ** 1.4
    c = c * (1 - t2) + hex_rgb(edge) * t2
    return Image.fromarray(np.clip(c, 0, 255).astype(np.uint8)).convert("RGBA")


def lin_gradient(c0, c1, angle_deg=45):
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) / N
    a = math.radians(angle_deg)
    t = np.clip(((xx - 0.5) * math.cos(a) + (yy - 0.5) * math.sin(a)) + 0.5, 0, 1)[..., None]
    c = hex_rgb(c0) * (1 - t) + hex_rgb(c1) * t
    return Image.fromarray(np.clip(c, 0, 255).astype(np.uint8)).convert("RGBA")


def painted(gradient, mask):
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.paste(gradient, (0, 0), mask)
    return out


def ring_mask(cx, cy, radius, width, start, end):
    """Open ring with round caps; PIL angles run clockwise from 3 o'clock."""
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    Ro = (radius + width / 2) * SS
    d.arc([cx * SS - Ro, cy * SS - Ro, cx * SS + Ro, cy * SS + Ro], start, end, fill=255, width=int(width * SS))
    for ang in (start, end):
        px = cx * SS + radius * SS * math.cos(math.radians(ang))
        py = cy * SS + radius * SS * math.sin(math.radians(ang))
        r = width * SS / 2
        d.ellipse([px - r, py - r, px + r, py + r], fill=255)
    return m


def arrow_masks(cx, cy, scale, tilt_deg):
    """Navigation arrowhead as (whole, left facet, right facet) masks with softly rounded corners."""
    t = math.radians(tilt_deg)

    def pt(x, y):
        xr, yr = x * math.cos(t) - y * math.sin(t), x * math.sin(t) + y * math.cos(t)
        return (cx * SS + xr * scale * SS, cy * SS + yr * scale * SS)

    tip, br, notch, bl = pt(0, -1), pt(0.72, 0.92), pt(0, 0.46), pt(-0.72, 0.92)

    def poly(points):
        m = Image.new("L", (N, N), 0)
        ImageDraw.Draw(m).polygon(points, fill=255)
        return m

    def round_off(m, radius=9):
        return m.filter(ImageFilter.GaussianBlur(radius * SS)).point(lambda p: 255 if p > 128 else 0).filter(
            ImageFilter.GaussianBlur(0.8 * SS))

    whole = round_off(poly([tip, br, notch, bl]))
    left = ImageChops.multiply(whole, poly([tip, bl, notch]))
    right = ImageChops.multiply(whole, poly([tip, br, notch]))
    return whole, left, right


def shadow(mask, dy, blur, opacity):
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    m = ImageChops.offset(mask, 0, int(dy * SS)).filter(ImageFilter.GaussianBlur(blur * SS))
    m = m.point(lambda p: int(p * opacity))
    sh.paste(Image.new("RGBA", (N, N), (0, 0, 0, 255)), (0, 0), m)
    return sh


def glow(layer, blur, gain):
    g = layer.filter(ImageFilter.GaussianBlur(blur * SS))
    r, gch, b, a = g.split()
    a = a.point(lambda p: min(255, int(p * gain)))
    return Image.merge("RGBA", (r, gch, b, a))


def render(variant):
    if variant == "light":
        bg = background("#17566A", "#0A2531", "#041118")
        ring = ("#5CF2D6", "#2F8DF5")
        facets = ("#FFFFFF", "#CFE9F2")
        beacon = "#5CF2D6"
    elif variant == "dark":
        bg = background("#0E3340", "#06161E", "#020A0F")
        ring = ("#4AE6CA", "#2778E0")
        facets = ("#F2F7F9", "#B9D3DD")
        beacon = "#4AE6CA"
    else:  # tinted: the system recolors luminance, so use clean grayscale on black
        bg = background("#2A2A2A", "#101010", "#000000")
        ring = ("#FFFFFF", "#9A9A9A")
        facets = ("#FFFFFF", "#CFCFCF")
        beacon = "#FFFFFF"

    img = bg
    cx = cy = 512
    radius, width = 322, 96

    ring_m = ring_mask(cx, cy, radius, width, 38, 322)
    ring_img = painted(lin_gradient(*ring, angle_deg=60), ring_m)
    img = Image.alpha_composite(img, shadow(ring_m, 12, 20, 0.5))
    img = Image.alpha_composite(img, glow(ring_img, 30, 1.2))
    img = Image.alpha_composite(img, ring_img)

    # beacon sits in the ring's gap: the dongle the phone is feeding
    bx = cx + radius
    dot_m = Image.new("L", (N, N), 0)
    r = 50 * SS
    ImageDraw.Draw(dot_m).ellipse([bx * SS - r, cy * SS - r, bx * SS + r, cy * SS + r], fill=255)
    dot = painted(Image.new("RGBA", (N, N), tuple(int(v) for v in hex_rgb(beacon)) + (255,)), dot_m)
    img = Image.alpha_composite(img, glow(dot, 28, 2.2))
    img = Image.alpha_composite(img, dot)

    whole, left, right = arrow_masks(cx - 6, cy + 24, 215, 14)
    img = Image.alpha_composite(img, shadow(whole, 16, 24, 0.55))
    img = Image.alpha_composite(img, painted(Image.new("RGBA", (N, N), tuple(int(v) for v in hex_rgb(facets[1])) + (255,)), left))
    img = Image.alpha_composite(img, painted(Image.new("RGBA", (N, N), tuple(int(v) for v in hex_rgb(facets[0])) + (255,)), right))

    return img.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


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

    color_set("AccentColor", "#0FB59B", "#4AE6CA")
    color_set("LaunchBackground", "#0A2531", "#06161E")


if __name__ == "__main__":
    main()
