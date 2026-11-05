"""Draws the icon, the README banner and the GitHub social preview.

Usage: KOREADER_DIR=<desktop KOReader> python3 -I tools/make_brand_art.py
Run tools/koreader/render_readme_screens.sh first. Needs Pillow, and the Noto fonts that come with KOReader.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BLACK, WHITE = 0, 255
ICON_SIZE = 1024
SUPERSAMPLE = 3
TAGLINE = "Send books to your e-reader from any browser."
DETAILS = ["Over your local Wi-Fi, with no app to install.", "For KOReader. Approved on the device, one at a time."]


class Canvas:
    """Draws in icon coordinates, so each icon reads as if it were 1024 pixels wide."""

    def __init__(self, draw, scale):
        self.draw = draw
        self.scale = scale

    def rect(self, left, top, right, bottom, fill=WHITE):
        k = self.scale
        self.draw.rectangle([left * k, top * k, right * k, bottom * k], fill=fill)

    def round_rect(self, left, top, right, bottom, radius, fill=WHITE):
        k = self.scale
        self.draw.rounded_rectangle([left * k, top * k, right * k, bottom * k], radius=radius * k, fill=fill)

    def arc(self, cx, cy, radius, start, end, width, fill=WHITE):
        k = self.scale
        self.draw.arc([(cx - radius) * k, (cy - radius) * k, (cx + radius) * k, (cy + radius) * k], start, end, fill=fill, width=round(width * k))


def small_book(c, left, top, right, bottom, fill, cut):
    c.round_rect(left, top, right, bottom, 14, fill)
    spine = left + (right - left) * 0.16
    c.rect(spine, top, spine + (right - left) * 0.07, bottom, cut)


def draw_waves(c):
    small_book(c, 342, 500, 682, 930, WHITE, BLACK)
    for radius in (150, 270, 390):
        c.arc(512, 450, radius, 222, 318, 58)


def draw_icon():
    k = SUPERSAMPLE
    size = ICON_SIZE
    large = Image.new("L", (size * k, size * k), BLACK)
    draw_waves(Canvas(ImageDraw.Draw(large), k))
    final = large.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=190 * 4, fill=255)
    icon = Image.new("LA", (size, size))
    icon.paste(final)
    icon.putalpha(mask.resize((size, size), Image.LANCZOS))
    return icon


def halftone(image, cx, cy, radius, spacing):
    d = ImageDraw.Draw(image)
    row, y = 0, cy - radius
    while y <= cy + radius:
        x = cx - radius + (spacing / 2 if row % 2 else 0)
        while x <= cx + radius:
            distance = math.hypot(x - cx, y - cy) / radius
            if distance <= 1:
                dot = spacing * 0.34 * (1 - distance * 0.72)
                d.ellipse([x - dot, y - dot, x + dot, y + dot], fill=88)
            x += spacing
        y += spacing * 0.87
        row += 1


def place_screen(image, name, center, height, angle):
    screen = Image.open(os.path.join(ROOT, "docs", "screenshots", name + ".png")).convert("L")
    screen = screen.resize((round(height * screen.width / screen.height), height), Image.LANCZOS)
    framed = Image.new("L", (screen.width + 12, screen.height + 12), WHITE)
    framed.paste(screen, (6, 6))
    rotated = framed.convert("LA").rotate(angle, expand=True, resample=Image.BICUBIC)
    image.paste(rotated.getchannel("L"), (round(center[0] - rotated.width / 2), round(center[1] - rotated.height / 2)), rotated.getchannel("A"))


def draw_header(width, height, fonts, icon, layout):
    k = 2
    image = Image.new("L", (width * k, height * k), BLACK)
    middle, screen_height, offset, text = layout["middle"], layout["screen_height"], layout["offset"], layout["text"]
    halftone(image, middle * k, height // 2 * k, round(layout["halftone"] * k), 26 * k)
    place_screen(image, "device_waiting", ((middle - offset) * k, (height // 2 + 8) * k), screen_height * k, 6)
    place_screen(image, "device_connected", ((middle + offset) * k, (height // 2 - 8) * k), screen_height * k, -5)
    margin = 58
    icon_size = round(96 * text)
    title_size = round(72 * text)
    tagline_size = round(24 * text)
    details_size = round(19 * text)
    details = layout.get("details")
    block = icon_size + title_size + tagline_size + round(44 * text)
    if details:
        block += round(details_size * 1.45 * len(details)) + round(22 * text)
    y = (height - block) // 2
    small = icon.resize((icon_size * k, icon_size * k), Image.LANCZOS)
    # The drawing starts inside the icon's black square, which disappears on this background.
    inset = round(icon_size * 222 / ICON_SIZE)
    image.paste(small.getchannel("L"), ((margin - inset) * k, y * k), small.getchannel("A"))
    y += icon_size + round(6 * text)
    d = ImageDraw.Draw(image)
    d.text((margin * k, y * k), "Book Drop", font=ImageFont.truetype(fonts["bold"], title_size * k), fill=WHITE)
    y += title_size + round(26 * text)
    d.text((margin * k, y * k), TAGLINE, font=ImageFont.truetype(fonts["italic"], tagline_size * k), fill=WHITE)
    y += tagline_size + round(30 * text)
    if details:
        font = ImageFont.truetype(fonts["regular"], details_size * k)
        for line in details:
            d.text((margin * k, y * k), line, font=font, fill=205)
            y += round(details_size * 1.45)
    return image.resize((width, height), Image.LANCZOS)


def main():
    koreader = os.environ.get("KOREADER_DIR")
    if not koreader:
        sys.exit("Set KOREADER_DIR to the KOReader folder, which has the Noto fonts.")
    noto = os.path.join(koreader, "fonts", "noto")
    fonts = {
        "bold": os.path.join(noto, "NotoSerif-Bold.ttf"),
        "italic": os.path.join(noto, "NotoSerif-Italic.ttf"),
        "regular": os.path.join(noto, "NotoSerif-Regular.ttf"),
    }
    brand = os.path.join(ROOT, "docs", "brand")
    os.makedirs(brand, exist_ok=True)
    icon = draw_icon()
    icon.save(os.path.join(brand, "icon.png"), optimize=True)
    draw_header(1280, 400, fonts, icon, {"middle": 980, "screen_height": 330, "offset": 110, "text": 1, "halftone": 280}).save(os.path.join(brand, "banner.png"), optimize=True)
    draw_header(1280, 640, fonts, icon, {"middle": 985, "screen_height": 430, "offset": 112, "text": 1.05, "halftone": 360, "details": DETAILS}).save(os.path.join(ROOT, "docs", "social-preview.png"), optimize=True)
    print("Images generated in docs/brand and docs/social-preview.png")


main()
