#!/usr/bin/env python3
"""
Aspect-ratio assignment guardrail for the Snug catalog.

The app's CatalogModelLoader.fitTransform stretches a model's bounding box per
axis to the SKU's real dimensions. That stretch is invisible when the asset's
native proportions are CLOSE to the SKU's, and turns into "taffy legs" when they
are not. This script refuses the bad pairings before they ship.

For every catalog item whose `modelAssetName` matches a converted model in the
pipeline report, it computes the per-axis fit factors (target / native) and their
SPREAD = max/min. Spread == 1.0 means a perfectly uniform (distortion-free) fit;
the further above 1.0, the more the model is squashed/stretched non-uniformly.
Anything past the tolerance is a loud error, e.g.:

    PIPELINE ERROR: asset 'kenney_chair_01' (w:d:h 1.0:1.0:1.1) cannot back SKU
    'snug-sofa-lina-3seat' (2.60:1.08:1.0) without 2.4x non-uniform stretch.
    Provide a wider asset variant or repoint modelAssetName.

Usage:
    validate_assignments.py --catalog <catalog.json> --report <report.json> \
        [--tolerance 1.15]
Exit code is nonzero if any assignment exceeds tolerance (so CI / build_catalog
can fail the build).
"""

import argparse
import json
import sys


def fmt_ratio(dims):
    """A scale-invariant w:d:h signature normalized to the smallest axis."""
    lo = min(d for d in dims if d > 1e-6)
    return ":".join(f"{d / lo:.2f}" for d in dims)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--tolerance", type=float, default=1.15,
                    help="max allowed spread (max/min) of per-axis fit factors")
    args = ap.parse_args()

    with open(args.catalog) as f:
        catalog = json.load(f)
    with open(args.report) as f:
        models = {m["assetName"]: m for m in json.load(f)["models"]}

    errors, warnings, ok, unmatched = [], [], [], []

    for item in catalog:
        name = item.get("modelAssetName")
        if not name:
            continue                       # null model -> app falls back to the box
        model = models.get(name)
        if model is None:
            unmatched.append((item["id"], name))
            continue

        target = item["dimensions"]        # (width, depth, height)
        native = model["nativeDimsWDH"]    # (width, depth, height)
        factors = [target[i] / native[i] for i in range(3) if native[i] > 1e-6]
        spread = max(factors) / min(factors)

        line = (f"{item['id']:<32} <- {name:<24} "
                f"SKU {fmt_ratio(target):<14} asset {fmt_ratio(native):<14} "
                f"stretch {spread:.2f}x")
        if spread > args.tolerance:
            errors.append("PIPELINE ERROR: " + line)
        elif spread > 1.0 + (args.tolerance - 1.0) * 0.6:
            warnings.append("near-tolerance:  " + line)
        else:
            ok.append("ok:              " + line)

    print(f"== aspect-ratio guardrail (tolerance {args.tolerance:.2f}x) ==\n")
    for l in ok:
        print(l)
    for l in warnings:
        print(l)
    for l in errors:
        print(l)
    if unmatched:
        print("\nunmatched (modelAssetName has no converted asset yet — falls back to box):")
        for sku, name in unmatched:
            print(f"  {sku} -> {name}")

    print(f"\n{len(ok)} ok, {len(warnings)} near, {len(errors)} over-tolerance, "
          f"{len(unmatched)} unmatched")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
