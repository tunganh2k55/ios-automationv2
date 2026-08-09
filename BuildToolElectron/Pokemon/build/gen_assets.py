# -*- coding: utf-8 -*-
"""Sinh asset trang trí cho PokémonTool: pokéball bóng 3D + mascot Pikachu (phong cách phẳng).
Xuất PNG có alpha vào renderer/assets/. Vẽ supersample cho mượt."""
import os
from PIL import Image, ImageDraw, ImageFilter

SS = 4
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "renderer", "assets")
os.makedirs(OUT, exist_ok=True)

RED = (238, 21, 21)
RED_HI = (255, 90, 82)
RED_LO = (150, 8, 8)
WHITE = (248, 248, 248)
GREY = (205, 208, 214)
BLACK = (24, 24, 28)


def _canvas(size):
    return Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))


def radial(size, center, r, c_in, c_out):
    """Trả layer RGBA gradient tròn."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    cx, cy = center
    for y in range(size):
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / r
            if d > 1.15:
                continue
            t = min(1.0, max(0.0, d))
            col = tuple(int(c_in[i] + (c_out[i] - c_in[i]) * t) for i in range(3))
            a = 255 if d <= 1.0 else int(255 * (1.15 - d) / 0.15)
            px[x, y] = col + (a,)
    return img


def pokeball_3d(size=256):
    S = size * SS
    img = _canvas(size)
    d = ImageDraw.Draw(img)
    cx = cy = S // 2
    r = int(S * 0.46)
    box = [cx - r, cy - r, cx + r, cy + r]

    # nửa dưới trắng (gradient nhẹ)
    bottom = radial(S, (cx, int(cy + r * 0.35)), int(r * 1.5), WHITE, GREY)
    d.ellipse(box, fill=WHITE)
    img.alpha_composite(bottom)
    # nửa trên đỏ có khối
    top = radial(S, (int(cx - r * 0.3), int(cy - r * 0.45)), int(r * 1.6), RED_HI, RED_LO)
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    md.pieslice(box, 180, 360, fill=255)
    img.paste(top, (0, 0), Image.composite(mask, Image.new("L", (S, S), 0), mask))
    # cắt về hình tròn
    circ = Image.new("L", (S, S), 0)
    ImageDraw.Draw(circ).ellipse(box, fill=255)
    img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", (S, S), 0), circ))

    d = ImageDraw.Draw(img)
    band = int(S * 0.05)
    d.rectangle([cx - r, cy - band, cx + r, cy + band], fill=BLACK)
    d.ellipse(box, outline=BLACK, width=int(S * 0.035))
    # nút giữa
    for rr, col in [(0.20, BLACK), (0.145, WHITE), (0.075, (235, 235, 235))]:
        rp = int(r * rr)
        d.ellipse([cx - rp, cy - rp, cx + rp, cy + rp], fill=col)
    d.ellipse([cx - int(r * 0.145), cy - int(r * 0.145), cx + int(r * 0.145), cy + int(r * 0.145)],
              outline=BLACK, width=int(S * 0.012))
    # highlight bóng
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    hd.ellipse([int(cx - r * 0.62), int(cy - r * 0.7), int(cx - r * 0.05), int(cy - r * 0.2)],
               fill=(255, 255, 255, 70))
    hl = hl.filter(ImageFilter.GaussianBlur(S // 60))
    img.alpha_composite(hl)

    return img.resize((size, size), Image.LANCZOS)


def pikachu(size=256):
    """Mascot Pikachu phẳng, mặt trước — vẽ tối giản nhưng nhận ra được."""
    S = size * SS
    img = _canvas(size)
    d = ImageDraw.Draw(img)
    Y = (255, 203, 8)      # vàng
    Y_SH = (240, 170, 0)
    cx = S // 2
    # tai
    d.polygon([(cx - int(S*0.28), int(S*0.30)), (cx - int(S*0.42), int(S*0.02)), (cx - int(S*0.12), int(S*0.20))], fill=Y)
    d.polygon([(cx + int(S*0.28), int(S*0.30)), (cx + int(S*0.42), int(S*0.02)), (cx + int(S*0.12), int(S*0.20))], fill=Y)
    d.polygon([(cx - int(S*0.42), int(S*0.02)), (cx - int(S*0.33), int(S*0.02)), (cx - int(S*0.22), int(S*0.17))], fill=BLACK)
    d.polygon([(cx + int(S*0.42), int(S*0.02)), (cx + int(S*0.33), int(S*0.02)), (cx + int(S*0.22), int(S*0.17))], fill=BLACK)
    # đầu
    hr = int(S * 0.34)
    d.ellipse([cx - hr, int(S*0.28), cx + hr, int(S*0.28) + 2*hr], fill=Y)
    # má đỏ
    cr = int(S * 0.085)
    for sx in (-1, 1):
        ccx = cx + sx * int(S * 0.24)
        ccy = int(S * 0.66)
        d.ellipse([ccx - cr, ccy - cr, ccx + cr, ccy + cr], fill=(240, 60, 40))
    # mắt
    er = int(S * 0.055)
    for sx in (-1, 1):
        ex = cx + sx * int(S * 0.15)
        ey = int(S * 0.55)
        d.ellipse([ex - er, ey - er, ex + er, ey + er], fill=BLACK)
        hp = int(er * 0.4)
        d.ellipse([ex - hp, ey - er + hp//2, ex + hp, ey - er + hp*3], fill=WHITE)
    # mũi + miệng
    d.ellipse([cx - int(S*0.012), int(S*0.62), cx + int(S*0.012), int(S*0.645)], fill=BLACK)
    d.arc([cx - int(S*0.05), int(S*0.63), cx, int(S*0.70)], 300, 60, fill=BLACK, width=int(S*0.008))
    d.arc([cx, int(S*0.63), cx + int(S*0.05), int(S*0.70)], 120, 240, fill=BLACK, width=int(S*0.008))
    return img.resize((size, size), Image.LANCZOS)


def main():
    # Chỉ sinh pokéball bóng 3D (yếu tố thiết kế chung). KHÔNG tái tạo nhân vật có bản quyền.
    pokeball_3d(256).save(os.path.join(OUT, "pokeball3d.png"))
    print("wrote assets ->", OUT)


if __name__ == "__main__":
    main()
