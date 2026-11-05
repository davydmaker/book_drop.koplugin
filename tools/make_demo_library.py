"""Creates a small library with invented titles and drawn covers, for the README screenshots.

Usage: python3 -I tools/make_demo_library.py <output folder>. Needs Pillow.
"""
import io
import os
import sys
import zipfile

from PIL import Image, ImageDraw

BOOKS = [
    ("Helena Vargas - The House of Tides", 0, "wave"),
    ("Helena Vargas - An Inventory of Silence", 235, "lines"),
    ("Lia Serrano - A Map to Nowhere", 90, "circle"),
    ("Otavio Brandao - The Stopped Elevator", 30, "bars"),
    ("Otavio Brandao - The Lighthouse Keeper", 150, "circle"),
    ("Rui Salgado - Winter Letters", 215, "wave"),
    ("Rui Salgado - The Glass Orchard", 60, "lines"),
    ("Tessa Lindqvist - Salt and Paper", 180, "bars"),
]


def cover(tone, motif):
    k = 2
    width, height = 400 * k, 600 * k
    image = Image.new("L", (width, height), tone)
    d = ImageDraw.Draw(image)
    ink = 255 if tone < 128 else 0
    if motif == "wave":
        for row in range(6):
            y = height * (0.45 + row * 0.08)
            points = [(x, y + 30 * k * ((-1) ** (x // (60 * k)))) for x in range(0, width + 1, 60 * k)]
            d.line(points, fill=ink, width=5 * k)
    elif motif == "lines":
        for row in range(9):
            d.rectangle([60 * k, height * 0.3 + row * 42 * k, width - (60 + row * 16) * k, height * 0.3 + row * 42 * k + 8 * k], fill=ink)
    elif motif == "circle":
        d.ellipse([width * 0.2, height * 0.3, width * 0.8, height * 0.3 + width * 0.6], outline=ink, width=10 * k)
        d.ellipse([width * 0.42, height * 0.3 + width * 0.22, width * 0.58, height * 0.3 + width * 0.38], fill=ink)
    else:
        for column in range(5):
            top = height * (0.75 - column * 0.1)
            d.rectangle([width * (0.15 + column * 0.14), top, width * (0.25 + column * 0.14), height * 0.85], fill=ink)
    d.rectangle([40 * k, 60 * k, width - 40 * k, 74 * k], fill=ink)
    data = io.BytesIO()
    image.resize((400, 600), Image.LANCZOS).convert("RGB").save(data, "JPEG", quality=85)
    return data.getvalue()


def main():
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    for name, tone, motif in BOOKS:
        with zipfile.ZipFile(os.path.join(folder, name + ".epub"), "w") as epub:
            epub.writestr("mimetype", "application/epub+zip")
            epub.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>')
            epub.writestr("c.opf", '<package><metadata><meta name="cover" content="c"/></metadata><manifest><item id="c" href="cover.jpg" media-type="image/jpeg"/></manifest></package>')
            epub.writestr("cover.jpg", cover(tone, motif))
            epub.writestr("text.xhtml", "<html><body>" + "lorem ipsum " * 60000 + "</body></html>")


main()
