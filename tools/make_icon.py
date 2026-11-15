#!/usr/bin/env python3
"""Draws Gale's app icon (1024x1024 PNG): a gust of wind that turns into a pencil line.
Run: python3 tools/make_icon.py   (needs Pillow: pip install pillow)"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "Gale", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    img = Image.new("RGB", (S, S))
    top, bottom = (34, 211, 238), (124, 58, 237)   # cyan to purple
    px = img.load()
    for y in range(S):
        for x in range(S):
            t = min(1, max(0, (x * 0.35 + y * 0.65) / S))
            px[x, y] = lerp(top, bottom, t)

    # Soft glow
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((180, 120, 900, 840), fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    img = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), img, glow)

    # Three wind swooshes drawn as thick smooth curves with round ends.
    layer = Image.new("RGBA", (S * 2, S * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def swoosh(y0, length, curl, width, alpha):
        pts = []
        for i in range(161):
            t = i / 160
            x = 150 + t * length
            y = y0 + math.sin(t * math.pi * 1.2) * -40
            pts.append((x, y))
        # curl at the end
        cx, cy = pts[-1][0], pts[-1][1] + curl
        for i in range(1, 100):
            a = -math.pi / 2 + i / 100 * math.pi * 1.5
            r = curl * (1 - i / 160)
            pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
        pts = [(x * 2, y * 2) for x, y in pts]
        w = width * 2
        for i, (x, y) in enumerate(pts):
            k = 1 - max(0, (i - len(pts) * 0.7) / (len(pts) * 0.3)) * 0.6
            r = w / 2 * k
            d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, alpha))

    swoosh(330, 560, 90, 64, 255)
    swoosh(520, 470, 70, 52, 235)
    swoosh(690, 330, 52, 40, 210)
    layer = layer.resize((S, S), Image.LANCZOS)

    # Pencil tip at the start of the top swoosh
    tip = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    t = ImageDraw.Draw(tip)
    t.polygon([(70, 330), (165, 290), (165, 370)], fill=(255, 214, 102, 255))
    t.polygon([(70, 330), (102, 316), (102, 344)], fill=(40, 30, 60, 255))

    img = img.convert("RGBA")
    img.alpha_composite(tip)
    img.alpha_composite(layer)
    img.convert("RGB").save(OUT)
    print("Saved", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
