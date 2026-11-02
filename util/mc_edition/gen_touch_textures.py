#!/usr/bin/env python3
"""
Generates the Minecraft-Pocket-Edition-style touchscreen textures used by the
MC Edition touch layout.

Everything is drawn procedurally (no ripped Minecraft assets) so the repo stays
license-clean, and re-running this script regenerates every file.

    python3 util/mc_edition/gen_touch_textures.py

Output: textures/base/pack/*.png  (engine touch buttons + crosshair)
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "textures", "base", "pack")
SS = 4  # supersampling factor
SIZE = 128  # final pixel size of a square button

# Minecraft PE palette
OUTLINE = (55, 55, 55, 255)
FILL_TOP = (206, 206, 206)
FILL_BOT = (150, 150, 150)
HILITE = (240, 240, 240, 255)
SHADOW = (108, 108, 108, 255)
GLYPH = (48, 48, 48, 255)
GLYPH_HI = (250, 250, 250, 90)


def rounded_rect(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def vertical_gradient(size, top_rgb, bot_rgb):
    w, h = size
    grad = Image.new("RGB", (1, h))
    px = grad.load()
    for y in range(h):
        t = y / max(1, h - 1)
        px[0, y] = (
            int(top_rgb[0] + (bot_rgb[0] - top_rgb[0]) * t),
            int(top_rgb[1] + (bot_rgb[1] - top_rgb[1]) * t),
            int(top_rgb[2] + (bot_rgb[2] - top_rgb[2]) * t),
        )
    return grad.resize((w, h), Image.BILINEAR)


def stone_button(size=SIZE, radius=None, glyph_fn=None):
    """A Minecraft PE style chunky stone button with a glyph on top."""
    s = size * SS
    radius = radius if radius is not None else int(s * 0.13)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # 1px-ish outer outline
    d = ImageDraw.Draw(img)
    rounded_rect(d, (0, 0, s - 1, s - 1), radius, fill=OUTLINE)

    # body
    inset = max(2, int(s * 0.022))
    body_box = (inset, inset, s - 1 - inset, s - 1 - inset)
    grid = vertical_gradient((body_box[2] - body_box[0], body_box[3] - body_box[1]),
                             FILL_TOP, FILL_BOT).convert("RGBA")
    mask = Image.new("L", grid.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, grid.width - 1, grid.height - 1),
        radius=max(1, radius - inset), fill=255)
    img.paste(grid, (body_box[0], body_box[1]), mask)

    # MC-style bevel: bright on the top/left inner edge, dark on bottom/right.
    # Drawn as straight edges (not arcs) so it reads as a flat stone plate.
    bev = max(2, int(s * 0.022))
    r = max(1, radius - inset)
    hl = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    dh = ImageDraw.Draw(hl)
    x0, y0, x1, y1 = body_box
    dh.line([(x0 + r, y0 + bev // 2), (x1 - r, y0 + bev // 2)],
            fill=HILITE, width=bev)
    dh.line([(x0 + bev // 2, y0 + r), (x0 + bev // 2, y1 - r)],
            fill=HILITE, width=bev)
    dh.arc((x0 + bev // 2, y0 + bev // 2, x0 + 2 * r, y0 + 2 * r),
           start=180, end=270, fill=HILITE, width=bev)
    img.alpha_composite(hl)

    sh = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ds = ImageDraw.Draw(sh)
    ds.line([(x0 + r, y1 - bev // 2), (x1 - r, y1 - bev // 2)],
            fill=SHADOW, width=bev)
    ds.line([(x1 - bev // 2, y0 + r), (x1 - bev // 2, y1 - r)],
            fill=SHADOW, width=bev)
    ds.arc((x1 - 2 * r, y1 - 2 * r, x1 - bev // 2, y1 - bev // 2),
           start=0, end=90, fill=SHADOW, width=bev)
    img.alpha_composite(sh)

    if glyph_fn:
        g = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        glyph_fn(ImageDraw.Draw(g), s)
        img.alpha_composite(g)

    return img.resize((size, size), Image.LANCZOS)


# --------------------------------------------------------------------------
# glyphs: all take (draw, size) and paint on a transparent full-size canvas
# --------------------------------------------------------------------------

def glyph_up_arrow(d, s):
    w = s * 0.30          # shaft width
    head = s * 0.34
    cx = s / 2
    top = s * 0.24
    bot = s * 0.77
    pts = [(cx, top), (cx + head, top + head), (cx + w / 2, top + head),
           (cx + w / 2, bot), (cx - w / 2, bot), (cx - w / 2, top + head),
           (cx - head, top + head)]
    d.polygon(pts, fill=GLYPH)
    d.line(pts + [pts[0]], fill=(30, 30, 30, 255), width=max(2, s // 90), joint="curve")


def glyph_down_arrow(d, s):
    g = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    glyph_up_arrow(ImageDraw.Draw(g), s)
    d._image.paste(g.transpose(Image.ROTATE_180), (0, 0), g.transpose(Image.ROTATE_180))


def glyph_sword(d, s):
    # blade: rotated rectangle from bottom-left to top-right
    def rot(px, py, ang, cx, cy):
        a = math.radians(ang)
        dx, dy = px - cx, py - cy
        return (cx + dx * math.cos(a) - dy * math.sin(a),
                cy + dx * math.sin(a) + dy * math.cos(a))

    cx = cy = s / 2
    ang = -45
    blade = [(0.50, 0.13), (0.58, 0.13), (0.58, 0.62), (0.50, 0.62)]
    blade = [rot(x * s, y * s, ang, cx, cy) for x, y in blade]
    tip = rot(0.54 * s, 0.05 * s, ang, cx, cy)
    d.polygon([blade[0], tip, blade[1], blade[2], blade[3]], fill=GLYPH)

    # crossguard
    guard = [(0.40, 0.62), (0.68, 0.62), (0.68, 0.69), (0.40, 0.69)]
    guard = [rot(x * s, y * s, ang, cx, cy) for x, y in guard]
    d.polygon(guard, fill=GLYPH)

    # handle
    handle = [(0.50, 0.69), (0.58, 0.69), (0.58, 0.86), (0.50, 0.86)]
    handle = [rot(x * s, y * s, ang, cx, cy) for x, y in handle]
    d.polygon(handle, fill=GLYPH)

    # pommel
    p = rot(0.54 * s, 0.90 * s, ang, cx, cy)
    r = s * 0.045
    d.ellipse((p[0] - r, p[1] - r, p[0] + r, p[1] + r), fill=GLYPH)


def glyph_hand(d, s):
    """Simple pointing-hand cursor, like the MCPE 'place' button."""
    # palm
    d.rounded_rectangle((s * 0.36, s * 0.46, s * 0.66, s * 0.82),
                        radius=int(s * 0.09), fill=GLYPH)
    # index finger
    d.rounded_rectangle((s * 0.46, s * 0.20, s * 0.58, s * 0.52),
                        radius=int(s * 0.06), fill=GLYPH)
    # thumb
    d.rounded_rectangle((s * 0.28, s * 0.50, s * 0.40, s * 0.66),
                        radius=int(s * 0.055), fill=GLYPH)
    # knuckle bumps
    for i, x in enumerate((0.44, 0.52, 0.60)):
        d.rounded_rectangle((s * x - s * 0.045, s * 0.42, s * x + s * 0.045, s * 0.53),
                            radius=int(s * 0.04), fill=GLYPH)


def glyph_grid(d, s):
    """3x3 inventory grid."""
    n = 3
    gap = s * 0.045
    total = s * 0.62
    cell = (total - gap * (n - 1)) / n
    x0 = (s - total) / 2
    y0 = (s - total) / 2
    for r in range(n):
        for c in range(n):
            x = x0 + c * (cell + gap)
            y = y0 + r * (cell + gap)
            d.rounded_rectangle((x, y, x + cell, y + cell),
                                radius=int(cell * 0.16), fill=GLYPH)


def glyph_fly(d, s):
    """Double chevron up."""
    for i, off in enumerate((0.02, 0.20)):
        w = s * 0.30
        top = s * (0.30 + off)
        mid = s * (0.46 + off)
        bot = s * (0.62 + off)
        cx = s / 2
        pts = [(cx, top), (cx + w, mid), (cx + w * 0.55, mid), (cx, mid - s * 0.10),
               (cx - w * 0.55, mid), (cx - w, mid)]
        d.polygon(pts, fill=GLYPH)


def glyph_overflow(d, s):
    r = s * 0.058
    for x in (0.32, 0.5, 0.68):
        d.ellipse((s * x - r, s * 0.5 - r, s * x + r, s * 0.5 + r), fill=GLYPH)


def glyph_chat(d, s):
    d.rounded_rectangle((s * 0.20, s * 0.24, s * 0.80, s * 0.66),
                        radius=int(s * 0.12), fill=GLYPH)
    d.polygon([(s * 0.32, s * 0.62), (s * 0.30, s * 0.80), (s * 0.50, s * 0.64)],
              fill=GLYPH)


def glyph_camera(d, s):
    d.rounded_rectangle((s * 0.20, s * 0.34, s * 0.80, s * 0.74),
                        radius=int(s * 0.08), fill=GLYPH)
    d.rounded_rectangle((s * 0.38, s * 0.26, s * 0.62, s * 0.36),
                        radius=int(s * 0.04), fill=GLYPH)
    r = s * 0.13
    d.ellipse((s * 0.5 - r, s * 0.54 - r, s * 0.5 + r, s * 0.54 + r),
              fill=(196, 196, 196, 255))


# --------------------------------------------------------------------------
# joystick: MCPE is a rounded translucent square, not a circle
# --------------------------------------------------------------------------

def joystick_base(size=SIZE):
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = int(s * 0.04)
    rounded_rect(d, (pad, pad, s - pad, s - pad), int(s * 0.16),
                 fill=(74, 74, 74, 118), outline=(30, 30, 30, 150),
                 width=max(2, int(s * 0.012)))
    inner = int(s * 0.13)
    rounded_rect(d, (pad + inner, pad + inner, s - pad - inner, s - pad - inner),
                 int(s * 0.12), outline=(200, 200, 200, 55),
                 width=max(1, int(s * 0.008)))
    return img.resize((size, size), Image.LANCZOS)


def joystick_knob(size=SIZE):
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = (int(s * 0.22), int(s * 0.22), int(s * 0.78), int(s * 0.78))
    rounded_rect(d, box, int(s * 0.14), fill=(150, 150, 150, 190),
                 outline=(40, 40, 40, 200), width=max(2, int(s * 0.014)))
    rounded_rect(d, (box[0] + int(s * 0.03), box[1] + int(s * 0.03),
                     box[2] - int(s * 0.03), box[3] - int(s * 0.03)),
                 int(s * 0.12), fill=(186, 186, 186, 170))
    return img.resize((size, size), Image.LANCZOS)


def crosshair(size=64):
    """Minecraft's plain white plus sign."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    t = int(s * 0.11)          # arm thickness
    arm = int(s * 0.32)        # arm length from the centre
    c = s // 2
    d.rectangle((c - t // 2, c - arm, c + t // 2, c + arm), fill=(255, 255, 255, 235))
    d.rectangle((c - arm, c - t // 2, c + arm, c + t // 2), fill=(255, 255, 255, 235))
    return img.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    out = []

    def save(img, name):
        path = os.path.join(OUT_DIR, name)
        img.save(path)
        out.append(name)

    save(stone_button(glyph_fn=glyph_up_arrow), "jump_btn.png")
    save(stone_button(glyph_fn=glyph_down_arrow), "down.png")
    save(stone_button(glyph_fn=glyph_sword), "dig_btn.png")
    save(stone_button(glyph_fn=glyph_hand), "place_btn.png")
    save(stone_button(glyph_fn=glyph_grid), "inventory_btn.png")
    save(stone_button(glyph_fn=glyph_fly), "fly_btn.png")
    save(stone_button(glyph_fn=glyph_overflow), "overflow_btn.png")
    save(stone_button(glyph_fn=glyph_chat), "chat_btn.png")
    save(stone_button(glyph_fn=glyph_chat), "chat_hide_btn.png")
    save(stone_button(glyph_fn=glyph_chat), "chat_show_btn.png")
    save(stone_button(glyph_fn=glyph_camera), "camera_btn.png")
    # unused-but-must-exist buttons get a neutral look
    save(stone_button(glyph_fn=glyph_grid), "aux1_btn.png")
    save(stone_button(glyph_fn=glyph_up_arrow), "fast_btn.png")
    save(stone_button(glyph_fn=glyph_grid), "minimap_btn.png")
    save(stone_button(glyph_fn=glyph_grid), "noclip_btn.png")
    save(stone_button(glyph_fn=glyph_grid), "debug_btn.png")
    save(stone_button(glyph_fn=glyph_grid), "rangeview_btn.png")
    save(stone_button(glyph_fn=glyph_grid), "drop_btn.png")
    save(stone_button(glyph_fn=glyph_overflow), "exit_btn.png")
    save(stone_button(glyph_fn=glyph_grid), "zoom.png")
    save(joystick_base(), "joystick_bg.png")
    save(joystick_base(), "joystick_off.png")
    save(joystick_knob(), "joystick_center.png")
    save(crosshair(), "crosshair.png")

    print("wrote %d textures to %s" % (len(out), os.path.normpath(OUT_DIR)))
    for n in out:
        print("  ", n)


if __name__ == "__main__":
    main()
