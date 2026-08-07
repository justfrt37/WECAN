#!/usr/bin/env python3
"""Batch-crop bottom watermark strip off images. Drag a folder onto crop_watermark.command."""
import sys
from pathlib import Path
from PIL import Image

Y_KEEP_RATIO = 0.90  # keep top 90% height, drop bottom 10% (safe-min watermark band)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".tif", ".tiff", ".bmp"}


def crop_file(src: Path, dst: Path) -> None:
    with Image.open(src) as img:
        w, h = img.size
        crop_h = int(h * Y_KEEP_RATIO)
        cropped = img.crop((0, 0, w, crop_h))
        dst.parent.mkdir(parents=True, exist_ok=True)
        if img.format == "JPEG":
            cropped.save(dst, quality=95)
        else:
            cropped.save(dst)


def main(argv):
    if len(argv) < 2:
        print("Usage: crop_watermark.py <folder>")
        return 1

    src_root = Path(argv[1]).resolve()
    if not src_root.is_dir():
        print(f"Not a folder: {src_root}")
        return 1

    out_root = src_root.parent / f"{src_root.name}_cropped"
    ok, skipped = 0, []

    for src in sorted(src_root.rglob("*")):
        if not src.is_file() or src.suffix.lower() not in IMAGE_EXTS:
            continue
        rel = src.relative_to(src_root)
        dst = out_root / rel
        try:
            crop_file(src, dst)
            ok += 1
        except Exception as e:
            skipped.append((src, str(e)))

    print(f"Done. Cropped: {ok}. Skipped: {len(skipped)}.")
    for f, err in skipped:
        print(f"  SKIP {f}: {err}")
    print(f"Output folder: {out_root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
