#!/usr/bin/env python3
"""Makes the desktop icon (build/icon.png, 512x512) from the iPad icon: same cyan-to-purple
gradient with white wind swooshes, with rounded corners and a little space around it.
Also writes a small copy for the app window (src/renderer/icon.png).
Run: python3 build/make_icon.py   (needs Pillow: pip install pillow)"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "Gale", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
OUT = os.path.join(HERE, "icon.png")
SMALL = os.path.join(HERE, "..", "src", "renderer", "icon.png")

S = 512
PAD = 24
BIG = 4  # draw the mask 4x bigger, then shrink it, for smooth corners


def main():
    art = Image.open(SRC).convert("RGBA").resize((S - 2 * PAD, S - 2 * PAD), Image.LANCZOS)
    mask = Image.new("L", ((S - 2 * PAD) * BIG, (S - 2 * PAD) * BIG), 0)
    r = int((S - 2 * PAD) * BIG * 0.225)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, mask.width - 1, mask.height - 1), radius=r, fill=255)
    mask = mask.resize(art.size, Image.LANCZOS)
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(art, (PAD, PAD), mask)
    icon.save(OUT)
    icon.resize((128, 128), Image.LANCZOS).save(SMALL)
    print("wrote", OUT, "and", SMALL)


if __name__ == "__main__":
    main()
