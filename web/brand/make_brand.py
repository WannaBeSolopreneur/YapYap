"""YapYap brand art: the pixel speech-bubble mark and every icon / card made from it.

The mark is drawn on a 16x16 grid in the TikTok show's palette (office-show / pixel-stage clip.yaml): a speech bubble with
two lines of text and the app's yellow read-along highlight running across it, past both edges.

    python3 web/brand/make_brand.py            # writes site/ icons, Resources/AppIcon-1024.png + AppIcon.icns, docs/icon.png
Needs Pillow; AppIcon.icns needs macOS iconutil. Hero art and cast sprites live in site/art/ (see web/brand/README.md)."""
import os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HERE = os.path.dirname(os.path.abspath(__file__))

INK, NAVY, SLATE, POWDER, PALE, CREAM, YELLOW, SHADE = "#0f1828", "#1b2a41", "#3e5c84", "#a7c7e7", "#dcebf7", "#f4f1ea", "#ffd166", "#5b7db1"

def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) + (255,)

def mark_grid():
    """16x16 palette grid (None = transparent)."""
    g = [[None] * 16 for _ in range(16)]
    fill = set()
    for y in range(2, 12):
        for x in range(2, 14):
            if (x, y) in {(2, 2), (13, 2), (2, 11), (13, 11)}: continue   # rounded corners
            fill.add((x, y))
    tail = {(4, 12), (5, 12), (4, 13)}
    bar = {(x, y) for x in range(1, 15) for y in (5, 6)}   # the highlight, one pixel past the bubble on each side
    shape = fill | tail | bar
    for x, y in shape: g[y][x] = POWDER
    for x, y in fill:                               # top light, bottom shade
        if y == 2: g[y][x] = PALE
        if y == 11: g[y][x] = SHADE
    for x, y in tail: g[y][x] = SHADE
    for x in range(4, 12): g[3][x] = SLATE          # text lines
    for x in range(4, 12): g[8][x] = SLATE
    for x in range(4, 9): g[10][x] = SLATE
    for x, y in bar: g[y][x] = YELLOW
    for y in range(16):                             # 1 px ink outline around the whole shape (4-neighbour)
        for x in range(16):
            if (x, y) in shape: continue
            if any((x + dx, y + dy) in shape for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))): g[y][x] = INK
    return g

def mark_image(scale=1, pad=0):
    g = mark_grid()
    im = Image.new("RGBA", (16 + 2 * pad, 16 + 2 * pad), (0, 0, 0, 0))
    for y in range(16):
        for x in range(16):
            if g[y][x]: im.putpixel((x + pad, y + pad), hexrgb(g[y][x]))
    return im.resize((im.width * scale, im.height * scale), Image.NEAREST)

def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset, inset, size - inset - 1, size - inset - 1], radius=radius, fill=255)
    return m

def app_icon(size=1024):
    """macOS icon: navy night tile on Apple's 824/1024 grid, a few stars, the mark at 40 px per pixel."""
    u = size // 1024
    S = 1024
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tile = Image.new("RGBA", (S, S), hexrgb(NAVY))
    d = ImageDraw.Draw(tile)
    for x, y, s in ((170, 170, 22), (812, 196, 22), (176, 806, 14), (840, 760, 14), (700, 142, 14)):   # stars
        d.rectangle([x, y, x + s - 1, y + s - 1], fill=hexrgb(CREAM))
    k = 44
    m = mark_image(k)
    ox, oy = (S - m.width) // 2, (S - m.height) // 2 + 22
    shadow = Image.new("RGBA", m.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", m.size, hexrgb("#121d30")), (0, 0), m)
    tile.alpha_composite(shadow, (ox, oy + k))
    tile.alpha_composite(m, (ox, oy))
    im.paste(tile, (0, 0), squircle_mask(S, 100, 185))
    return im if size == S else im.resize((size, size), Image.LANCZOS)

def font(name, px): return ImageFont.truetype(os.path.join(HERE, "fonts", name), px)

def og_card():
    """1200x630 share card: the show's night sky, mark + YAPYAP wordmark, the tagline, the cast, yapyap.cc."""
    W, H = 1200, 630
    im = Image.new("RGBA", (W, H), hexrgb(NAVY))
    d = ImageDraw.Draw(im)
    for y in range(0, H, 60): d.rectangle([0, y + 54, W, y + 57], fill=hexrgb("#16233a"))
    m = mark_image(8)
    title = font("PressStart2P.ttf", 88)
    tw = d.textlength("YAPYAP", font=title)
    x0 = (W - (m.width + 36 + tw)) // 2
    im.alpha_composite(m, (int(x0), 70))
    for dx, dy in ((6, 6),): d.text((x0 + m.width + 36 + dx, 96 + dy), "YAPYAP", font=title, fill=hexrgb(INK))
    d.text((x0 + m.width + 36, 96), "YAPYAP", font=title, fill=hexrgb(POWDER))
    sub = font("PressStart2P.ttf", 26)
    t = "ON-DEVICE AI PRODUCTIVITY TOOLS"
    d.text(((W - d.textlength(t, font=sub)) // 2 + 3, 247 + 3), t, font=sub, fill=hexrgb(INK))
    d.text(((W - d.textlength(t, font=sub)) // 2, 247), t, font=sub, fill=hexrgb(CREAM))
    cast = ["bob", "walt", "gail", "jessy", "zoe", "lenny"]
    pose = {"bob": "shock", "walt": "idle0", "gail": "idle0", "jessy": "phone0", "zoe": "shock", "lenny": "idle0"}
    k = 5; gap = 34; cw = 24 * k
    cx0 = (W - (len(cast) * cw + (len(cast) - 1) * gap)) // 2
    for i, n in enumerate(cast):
        s = Image.open(os.path.join(ROOT, "site", "art", "cast", f"{n}-{pose[n]}.png")).convert("RGBA")
        im.alpha_composite(s.resize((s.width * k, s.height * k), Image.NEAREST), (cx0 + i * (cw + gap), 300))
    d.rectangle([cx0 - 30, 300 + 32 * k - 2, W - cx0 + 30, 300 + 32 * k + 2], fill=hexrgb("#0b1220"))
    url = font("PressStart2P.ttf", 40)
    t = "YAPYAP.CC"
    d.text(((W - d.textlength(t, font=url)) // 2 + 4, 520 + 4), t, font=url, fill=hexrgb(INK))
    d.text(((W - d.textlength(t, font=url)) // 2, 520), t, font=url, fill=hexrgb(YELLOW))
    return im.convert("RGB")

def main():
    site = os.path.join(ROOT, "site")
    mark_image(1).save(os.path.join(site, "mark.png"))
    mark_image(2).save(os.path.join(site, "favicon-32.png"))
    with open(os.path.join(site, "favicon.svg"), "w") as f:
        g = mark_grid()
        rects = "".join(f'<rect x="{x}" y="{y}" width="1" height="1" fill="{g[y][x]}"/>' for y in range(16) for x in range(16) if g[y][x])
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">{rects}</svg>\n')
    icon = app_icon(1024)
    icon.resize((256, 256), Image.LANCZOS).save(os.path.join(site, "icon.png"))
    # Touch icon: iOS rounds the corners itself, so fill the square.
    touch = Image.new("RGBA", (180, 180), hexrgb(NAVY))
    touch.alpha_composite(mark_image(9), (18, 22))
    touch.convert("RGB").save(os.path.join(site, "apple-touch-icon.png"))
    og_card().save(os.path.join(site, "og.png"))
    og_card().resize((1280, 672), Image.LANCZOS).crop((0, 16, 1280, 656)).save(os.path.join(ROOT, "docs", "social-preview.png"))
    icon.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "docs", "icon.png"))
    icon.save(os.path.join(ROOT, "Resources", "AppIcon-1024.png"))
    if shutil.which("iconutil"):
        tmp = tempfile.mkdtemp(); iset = os.path.join(tmp, "AppIcon.iconset"); os.mkdir(iset)
        for s in (16, 32, 128, 256, 512):
            icon.resize((s, s), Image.LANCZOS).save(os.path.join(iset, f"icon_{s}x{s}.png"))
            icon.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iset, f"icon_{s}x{s}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iset, "-o", os.path.join(ROOT, "Resources", "AppIcon.icns")], check=True)
    else:
        print("iconutil not found: Resources/AppIcon.icns not rebuilt", file=sys.stderr)
    print("brand assets written")

if __name__ == "__main__":
    main()
