#!/usr/bin/env python3
"""Render flavor resources with circle/squircle masks. Requires Pillow and CairoSVG."""
import argparse
import io
import math
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ANDROID = "{http://schemas.android.com/apk/res/android}"


def attr(element, name):
    return element.attrib[ANDROID + name]


def vector_svg(element):
    if element.tag == "vector":
        return "".join(vector_svg(child) for child in element)
    if element.tag == "group":
        transform = (f"translate({attr(element, 'translateX')} {attr(element, 'translateY')}) "
                     f"scale({attr(element, 'scaleX')} {attr(element, 'scaleY')})")
        return f'<g transform="{transform}">' + "".join(vector_svg(child) for child in element) + "</g>"
    if element.tag == "path":
        return f'<path fill="{attr(element, "fillColor")}" d="{attr(element, "pathData")}"/>'
    raise ValueError(f"Unsupported vector element: {element.tag}")


def mask_svg(shape):
    if shape == "circle":
        return '<circle cx="54" cy="54" r="36"/>'
    # A fourth-order superellipse, representing a squircle launcher mask.
    points = []
    for index in range(1024):
        angle = index * 2 * math.pi / 1024
        x, y = math.cos(angle), math.sin(angle)
        points.append(f"{54 + 36 * math.copysign(abs(x) ** 0.5, x):.6f},"
                      f"{54 + 36 * math.copysign(abs(y) ** 0.5, y):.6f}")
    return '<polygon points="' + " ".join(points) + '"/>'


def render(flavor, mask, size):
    drawable = ROOT / "app/src" / flavor / "res/drawable"
    foreground = vector_svg(ET.parse(drawable / "ic_launcher_foreground.xml").getroot())
    background = ET.parse(drawable / "ic_launcher_background.xml").getroot()
    solid = background.find("solid")
    gradient = ""
    if solid is not None:
        fill = attr(solid, "color")
    else:
        element = background.find("gradient")
        assert attr(element, "angle") == "270" and attr(element, "type") == "linear"
        stops = "".join(f'<stop offset="{offset}" stop-color="{attr(element, name)}"/>'
                        for offset, name in (("0", "startColor"), ("0.5", "centerColor"), ("1", "endColor")))
        gradient = ('<linearGradient id="background" gradientUnits="userSpaceOnUse" '
                    'x1="0" y1="0" x2="0" y2="108">' + stops + '</linearGradient>')
        fill = "url(#background)"
    # AdaptiveIconDrawable shows the central 72dp of its 108dp layers at rest.
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="18 18 72 72" width="{size}" height="{size}">'
           f'<defs>{gradient}<clipPath id="mask">{mask_svg(mask)}</clipPath></defs>'
           f'<g clip-path="url(#mask)"><rect width="108" height="108" fill="{fill}"/>{foreground}</g></svg>')
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=size * 3, output_height=size * 3)
    return Image.open(io.BytesIO(png)).convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGB", (960, 760), "#EEEEF0")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype(str(ROOT / "app/src/main/res/font/inter_variable.ttf"), 24)
    for column, flavor in enumerate(("dev", "staging", "prod")):
        center = 160 + column * 320
        draw.text((center, 24), flavor, font=font, fill="#1A1B1E", anchor="mt")
        for row, mask in enumerate(("circle", "squircle")):
            icon = render(flavor, mask, 512)
            icon.save(args.output / f"{flavor}-{mask}.png")
            thumbnail = icon.resize((256, 256), Image.Resampling.LANCZOS)
            top = 74 + row * 340
            sheet.paste(thumbnail, (center - 128, top), thumbnail)
            draw.text((center, top + 274), mask, font=font, fill="#4A4C50", anchor="mt")
    sheet.save(args.output / "launcher-icons-preview.png")
    print(f"Saved six icon previews and a contact sheet to {args.output}")


if __name__ == "__main__":
    main()
