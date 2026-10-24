"""Generates the iOS app icon and the launch screen's icon from Sprig's pixels (visual design §8.1, the mockups'
`iconGrid`): the 36 x 36 cell picture of the Android adaptive icon (the dawn sky in three bands with a dithered row
at each edge, a strip of grass, Sprig's `base` pose with its base box at cell (9, 13), its feet on row 23), of which
the middle 24 x 24 cells are what a launcher shows; the mockups' rounded-square icon is those cells, and so is this
one. Three appearances go into AppIcon.appiconset: light (the dawn sky), dark (the night sky and grass of design §5)
and tinted (Sprig's outline, leaves included, in white on black with the eyes cut out; iOS tints it). The launch
screen's LaunchIcon is the same picture in a circle, as on the mockups' launch screen, 168 pt (7 pt a cell) at @2x and
@3x, with a night version for the dark appearance.

The output depends only on the manifest: running it again gives the same files. Needs python3 with Pillow. From the
repository root:
  python3 scripts/dev/make-ios-icon.py
"""
import json
import os
import sys

from PIL import Image, ImageDraw

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
MANIFEST = os.path.join(ROOT, 'Skins', 'sprig', 'manifest.json')
ASSETS = os.path.join(ROOT, 'ios', 'Critter', 'Assets.xcassets')

CELLS = 36
GROUND = 23  # the grass starts on this row
SPRIG_AT = (9, 13)  # where Sprig's base box (column 0, row 0) goes: centered, its feet on the grass
VISIBLE = (6, 30)  # the cells a launcher shows, in both directions: the middle 24

ICON_PX = 1024
LAUNCH_PT = 168  # 24 cells of 7 pt

# The mockups' icon sky (lighter than the meadow's dawn so the purple stands out) and the meadow's night (design §5).
DAWN = {'top': '#8FCEFF', 'middle': '#B4DEFF', 'bottom': '#D6EEFF',
        'grass': '#8ED07A', 'grass_hi': '#B5E39C', 'grass_lo': '#6DB65A'}
NIGHT = {'top': '#1E1B3A', 'middle': '#2B2752', 'bottom': '#3B3466',
         'grass': '#2F5A33', 'grass_hi': '#3E7342', 'grass_lo': '#22452A'}


def sky_and_grass(sky):
    """The background, cell by cell (the mockups' iconGrid): three bands with a dithered row at each edge, then the
    grass with its light top row, a few blades poking into the sky and dark specks."""
    cells = {}
    for y in range(CELLS):
        for x in range(CELLS):
            c = sky['top'] if y < 10 else sky['middle'] if y < 17 else sky['bottom'] if y < GROUND else sky['grass']
            if y == 10 and x % 2 == 0:
                c = sky['top']
            if y == 9 and x % 4 == 1:
                c = sky['middle']
            if y == 17 and x % 2 == 0:
                c = sky['middle']
            if y == 16 and x % 4 == 1:
                c = sky['bottom']
            if y == GROUND:
                c = sky['grass_hi']
            if y == GROUND - 1 and (x % 7 == 2 or x % 11 == 6):
                c = sky['grass_hi']
            if y > GROUND + 1 and (x * 7 + y * 13) % 17 == 0:
                c = sky['grass_lo']
            cells[(x, y)] = c
    return cells


def base_pose(manifest):
    """Sprig's `base` pose as {(x, y): palette character} in base-box cells, parts laid over each other in order
    (later parts cover earlier ones), like SkinRenderer.grid."""
    pixels = {}
    for name in manifest['poses']['base']:
        part = manifest['parts'][name]
        ax, ay = part['at']
        for r, line in enumerate(part['rows']):
            for c, ch in enumerate(line):
                if ch != '.':
                    pixels[(ax + c, ay + r)] = ch
    return pixels


def hex_rgba(color):
    color = color.lstrip('#')
    return tuple(int(color[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def paint(cells, size, background=None):
    """The visible 24 x 24 cells of `cells` ({(x, y): '#RRGGBB'}) on a `size` px square; a cell spans from
    round(i * size / 24) to round((i + 1) * size / 24), so cells differ by a pixel at most when size is not a
    multiple of 24. Cells not in `cells` are `background` (transparent when None)."""
    image = Image.new('RGBA', (size, size), hex_rgba(background) if background else (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    lo, hi = VISIBLE
    n = hi - lo

    def edge(i):
        return round(i * size / n)

    for (x, y), color in cells.items():
        if lo <= x < hi and lo <= y < hi:
            i, j = x - lo, y - lo
            draw.rectangle((edge(i), edge(j), edge(i + 1) - 1, edge(j + 1) - 1), fill=hex_rgba(color))
    return image


def circle(image):
    """`image` cut to the circle that fills it, with a smooth edge (drawn four times larger, then scaled down)."""
    size = image.width
    mask = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(image, (0, 0), mask.resize((size, size), Image.LANCZOS))
    return out


def save(image, folder, name):
    path = os.path.join(ASSETS, folder, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, optimize=True)
    print('wrote', os.path.relpath(path, ROOT))


def write_json(folder, contents):
    path = os.path.join(ASSETS, folder, 'Contents.json')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(contents, f, indent=2)
        f.write('\n')
    print('wrote', os.path.relpath(path, ROOT))


INFO = {'author': 'xcode', 'version': 1}


def main():
    with open(MANIFEST, encoding='utf-8') as f:
        manifest = json.load(f)
    palette = manifest['palette']
    sprig = {(x + SPRIG_AT[0], y + SPRIG_AT[1]): ch for (x, y), ch in base_pose(manifest).items()}
    lo, hi = VISIBLE
    for (x, y) in sprig:
        assert lo <= x < hi and lo <= y < hi, f'Sprig does not fit the visible icon at {(x, y)}'

    def picture(sky):
        cells = sky_and_grass(sky)
        cells.update({k: palette[ch] for k, ch in sprig.items()})
        return cells

    light, dark = picture(DAWN), picture(NIGHT)
    # The eyes (o) and their shine (w) are cut out; iOS turns the image grey and tints the light parts.
    outline = {k: '#FFFFFF' for k, ch in sprig.items() if ch not in ('o', 'w')}

    icon = 'AppIcon.appiconset'
    save(paint(light, ICON_PX), icon, 'icon-light.png')
    save(paint(dark, ICON_PX), icon, 'icon-dark.png')
    save(paint(outline, ICON_PX, background='#000000'), icon, 'icon-tinted.png')
    write_json(icon, {
        'images': [
            {'filename': 'icon-light.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
            {'appearances': [{'appearance': 'luminosity', 'value': 'dark'}],
             'filename': 'icon-dark.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
            {'appearances': [{'appearance': 'luminosity', 'value': 'tinted'}],
             'filename': 'icon-tinted.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
        ],
        'info': INFO,
    })

    launch = 'LaunchIcon.imageset'
    images = []
    for name, cells, appearance in (('launch-icon', light, None), ('launch-icon-dark', dark, 'dark')):
        for scale in (2, 3):
            file = f'{name}@{scale}x.png'
            save(circle(paint(cells, LAUNCH_PT * scale)), launch, file)
            entry = {'filename': file, 'idiom': 'universal', 'scale': f'{scale}x'}
            if appearance:
                entry = {'appearances': [{'appearance': 'luminosity', 'value': appearance}], **entry}
            images.append(entry)
    write_json(launch, {'images': images, 'info': INFO})


if __name__ == '__main__':
    main()
