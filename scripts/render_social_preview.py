#!/usr/bin/env python3
"""Export light/dark social cards while leaving the README hero unchanged."""
import copy
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

DEST = Path(__file__).resolve().parents[1] / 'docs/assets/brand'
NS = '{http://www.w3.org/2000/svg}'
ET.register_namespace('', NS[1:-1])


def render(theme, artwork, background, foreground):
    logo = copy.deepcopy(ET.parse(DEST / artwork).getroot())
    # Enlarge the original lockup while keeping its center and caption fixed.
    logo_width = 1060
    logo_height = logo_width * 360 / 938.119
    original_center_y = 96 + (920 * 360 / 938.119) / 2
    logo.attrib.update(x=str((1280 - logo_width) / 2),
                       y=str(original_center_y - logo_height / 2),
                       width=str(logo_width), height=str(logo_height))
    logo.attrib.pop('aria-labelledby', None)
    for child in list(logo):
        if child.tag in (NS + 'title', NS + 'desc'):
            logo.remove(child)
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="640" '
           'viewBox="0 0 1280 640" role="img" aria-labelledby="title desc">\n'
           '  <title id="title">Eggshell — AI memory. Fewer tokens.</title>\n'
           '  <desc id="desc">Eggshell mascot and wordmark above the caption: '
           'AI memory. Fewer tokens.</desc>\n'
           f'  <rect width="1280" height="640" fill="{background}"/>\n'
           + ET.tostring(logo, encoding='unicode') + '\n'
           f'  <text x="640" y="540" text-anchor="middle" fill="{foreground}" '
           'font-family="DejaVu Sans, sans-serif" font-size="36" font-weight="700">'
           'AI memory. Fewer tokens.</text>\n</svg>\n')
    path = DEST / f'github-social-preview-{theme}-1280x640.svg'
    path.write_text(svg)
    subprocess.run(['rsvg-convert', str(path), '-o', str(path.with_suffix('.png'))], check=True)


if __name__ == '__main__':
    render('dark', 'eggshell-primary-horizontal-white.svg', '#111111', '#f7f3ea')
    render('light', 'eggshell-primary-horizontal.svg', '#f7f3ea', '#111111')
