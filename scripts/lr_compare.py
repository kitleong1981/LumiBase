#!/usr/bin/env python3
"""Compare a LumiBase render against a Lightroom export (Lab dE76 at 2000px).

Usage: lr_compare.py REFERENCE.jpg RENDER.png [OTHER_RENDER.png ...]
Render PNGs come from the opt-in HighlightsDiagTests (see docs/baseline-tone-correction-zhTW.md).
"""
import sys
import numpy as np
from PIL import Image

M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
WHITE = np.array([0.95047, 1.0, 1.08883])


def load(path, size=(2000, 1333)):
    return np.asarray(Image.open(path).convert("RGB").resize(size, Image.LANCZOS)).astype(float) / 255


def lab(srgb):
    lin = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
    xyz = lin @ M.T / WHITE
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def chroma(l):
    return np.hypot(l[..., 1], l[..., 2])


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ref = lab(load(sys.argv[1]))
    for path in sys.argv[2:]:
        out = lab(load(path))
        err = np.sqrt(((out - ref) ** 2).sum(-1))
        print(f"{path}: dE mean {err.mean():.2f}  p95 {np.percentile(err, 95):.1f}")
        for name, lo, hi in [("dark/mid L*<35", 0, 35), ("bright L*>=35", 35, 101)]:
            m = (out[..., 0] >= lo) & (out[..., 0] < hi)
            if m.any():
                print(f"  {name}: dL(ref-out) {(ref[..., 0] - out[..., 0])[m].mean():+.1f}  "
                      f"chroma ref/out {chroma(ref)[m].mean() / max(chroma(out)[m].mean(), 1e-6):.2f}")


if __name__ == "__main__":
    main()
