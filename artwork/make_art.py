"""Maakt de Steam-bibliotheekafbeeldingen voor KeySight uit de promo-afbeelding van Phil.

Gebruik:  python make_art.py <bronafbeelding.png>
Uitvoer (in deze map):
  capsule.png  600x900   staand  (Steam: <appid>p.png)
  wide.png     920x430   liggend (Steam: <appid>.png)
  hero.png     1920x620  banner zonder tekst (Steam: <appid>_hero.png)
  logo.png     1600x480  woordmerk, doorzichtig (Steam: <appid>_logo.png)
  icon.png     256x256   icoon
De bron wordt niet aangepast.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_B = os.path.join(HERE, "..", "step2-leren", "fonts", "AtkinsonHyperlegible-Bold.ttf")
FONT_R = os.path.join(HERE, "..", "step2-leren", "fonts", "AtkinsonHyperlegible-Regular.ttf")
CYAN = (64, 214, 255)
VIOLET = (190, 92, 255)
WHITE = (246, 248, 252)
DARK = (10, 10, 22)


def cover(img, w, h, box=None):
    """Snijdt `box` (of het hele beeld) bij tot verhouding w:h zonder vervormen, schaalt naar w x h."""
    if box:
        img = img.crop(box)
    sw, sh = img.size
    target = w / h
    if sw / sh > target:
        nw = int(sh * target)
        x0 = (sw - nw) // 2
        img = img.crop((x0, 0, x0 + nw, sh))
    else:
        nh = int(sw / target)
        y0 = (sh - nh) // 2
        img = img.crop((0, y0, sw, y0 + nh))
    return img.resize((w, h), Image.LANCZOS)


def fade(img, side, length, strength=1.0, color=DARK, power=1.6):
    """Verloop naar donker aan één kant (left/right/top/bottom)."""
    w, h = img.size
    mask = Image.new("L", (w, h), 0)
    px = mask.load()
    for i in range(length):
        a = int(255 * strength * (1 - i / length) ** power)
        if side in ("left", "right"):
            x = i if side == "left" else w - 1 - i
            for y in range(h):
                px[x, y] = a
        else:
            y = i if side == "top" else h - 1 - i
            for x in range(w):
                px[x, y] = a
    solid = Image.new("RGB", (w, h), color)
    return Image.composite(solid, img.convert("RGB"), mask)


def wordmark(height, tagline=True):
    """"KeySight" in Atkinson Hyperlegible Bold: "Key" wit, "Sight" cyaan naar violet, met gloed."""
    fb = ImageFont.truetype(FONT_B, height)
    fr = ImageFont.truetype(FONT_R, int(height * 0.20))
    key_w = fb.getlength("Key")
    sight_w = fb.getlength("Sight")
    tw = int(key_w + sight_w)
    tag = "LEARN PIANO IN MIXED REALITY"
    spacing = int(height * 0.06)
    tag_w = int(sum(fr.getlength(c) for c in tag) + spacing * (len(tag) - 1))
    W = max(tw, tag_w) + height // 2
    H = int(height * (1.75 if tagline else 1.3))
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    x0 = (W - tw) // 2
    y0 = int(height * 0.05)
    # Tekstmasker voor "Sight" om het verloop in te kleuren.
    text = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(text)
    d.text((x0, y0), "Key", font=fb, fill=WHITE + (255,))
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).text((x0 + key_w, y0), "Sight", font=fb, fill=255)
    grad = Image.new("RGBA", (W, H))
    gp = grad.load()
    gx0, gx1 = x0 + key_w, x0 + key_w + sight_w
    for x in range(W):
        t = min(1.0, max(0.0, (x - gx0) / max(1.0, gx1 - gx0)))
        c = tuple(int(CYAN[i] * (1 - t) + VIOLET[i] * t) for i in range(3)) + (255,)
        for y in range(H):
            gp[x, y] = c
    text = Image.alpha_composite(text, Image.composite(grad, Image.new("RGBA", (W, H), (0, 0, 0, 0)), m))
    d = ImageDraw.Draw(text)
    if tagline:
        ty = int(y0 + height * 1.22)
        tx = (W - tag_w) // 2
        for c in tag:
            d.text((tx, ty), c, font=fr, fill=(225, 230, 245, 235))
            tx += fr.getlength(c) + spacing
    # Zachte gloed + donkere schaduw voor contrast op elke achtergrond.
    alpha = text.split()[3]
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.putalpha(alpha.filter(ImageFilter.GaussianBlur(height * 0.06)).point(lambda a: int(a * 0.85)))
    glow = Image.new("RGBA", (W, H), (120, 140, 255, 0))
    glow.putalpha(alpha.filter(ImageFilter.GaussianBlur(height * 0.14)).point(lambda a: int(a * 0.45)))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, shadow)
    img = Image.alpha_composite(img, text)
    return img.crop(img.getbbox())


def paste_center(base, overlay, cx, cy, max_w):
    if overlay.width > max_w:
        overlay = overlay.resize((max_w, int(overlay.height * max_w / overlay.width)), Image.LANCZOS)
    base = base.convert("RGBA")
    base.alpha_composite(overlay, (int(cx - overlay.width / 2), int(cy - overlay.height / 2)))
    return base.convert("RGB")


def main(src_path):
    src = Image.open(src_path).convert("RGB")
    S = src.width / 1254.0   # alle uitsnedes zijn gemeten op de 1254x1254-bron
    box = lambda x0, y0, x1, y1: tuple(int(v * S) for v in (x0, y0, x1, y1))

    # Staand: midden van de afbeelding (met het eigen logo erin), onderste rij iconen
    # weggewerkt met een verloop.
    cap = cover(src, 600, 900, box(209, 0, 1045, 1254))
    cap = fade(cap, "bottom", 330, 1.0, power=0.45)
    ImageDraw.Draw(cap).rectangle((0, 772, 600, 900), fill=DARK)
    cap.save(os.path.join(HERE, "capsule.png"))

    # Liggend: handen en vallende noten, links donker met ons woordmerk.
    wide = cover(src, 920, 430, box(250, 430, 1254, 900))
    wide = fade(wide, "left", 560, 0.97, power=0.9)
    wide = paste_center(wide, wordmark(150), 255, 205, 440)
    wide.save(os.path.join(HERE, "wide.png"))

    # Hero: banner zonder tekst (Steam zet het logo er zelf overheen).
    hero = cover(src, 1920, 620, box(0, 470, 1254, 875))
    hero = fade(hero, "bottom", 120, 0.6)
    hero.save(os.path.join(HERE, "hero.png"))

    # Logo: alleen het woordmerk, doorzichtig.
    logo = wordmark(300)
    canvas = Image.new("RGBA", (1600, 480), (0, 0, 0, 0))
    lw = min(1500, logo.width)
    logo = logo.resize((lw, int(logo.height * lw / logo.width)), Image.LANCZOS)
    if logo.height > 460:
        logo = logo.resize((int(logo.width * 460 / logo.height), 460), Image.LANCZOS)
    canvas.alpha_composite(logo, ((1600 - logo.width) // 2, (480 - logo.height) // 2))
    canvas.save(os.path.join(HERE, "logo.png"))

    # Icoon: het embleem (klavier in een headset) uit de afbeelding.
    # Embleem op een donkere achtergrond met een zachte violette gloed.
    emblem = src.crop(box(415, 45, 830, 205))
    icon = Image.new("RGB", (256, 256), DARK)
    m = Image.new("L", (256, 256), 0)
    ImageDraw.Draw(m).ellipse((18, 18, 238, 238), fill=150)
    icon = Image.composite(Image.new("RGB", (256, 256), (40, 30, 80)), icon, m.filter(ImageFilter.GaussianBlur(40)))
    ew = 236
    emblem = emblem.resize((ew, int(emblem.height * ew / emblem.width)), Image.LANCZOS)
    # Alleen de lichte delen (het embleem) overnemen, niet de donkere kamer erachter.
    lum = emblem.convert("L").point(lambda v: max(0, min(255, (v - 45) * 3)))
    feather = Image.new("L", emblem.size, 0)
    ImageDraw.Draw(feather).rectangle((6, 6, emblem.width - 7, emblem.height - 7), fill=255)
    feather = feather.filter(ImageFilter.GaussianBlur(5))
    from PIL import ImageChops
    mask = ImageChops.multiply(lum, feather)
    icon.paste(emblem, ((256 - ew) // 2, (256 - emblem.height) // 2), mask)
    icon.save(os.path.join(HERE, "icon.png"))
    print("klaar:", ", ".join(f for f in sorted(os.listdir(HERE)) if f.endswith(".png")))


if __name__ == "__main__":
    main(sys.argv[1])
