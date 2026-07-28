#!/usr/bin/env python3
"""
P1 STEP 3 — Assemble the final app catalog.json from the reviewed Amazon draft.

Takes the human-reviewed asins.json + generate_3d.py's outcome report, re-fetches
live price/stock from Canopy (so every release ships current prices), and writes
catalog.json in the exact shape `CatalogItem` decodes (Core/Models/CatalogItem.swift)
— including the two P1 fields `asin` and `imageURL`.

As a final gate it merges the Quaternius + Tripo conversion reports and runs
validate_assignments.py, so a bad model/SKU pairing fails the build here, never
on a user's screen.

USAGE
    export CANOPY_API_KEY=...
    python3 ingest_amazon.py \
        --asins asins.json \
        --generate-report out-tripo/generate_report.json \
        --report out-quaternius/report.json \
        --3d-report out-tripo-usdz/report.json \
        --out ../../Snug/Resources/catalog.json \
        [--affiliate-tag snug-20] [--skip-refresh]

    --skip-refresh assembles from the seeded price data without touching Canopy
    (useful while iterating on the pipeline; a real release should refresh).

NOTE  This REPLACES the bundled catalog: the 12 legacy hand-written SKUs
      (article.com etc. with placeholder models) are superseded by the Amazon
      spine — that is the pivot.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

from canopy import CanopyError, lookup, price_cents
from validate_assignments import FOOTPRINT_TOLERANCE, footprint_spread

HERE = os.path.dirname(os.path.abspath(__file__))


def display_name(title: str) -> str:
    """
    Amazon titles are keyword soup ("HOOBRO Side Table, Industrial Snack ...,
    23.6 Inch ..."). The card-friendly name is the first comma/dash clause,
    hard-capped at 60 chars.
    """
    for sep in (",", " - ", " – ", "|"):
        if sep in title:
            title = title.split(sep, 1)[0]
            break
    title = title.strip()
    return title[:60].rstrip() if len(title) > 60 else title


def main() -> None:
    ap = argparse.ArgumentParser(description="P1: assemble catalog.json from reviewed Amazon data.")
    ap.add_argument("--asins", required=True, help="reviewed asins.json")
    ap.add_argument("--generate-report", required=True,
                    help="generate_3d.py --finalize output (model outcomes)")
    ap.add_argument("--report", required=True, help="Quaternius conversion report.json")
    ap.add_argument("--3d-report", dest="tripo_report", required=True,
                    help="Tripo conversion report.json (out-tripo-usdz/report.json)")
    ap.add_argument("--out", required=True, help="output catalog.json path")
    ap.add_argument("--affiliate-tag", default="snug-20")
    ap.add_argument("--skip-refresh", action="store_true",
                    help="skip the live Canopy price/stock refresh")
    args = ap.parse_args()

    with open(args.asins) as f:
        entries = json.load(f)
    unreviewed = [e["asin"] for e in entries if e.get("_review")]
    if unreviewed:
        sys.exit(f"ERROR: {len(unreviewed)} entries still flagged _review:true "
                 f"(first: {unreviewed[:5]}). Review them first.")

    with open(args.generate_report) as f:
        outcomes = {r["asin"]: r for r in json.load(f)["results"]}

    # Merged converted-model reports (Quaternius archetypes + Tripo meshes) —
    # needed up front so each SKU's model assignment can be footprint-gated the
    # same way the app will render it (see validate_assignments).
    with open(args.report) as f:
        models = {m["assetName"]: m for m in json.load(f)["models"]}
    with open(args.tripo_report) as f:
        models.update({m["assetName"]: m for m in json.load(f)["models"]})

    catalog, stale, refresh_failed, boxed = [], [], [], []
    for e in entries:
        asin = e["asin"]
        cents, currency = e["priceCents"], e["currencyCode"]
        in_stock = True

        if not args.skip_refresh:
            time.sleep(0.4)
            try:
                p = lookup(asin)
            except CanopyError as err:
                # A transient API failure is NOT "out of stock" — keep the
                # seeded price and flag the run below if too many degrade.
                refresh_failed.append(asin)
                print(f"  WARN {asin}: refresh failed ({err}); keeping seeded price",
                      file=sys.stderr)
                p = None
            if p:
                fresh_cents, fresh_currency = price_cents(p)
                if fresh_cents is not None:
                    cents, currency = fresh_cents, fresh_currency
                else:
                    # No price on a live listing = not currently buyable.
                    in_stock = False
            elif p is not None:
                # Canopy answered but the listing is gone from Amazon.
                stale.append(asin)
                in_stock = False

        if not cents or cents <= 0:
            # A $0.00 product would be false precision on a price. Never buyable.
            print(f"  WARN {asin}: no usable price (priceCents={cents}) — marked out of stock",
                  file=sys.stderr)
            in_stock = False

        outcome = outcomes.get(asin) or {}
        model_asset = outcome.get("modelAssetName") or e.get("archetype") or None
        # Footprint gate, identical to the app's render rule: a mesh whose w×d
        # can't reach the real footprint within tolerance (even rotated) would
        # render visibly warped — ship the honest stylized box instead (null).
        if model_asset:
            native = (models.get(model_asset) or {}).get("nativeDimsWDH")
            spread = footprint_spread(e["dimensionsMeters"], native) if native else None
            if spread is None or spread > FOOTPRINT_TOLERANCE:
                boxed.append((asin, model_asset, round(spread, 2) if spread else None))
                model_asset = None

        catalog.append({
            "id": f"amzn-{asin.lower()}",
            "name": display_name(e["title"]),
            "brand": e["brand"],
            "category": e["category"],
            "dimensions": e["dimensionsMeters"],
            "trueColorRGB": e["trueColorRGB"],
            "colorCategory": e["colorCategory"],
            "material": e["material"],
            "priceCents": cents,
            "currencyCode": currency,
            "retailerName": "Amazon",
            "productURL": e.get("productURL") or f"https://www.amazon.com/dp/{asin}",
            "affiliateTag": args.affiliate_tag or None,
            "thumbnailAssetName": None,
            "modelAssetName": model_asset,
            "inStock": in_stock,
            "isRemovable": e["isRemovable"],
            "asin": asin,
            "imageURL": e.get("mainImageUrl") or None,
        })

    # Duplicate ids would be undefined behavior in SwiftUI's ForEach — hard-fail
    # here, never on a user's screen.
    ids = [row["id"] for row in catalog]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        sys.exit(f"PIPELINE FAILED: duplicate catalog ids {dupes} — "
                 f"de-duplicate asins.json first.")

    # A refresh run where a large slice degraded is a bad run, not a bad
    # catalog — abort rather than ship stale prices at scale.
    if refresh_failed and len(refresh_failed) * 5 > len(entries):
        sys.exit(f"PIPELINE FAILED: {len(refresh_failed)}/{len(entries)} price "
                 f"refreshes failed — Canopy is degraded; re-run later.")

    # Stage the catalog next to the destination and only move it into the app
    # bundle after the validation gate passes — a rejected catalog must never
    # sit in Resources/ ready to be committed.
    out_dir = os.path.dirname(os.path.abspath(args.out)) or "."
    fd, staged = tempfile.mkstemp(suffix=".json", dir=out_dir)
    with os.fdopen(fd, "w") as f:
        json.dump(catalog, f, indent=2)

    # Final gate: aspect-ratio guardrail over the MERGED model set (Quaternius
    # archetypes + Tripo meshes), reusing the one canonical implementation.
    with open(args.report) as f:
        models = json.load(f)["models"]
    with open(args.tripo_report) as f:
        models += json.load(f)["models"]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tmp:
        json.dump({"models": models}, tmp)
        merged_path = tmp.name
    try:
        result = subprocess.run(
            [sys.executable, os.path.join(HERE, "validate_assignments.py"),
             "--catalog", staged, "--report", merged_path],
            check=False,
        )
    finally:
        os.unlink(merged_path)
    if result.returncode != 0:
        os.unlink(staged)
        sys.exit("\nPIPELINE FAILED: aspect-ratio guardrail rejected the catalog (see above).")

    os.replace(staged, args.out)
    print(f"Wrote {len(catalog)} SKUs -> {args.out}")
    if boxed:
        print(f"  {len(boxed)} SKUs ship the stylized box (no asset fits their footprint):")
        for asin, asset, spread in boxed:
            print(f"    {asin}: {asset} footprint {spread}x")
    if stale:
        print(f"  {len(stale)} listings vanished from Amazon (marked out of stock): {stale}")
    if refresh_failed:
        print(f"  {len(refresh_failed)} refreshes failed (kept seeded prices): {refresh_failed}")
    print("\nCatalog assembled and validated.")


if __name__ == "__main__":
    main()
