# -*- coding: utf-8 -*-
"""Sinh icon Pokéball (đỏ) cho app: build/icon.png (256) + build/icon.ico đa kích thước.
Vẽ vector-ish bằng PIL với supersampling để viền mượt."""
import os
from PIL import Image, ImageDraw

RED = (238, 21, 21, 255)      # đỏ pokéball
WHITE = (245, 245, 245, 255)
BLACK = (26, 26, 26, 255)
SS = 8                         # supersample


def draw_pokeball(size):
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = int(S * 0.03)
    box = [pad, pad, S - pad, S - pad]
    cx = cy = S // 2
    r = (S - 2 * pad) // 2

    # thân: nửa trên đỏ, nửa dưới trắng
    d.ellipse(box, fill=WHITE)
    d.pieslice(box, 180, 360, fill=RED)          # nửa trên
    # viền ngoài đen
    ring = max(2, int(S * 0.035))
    d.ellipse(box, outline=BLACK, width=ring)
    # dải ngang đen
    band = int(S * 0.055)
    d.rectangle([pad, cy - band, S - pad, cy + band], fill=BLACK)

    # nút giữa
    r_out = int(r * 0.26)
    r_mid = int(r * 0.20)
    r_in = int(r * 0.12)
    d.ellipse([cx - r_out, cy - r_out, cx + r_out, cy + r_out], fill=BLACK)
    d.ellipse([cx - r_mid, cy - r_mid, cx + r_mid, cy + r_mid], fill=WHITE)
    d.ellipse([cx - r_in, cy - r_in, cx + r_in, cy + r_in], fill=BLACK, outline=WHITE, width=max(2, int(S*0.012)))

    return img.resize((size, size), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    png = draw_pokeball(256)
    png.save(os.path.join(here, "icon.png"))
    sizes = [16, 24, 32, 48, 64, 128, 256]
    imgs = [draw_pokeball(s) for s in sizes]
    imgs[-1].save(os.path.join(here, "icon.ico"), sizes=[(s, s) for s in sizes],
                  append_images=imgs[:-1])
    print("wrote icon.png + icon.ico ->", here)


if __name__ == "__main__":
    main()
