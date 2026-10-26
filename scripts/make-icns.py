#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make-icns.py -- turn one square PNG into a macOS `.icns`, without `iconutil`.

`iconutil` only ships with macOS, so this script writes the ICNS container by
hand (magic + big-endian total length + one TLV chunk per size, each chunk
carrying a PNG payload).  Result: a Retina-ready icon that can be built on
macOS, Linux or Windows.

Dependency: Pillow (the only non-stdlib requirement).
    python3 -m pip install --user Pillow

Usage:
    # build DSH.icns from your own artwork (1024x1024 PNG recommended)
    python3 scripts/make-icns.py -s ~/art/whale-1024.png -o DSH.icns

    # then drop it into a built bundle and point Info.plist at it
    cp DSH.icns DSH.app/Contents/Resources/DSH.icns
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string DSH" \
        DSH.app/Contents/Info.plist   # or edit the XML by hand

    # inspect an existing icon (structure + embedded PNG dimensions)
    python3 scripts/make-icns.py --verify DSH.icns

The repository ships **no** image files: pass your own source path.  The icon
you produce must not contain DeepSeek trademarks (see BRAND.md).
"""

from __future__ import annotations

import argparse
import io
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("error: Pillow is required -- python3 -m pip install --user Pillow")

# PNG-bearing ICNS element types understood by macOS 10.7+.
# 1024 is the @2x payload for the 512pt slot.
ICNS_TYPE_BY_SIZE = {
    16: "icp4",
    32: "icp5",
    64: "icp6",
    128: "ic07",
    256: "ic08",
    512: "ic09",
    1024: "ic10",
}
DEFAULT_SIZES = (16, 32, 64, 128, 256, 512, 1024)
DEFAULT_PADDING = 0.05


def render_size(src: Image.Image, size: int, padding: float) -> Image.Image:
    """Downscale *src* (RGBA) to one square tile, with an optional margin."""
    if not 0.0 <= padding < 0.5:
        raise SystemExit(f"error: --padding must be in [0, 0.5), got {padding}")
    inner = max(1, round(size * (1.0 - 2.0 * padding)))
    # Premultiply before resampling so transparent pixels cannot bleed colour.
    scaled = src.convert("RGBa").resize((inner, inner), Image.Resampling.LANCZOS).convert("RGBA")
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile.alpha_composite(scaled, ((size - inner) // 2, (size - inner) // 2))
    return tile


def build_icns(png_by_size: dict[int, bytes]) -> bytes:
    body = bytearray()
    for size in sorted(png_by_size):
        try:
            elem = ICNS_TYPE_BY_SIZE[size]
        except KeyError:
            raise SystemExit(
                "error: %dpx has no ICNS element type (supported: %s)"
                % (size, ",".join(map(str, sorted(ICNS_TYPE_BY_SIZE))))
            )
        payload = png_by_size[size]
        body += struct.pack(">4sI", elem.encode("ascii"), len(payload) + 8) + payload
    return b"icns" + struct.pack(">I", 8 + len(body)) + bytes(body)


def parse_icns(data: bytes) -> list[dict]:
    if data[:4] != b"icns" or len(data) < 8:
        raise ValueError("not an ICNS file (magic != 'icns')")
    declared = struct.unpack(">I", data[4:8])[0]
    if declared != len(data):
        raise ValueError(f"header length {declared} != file size {len(data)}")
    chunks, pos = [], 8
    while pos < len(data):
        if pos + 8 > len(data):
            raise ValueError(f"truncated chunk header at offset {pos}")
        elem, length = struct.unpack(">4sI", data[pos : pos + 8])
        if length < 8 or pos + length > len(data):
            raise ValueError(f"bad chunk length {length} at offset {pos}")
        payload = data[pos + 8 : pos + length]
        if payload[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"chunk {elem!r} is not a PNG payload")
        with Image.open(io.BytesIO(payload)) as im:
            im.load()
            chunks.append(
                {
                    "type": elem.decode("ascii", "replace"),
                    "length": length,
                    "size": im.size,
                    "payload": len(payload),
                    "offset": pos,
                }
            )
        pos += length
    return chunks


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Build or verify a PNG-based macOS .icns (no iconutil needed).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("-s", "--source", type=Path, help="square source image (PNG recommended)")
    ap.add_argument("-o", "--output", type=Path, default=Path("DSH.icns"), help="output .icns path")
    ap.add_argument("--sizes", default=",".join(map(str, DEFAULT_SIZES)), help="pixel sizes to embed")
    ap.add_argument(
        "--padding",
        type=float,
        default=DEFAULT_PADDING,
        help="transparent margin per side as a fraction (0 = full bleed)",
    )
    ap.add_argument("--verify", type=Path, help="verify an existing .icns and exit")
    args = ap.parse_args(argv)

    if args.verify:
        chunks = parse_icns(args.verify.read_bytes())
        print(f"OK {args.verify} ({args.verify.stat().st_size} bytes, {len(chunks)} chunks)")
        for c in chunks:
            print(f"  {c['type']:<5} {c['size'][0]:>4}px  chunk={c['length']:>7}B  offset={c['offset']}")
        return 0

    if not args.source:
        ap.error("--source is required (or use --verify)")
    sizes = sorted({int(s) for s in args.sizes.replace(" ", "").split(",") if s})
    try:
        with Image.open(args.source) as im:
            im.load()
            if im.width != im.height:
                ap.error(f"source must be square, got {im.width}x{im.height}")
            src = im.convert("RGBA")
    except OSError as exc:
        ap.error(f"cannot read {args.source}: {exc}")

    png_by_size = {}
    for size in sizes:
        tile = render_size(src, size, args.padding)
        buf = io.BytesIO()
        tile.save(buf, format="PNG", optimize=True, compress_level=9)
        png_by_size[size] = buf.getvalue()
        print(f"  {size:>4}px -> {ICNS_TYPE_BY_SIZE[size]:>5}  {len(buf.getvalue()):>7} bytes")

    icns = build_icns(png_by_size)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(icns)
    chunks = parse_icns(icns)
    print(f"wrote {args.output} ({len(icns)} bytes, {len(chunks)} chunks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
