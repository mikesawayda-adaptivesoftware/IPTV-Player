#!/usr/bin/env python3
"""Generates the launcher icons, adaptive icons and the Android TV banner.

Kept in the repo so the branding can be regenerated rather than being a set of
binaries nobody can edit. Run from the repo root:

    python3 tool/make_icons.py

Everything is drawn at 4x and downsampled with LANCZOS, because Pillow's
draw primitives are not anti-aliased - drawing at final size gives visibly
jagged diagonals on the play triangle and the rounded corners.

Design constraints, in order of importance:

  - It has to read at 48px (mipmap-mdpi). That rules out text, thin strokes and
    fine detail; what survives is two or three bold shapes in high contrast.
  - Colours come from AppTheme so the icon matches the app it opens:
    primaryColor indigo -> secondaryColor purple for the ground, accentColor
    cyan for the play triangle.
  - The adaptive-icon foreground has to sit inside the 66dp safe circle of its
    108dp canvas, because the launcher can mask it to a circle, a squircle or a
    rounded square and crops anything outside that.
"""

import os
from PIL import Image, ImageDraw, ImageFont

SS = 4  # supersampling factor

# AppTheme palette (lib/core/theme/app_theme.dart).
INDIGO = (0x63, 0x66, 0xF1)
PURPLE = (0x8B, 0x5C, 0xF6)
CYAN = (0x22, 0xD3, 0xEE)
NEAR_WHITE = (0xF8, 0xFA, 0xFC)
BACKGROUND = (0x0F, 0x0F, 0x1A)
TEXT_SECONDARY = (0x94, 0xA3, 0xB8)

RES = os.path.join('android', 'app', 'src', 'main', 'res')

# Legacy launcher icon sizes, in dp-per-density order.
LAUNCHER_SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

# Adaptive icon layers are always 108dp; the launcher crops to 72dp and may
# mask to a circle of 66dp.
ADAPTIVE_SIZES = {
    'mipmap-mdpi': 108,
    'mipmap-hdpi': 162,
    'mipmap-xhdpi': 216,
    'mipmap-xxhdpi': 324,
    'mipmap-xxxhdpi': 432,
}


def diagonal_gradient(size, start, end):
    """Indigo top-left to purple bottom-right."""
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            # Normalised distance along the diagonal.
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(
                round(start[i] + (end[i] - start[i]) * t) for i in range(3)
            )
    return img


def draw_tv(draw, size, screen_fill):
    """A TV set with a play triangle, scaled to a `size` square canvas.

    All geometry is expressed as a fraction of the canvas so the same code
    serves a 48px launcher icon and a 432px adaptive foreground.
    """
    # Body. Deliberately wide and short - a 16:9-ish set reads as a television
    # at small sizes where a square would read as a generic window.
    bx0, by0 = size * 0.14, size * 0.24
    bx1, by1 = size * 0.86, size * 0.72
    radius = size * 0.07
    draw.rounded_rectangle([bx0, by0, bx1, by1], radius=radius, fill=NEAR_WHITE)

    # Screen cut-out.
    inset = size * 0.055
    draw.rounded_rectangle(
        [bx0 + inset, by0 + inset, bx1 - inset, by1 - inset],
        radius=radius * 0.55,
        fill=screen_fill,
    )

    # Play triangle, optically centred in the screen. Nudged right by a hair
    # because a triangle's visual centre of mass sits left of its bounding box.
    cx = (bx0 + bx1) / 2 + size * 0.012
    cy = (by0 + by1) / 2
    h = size * 0.20
    w = h * 0.86
    draw.polygon(
        [(cx - w / 2, cy - h / 2), (cx - w / 2, cy + h / 2), (cx + w / 2, cy)],
        fill=CYAN,
    )

    # Stand: a short neck and a base bar. Thick enough to survive 48px.
    neck_w = size * 0.07
    draw.rectangle(
        [cx - neck_w / 2, by1, cx + neck_w / 2, by1 + size * 0.09],
        fill=NEAR_WHITE,
    )
    base_w = size * 0.34
    draw.rounded_rectangle(
        [cx - base_w / 2, by1 + size * 0.07,
         cx + base_w / 2, by1 + size * 0.13],
        radius=size * 0.03,
        fill=NEAR_WHITE,
    )


def launcher_icon(size):
    """Legacy all-in-one icon: gradient ground, rounded corners, TV on top."""
    big = size * SS
    img = diagonal_gradient(big, INDIGO, PURPLE).convert('RGBA')

    # Rounded-square mask. Android applies its own shape on newer versions via
    # the adaptive icon, but the legacy asset has to bring its own.
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=big * 0.22, fill=255
    )
    img.putalpha(mask)

    draw_tv(ImageDraw.Draw(img), big, BACKGROUND)
    return img.resize((size, size), Image.LANCZOS)


def adaptive_foreground(size):
    """TV only, transparent ground, scaled into the 66dp safe circle."""
    big = size * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))

    # The art occupies the middle 62% of the 108dp canvas, which keeps it
    # inside the safe circle whatever mask the launcher picks.
    art = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    # Near-black screen, same as the legacy icon. An indigo screen sits on an
    # indigo background and the cyan triangle loses all its contrast.
    draw_tv(ImageDraw.Draw(art), big, BACKGROUND)
    scaled = art.resize((int(big * 0.62), int(big * 0.62)), Image.LANCZOS)
    offset = (big - scaled.width) // 2
    img.paste(scaled, (offset, offset), scaled)

    return img.resize((size, size), Image.LANCZOS)


def adaptive_background(size):
    big = size * SS
    img = diagonal_gradient(big, INDIGO, PURPLE)
    return img.resize((size, size), Image.LANCZOS).convert('RGBA')


def load_font(size):
    """Best available sans-serif, falling back to Pillow's bitmap default."""
    for path in (
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
        '/usr/share/fonts/TTF/DejaVuSans-Bold.ttf',
    ):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def wrap_to_width(draw, text, font, max_width):
    """Greedy word wrap at `max_width`, in the given font."""
    words, lines, line = text.split(), [], ''
    for word in words:
        trial = f'{line} {word}'.strip()
        if draw.textlength(trial, font=font) <= max_width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def fit_text(draw, text, box, start_size, max_lines):
    """Largest font size at which `text` wraps into `box` within `max_lines`.

    Written because a fixed font size silently overflows: at 0.175 of the banner
    height, "Definitely Not Cable" ran off the right edge and the name read as
    "Definitely".
    """
    max_w, max_h = box
    for size in range(start_size, 8, -2):
        font = load_font(size)
        lines = wrap_to_width(draw, text, font, max_w)
        if len(lines) > max_lines:
            continue
        widest = max(draw.textlength(line, font=font) for line in lines)
        line_h = size * 1.18
        if widest <= max_w and line_h * len(lines) <= max_h:
            return font, lines, line_h
    font = load_font(10)
    return font, wrap_to_width(draw, text, font, max_w), 12


def tv_banner(name, tagline):
    """The 320x180 Google TV banner. Exact size is required by Android."""
    w, h = 320 * SS, 180 * SS
    img = Image.new('RGB', (w, h), BACKGROUND)

    # A soft diagonal wash so the banner is not flat black next to the
    # colourful icons around it on the TV home row.
    wash = diagonal_gradient(h, INDIGO, PURPLE).resize((w, h))
    img = Image.blend(img, wash, 0.16)
    draw = ImageDraw.Draw(img)

    # Icon mark on the left, at banner scale.
    margin = int(w * 0.05)
    mark_size = int(h * 0.56)
    mark = Image.new('RGBA', (mark_size, mark_size), (0, 0, 0, 0))
    draw_tv(ImageDraw.Draw(mark), mark_size, BACKGROUND)
    img.paste(mark, (margin, (h - mark_size) // 2), mark)

    # Text block, sized to whatever room is actually left.
    text_x = margin + mark_size + int(w * 0.035)
    avail_w = w - text_x - margin
    title_font, title_lines, title_lh = fit_text(
        draw, name, (avail_w, h * 0.46), int(h * 0.20), 2)
    tag_font, tag_lines, tag_lh = fit_text(
        draw, tagline, (avail_w, h * 0.22), int(h * 0.085), 1)

    gap = int(h * 0.05)
    block_h = title_lh * len(title_lines) + gap + tag_lh * len(tag_lines)
    y = (h - block_h) / 2

    for line in title_lines:
        draw.text((text_x, y), line, font=title_font, fill=NEAR_WHITE)
        y += title_lh
    y += gap
    for line in tag_lines:
        draw.text((text_x, y), line, font=tag_font, fill=TEXT_SECONDARY)
        y += tag_lh

    return img.resize((320, 180), Image.LANCZOS)


def main():
    if not os.path.isdir(RES):
        raise SystemExit(f'run me from the repo root - {RES} not found')

    for folder, size in LAUNCHER_SIZES.items():
        path = os.path.join(RES, folder, 'ic_launcher.png')
        launcher_icon(size).save(path)
        print(f'  {path}  {size}x{size}')

    for folder, size in ADAPTIVE_SIZES.items():
        fg = os.path.join(RES, folder, 'ic_launcher_foreground.png')
        bg = os.path.join(RES, folder, 'ic_launcher_background.png')
        adaptive_foreground(size).save(fg)
        adaptive_background(size).save(bg)
        print(f'  {fg}  {size}x{size}')
        print(f'  {bg}  {size}x{size}')

    banner_dir = os.path.join(RES, 'drawable-xhdpi')
    os.makedirs(banner_dir, exist_ok=True)
    banner_path = os.path.join(banner_dir, 'banner.png')
    tv_banner('Definitely Not Cable', 'Live TV and on-demand').save(banner_path)
    print(f'  {banner_path}  320x180')


if __name__ == '__main__':
    main()
