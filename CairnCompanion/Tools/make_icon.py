#!/usr/bin/env python3
"""Renders the Cairn Companion app icon (light, dark, tinted) into the asset catalog.

A stacked-stone cairn topped by a beacon that radiates signal arcs: the phone feeding GPS to the dongle.
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


def stone_layers(cx, cy, a, b, exp, light, dark, tilt=0.0):
    """Returns (rgba stone image, alpha mask) for a superellipse pebble with directional shading."""
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    x = xx - cx * SS
    y = yy - cy * SS
    if tilt:
        ct, st = math.cos(tilt), math.sin(tilt)
        x, y = x * ct + y * st, -x * st + y * ct
    f = (np.abs(x) / (a * SS)) ** exp + (np.abs(y) / (b * SS)) ** exp
    edge = 1.0 / (a * SS) * 1.4  # ~1.4px soft edge for anti-aliasing
    alpha = np.clip((1.0 - f) / (edge * 2.2) + 0.5, 0, 1)

    u = np.clip(x / (a * SS), -1, 1)
    v = np.clip(y / (b * SS), -1, 1)
    lit = 0.5 - 0.42 * v - 0.18 * u  # light from upper left
    lit = np.clip(lit, 0, 1)
    rim = np.clip(f, 0, 1) ** 3.0
    shade = np.clip(lit - 0.22 * rim, 0, 1)[..., None]
    col = hex_rgb(dark) * (1 - shade) + hex_rgb(light) * shade
    # soft specular on the upper-left shoulder
    hx, hy = -0.32, -0.55
    spec = np.exp(-(((u - hx) / 0.42) ** 2 + ((v - hy) / 0.22) ** 2))[..., None]
    col = col + spec * 26
    rgba = np.dstack([np.clip(col, 0, 255), alpha * 255]).astype(np.uint8)
    return Image.fromarray(rgba), Image.fromarray((alpha * 255).astype(np.uint8))


def shadow(mask, dy, blur, opacity):
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    black = Image.new("RGBA", (N, N), (0, 0, 0, 255))
    m = ImageChops.offset(mask, 0, int(dy * SS)).filter(ImageFilter.GaussianBlur(blur * SS))
    m = m.point(lambda p: int(p * opacity))
    sh.paste(black, (0, 0), m)
    return sh


def arc_layer(cx, cy, radii, width, start, end, colors, alphas):
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for r, col, al in zip(radii, colors, alphas):
        R = r * SS  # centerline radius; PIL strokes arcs inward from the box edge
        Ro = R + width * SS / 2
        box = [cx * SS - Ro, cy * SS - Ro, cx * SS + Ro, cy * SS + Ro]
        c = tuple(int(v) for v in hex_rgb(col)) + (int(255 * al),)
        d.arc(box, start, end, fill=c, width=int(width * SS))
        for ang in (start, end):  # round caps
            px = cx * SS + R * math.cos(math.radians(ang))
            py = cy * SS + R * math.sin(math.radians(ang))
            rr = width * SS / 2
            d.ellipse([px - rr, py - rr, px + rr, py + rr], fill=c)
    return layer


def glow(layer, blur, gain):
    g = layer.filter(ImageFilter.GaussianBlur(blur * SS))
    r, gch, b, a = g.split()
    a = a.point(lambda p: min(255, int(p * gain)))
    return Image.merge("RGBA", (r, gch, b, a))


def render(variant):
    if variant == "light":
        bg = background("#17566A", "#0A2531", "#041118")
        accent_a, accent_b = "#5CF2D6", "#2FB7F5"
        stones = [("#D8CFBC", "#8A806C"), ("#E6DECD", "#9C927E"), ("#F7F2E7", "#B9B09B")]
        shadow_op = 0.55
    elif variant == "dark":
        bg = background("#0E3340", "#06161E", "#020A0F")
        accent_a, accent_b = "#4AE6CA", "#27A8E6"
        stones = [("#C2BAA8", "#6F6656"), ("#CFC7B5", "#7E7566"), ("#E4DDCE", "#9A917F")]
        shadow_op = 0.65
    else:  # tinted: system recolors luminance, so use clean grayscale on black
        bg = background("#2A2A2A", "#101010", "#000000")
        accent_a = accent_b = "#FFFFFF"
        stones = [("#B8B8B8", "#5E5E5E"), ("#CFCFCF", "#707070"), ("#F2F2F2", "#9A9A9A")]
        shadow_op = 0.6

    img = bg
    lift = -6  # nudge composition so it's optically centered

    # (cx, cy, a, b, exponent, tilt)
    specs = [
        (506, 790 + lift, 300, 98, 2.7, math.radians(-1.0)),
        (528, 628 + lift, 222, 82, 2.6, math.radians(1.6)),
        (500, 490 + lift, 150, 68, 2.5, math.radians(-2.4)),
    ]
    for (cx, cy, a, b, e, tilt), (lt, dk) in zip(specs, stones):
        stone, mask = stone_layers(cx, cy, a, b, e, lt, dk, tilt)
        img = Image.alpha_composite(img, shadow(mask, 14, 22, shadow_op))
        img = Image.alpha_composite(img, stone)

    # beacon + arcs
    bx, by = 500, 352 + lift
    arcs = arc_layer(
        bx, by, [96, 174, 252], 26, 222, 318,
        [accent_a, accent_a, accent_b], [1.0, 0.82, 0.58],
    )
    dot = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dot)
    r = 34 * SS
    dd.ellipse([bx * SS - r, by * SS - r, bx * SS + r, by * SS + r], fill=tuple(int(v) for v in hex_rgb(accent_a)) + (255,))
    beacon = Image.alpha_composite(arcs, dot)
    img = Image.alpha_composite(img, glow(beacon, 26, 1.8))
    img = Image.alpha_composite(img, glow(beacon, 8, 1.0))
    img = Image.alpha_composite(img, beacon)

    out = img.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    return out


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
