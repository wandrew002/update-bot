"""Zero Two dance GIF -> Sixel frames for the update bot.

Sixel is a terminal graphics format: the terminal draws real pixels (10 x 20
per character cell in Windows Terminal) instead of text, so the GIF is shown at
its own resolution. Each frame becomes one escape string the bot prints at the
mascot's position.

Usage:  python -I make-sixel.py zero-two-hd.gif mascot.sixel.json
"""
import json
import sys

import numpy as np
from PIL import Image, ImageSequence

SRC, OUT = sys.argv[1], sys.argv[2]
BOX = (150, 0, 490, 360)   # 340 x 360 px around the dancer = 34 x 18 cells
STEP = 3                   # keep every 3rd source frame
COLORS = 64                # palette size shared by every frame

ESC = "\x1b"

im = Image.open(SRC)
durations = [f.info.get("duration", 40) for f in ImageSequence.Iterator(im)]
frames = [f.convert("RGB").crop(BOX) for f in ImageSequence.Iterator(im)]
picks = frames[::STEP]
delay = int(round(sum(durations) / max(1, len(durations)) * STEP))
w, h = picks[0].size

# One palette for the whole animation, so colours do not shimmer between frames.
sample = picks[:: max(1, len(picks) // 12)]
sheet = Image.new("RGB", (w * len(sample), h))
for i, f in enumerate(sample):
    sheet.paste(f, (i * w, 0))
pal_img = sheet.quantize(colors=COLORS, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
palette = np.array(pal_img.getpalette()[: COLORS * 3]).reshape(-1, 3)


def rle(bits):
    """Run-length encode one colour's row of sixel values."""
    n = len(bits)
    while n > 0 and bits[n - 1] == 0:      # trailing empty columns need no data
        n -= 1
    out = []
    i = 0
    while i < n:
        v = bits[i]
        j = i + 1
        while j < n and bits[j] == v:
            j += 1
        run = j - i
        ch = chr(63 + int(v))
        out.append("!%d%s" % (run, ch) if run > 3 else ch * run)
        i = j
    return "".join(out)


def encode(idx):
    out = [ESC + "P0;1;0q", '"1;1;%d;%d' % (w, h)]
    for c in np.unique(idx):
        r, g, b = palette[c]
        out.append("#%d;2;%d;%d;%d" % (c, round(r * 100 / 255), round(g * 100 / 255), round(b * 100 / 255)))
    for y0 in range(0, h, 6):
        band = idx[y0:y0 + 6]
        first = True
        for c in np.unique(band):
            mask = band == c
            bits = np.zeros(w, dtype=np.int32)
            for row in range(mask.shape[0]):
                bits |= mask[row].astype(np.int32) << row
            out.append(("" if first else "$") + "#%d" % c + rle(bits))
            first = False
        out.append("-")
    out.append(ESC + "\\")
    return "".join(out)


encoded = []
for f in picks:
    q = f.quantize(palette=pal_img, dither=Image.Dither.NONE)
    encoded.append(encode(np.asarray(q)))

with open(OUT, "w", encoding="utf-8") as fh:
    json.dump({"cols": (w + 9) // 10, "rows": (h + 19) // 20, "width": w, "height": h,
               "delayMs": delay, "frames": encoded}, fh)

sizes = [len(s) for s in encoded]
print("frames=%d  %dx%d px  = %d x %d cells  delay=%d ms  avg %d KB/frame  total %.1f MB"
      % (len(encoded), w, h, (w + 9) // 10, (h + 19) // 20, delay, sum(sizes) // len(sizes) // 1024, sum(sizes) / 1e6))

# What the quantised frames look like, for checking the palette.
if len(sys.argv) > 3:
    strip = Image.new("RGB", (w * 4, h))
    for i, k in enumerate((0, len(picks) // 4, len(picks) // 2, 3 * len(picks) // 4)):
        strip.paste(picks[k].quantize(palette=pal_img, dither=Image.Dither.NONE).convert("RGB"), (i * w, 0))
    strip.save(sys.argv[3])
