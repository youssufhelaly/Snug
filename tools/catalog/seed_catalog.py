#!/usr/bin/env python3
"""
P1 STEP 1 — Auto-seed the Amazon catalog draft (asins_draft.json).

Discovers real furniture ASINs per Snug category via Canopy search, enriches
each with assembled dims / price / images, and auto-infers the fields Canopy
can't give us directly:

  - colorCategory + trueColorRGB  (dominant pixel of mainImageUrl, via Pillow)
  - material                      (feature-bullet keyword scan)
  - isRemovable                   (keyword defaults; renter-safe gate)
  - archetype                     (best-fitting Quaternius asset by aspect
                                   spread — the honest-footprint fallback when
                                   Tripo generation fails for a SKU)

Entries the heuristics aren't confident about get "_review": true with reasons,
so the one human pass is a targeted fix-up, not a full audit. SKUs with only
PACKAGE dims (which would lie in the fit check — CLAUDE.md hard rule) are
dropped entirely, never flagged.

USAGE
    export CANOPY_API_KEY=...
    python3 seed_catalog.py \
        --report out-quaternius/report.json \
        --out asins_draft.json \
        [--per-category 15]

    Budget: ~13 search calls + 13*per-category lookups (~208 calls at 15).

HUMAN WORKFLOW AFTER
    Open asins_draft.json, fix the "_review": true entries (check dims order,
    color, material against the live listing), save as asins.json. Done — the
    rest of the pipeline (generate_3d.py, ingest_amazon.py) reads asins.json.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
import urllib.request

from canopy import (
    RAW_CACHE_DIR, CanopyError, cached_lookup, extract_dims, price_cents,
    ratings, search_asins,
)

# --- category spine ------------------------------------------------------------
# Keys are FurnitureCategory rawValues (Core/Models/FurnitureModels.swift).
# Search terms are tuned for assembled-furniture listings in the renter budget.
CATEGORY_SEARCHES = {
    "sofa":         "sofa couch small apartment",
    "chair":        "accent armchair living room",
    "bed":          "bed frame queen platform",
    "desk":         "computer desk home office",
    "coffee_table": "coffee table living room",
    "side_table":   "side table small",
    "dresser":      "dresser chest of drawers",
    "wardrobe":     "wardrobe closet armoire",
    "nightstand":   "nightstand bedside table",
    "bookshelf":    "bookshelf 5 shelf",
    "tv_stand":     "tv stand entertainment center",
}

# Quaternius archetype candidates per category. The picker chooses whichever
# candidate needs the LEAST non-uniform stretch to reach the SKU's real dims
# (same spread metric as validate_assignments.py).
ARCHETYPE_CANDIDATES = {
    "sofa":         ["quaternius_Sofa", "quaternius_Sofa2", "quaternius_Sofa3"],
    "chair":        ["quaternius_Sofa_individual", "quaternius_Chair", "quaternius_OfficeChair"],
    "dining_chair": ["quaternius_Chair"],
    "bed":          ["quaternius_BedDouble", "quaternius_BedTwin"],
    "desk":         ["quaternius_Desk", "quaternius_Table"],
    "dining_table": ["quaternius_Table", "quaternius_Table2"],
    "coffee_table": ["quaternius_Table2", "quaternius_Table"],
    "side_table":   ["quaternius_NightStand", "quaternius_Stool"],
    "dresser":      ["quaternius_ShortCloset", "quaternius_NightStand"],
    "wardrobe":     ["quaternius_Closet"],
    "nightstand":   ["quaternius_NightStand"],
    "bookshelf":    ["quaternius_Bookcase", "quaternius_Bookcase_Books"],
    "tv_stand":     ["quaternius_ShortCloset", "quaternius_Table2"],
}

# sRGB anchors for the 15 FurnitureColorCategory buckets — the same
# representative colors the app renders (FurnitureColorCategory in
# FurnitureModels.swift). Nearest-anchor classification keeps browse filters
# and rendering in agreement.
COLOR_ANCHORS = {
    "white":      (0xF5, 0xF0, 0xE8),
    "cream":      (0xED, 0xE0, 0xC4),
    "lightGrey":  (0xC8, 0xC4, 0xBC),
    "darkGrey":   (0x6B, 0x65, 0x60),
    "black":      (0x2B, 0x27, 0x22),
    "warmBrown":  (0x8B, 0x5E, 0x3C),
    "coolBrown":  (0x6B, 0x57, 0x44),
    "tan":        (0xC4, 0xA8, 0x82),
    "navy":       (0x2C, 0x3E, 0x6B),
    "teal":       (0x2D, 0x6B, 0x6B),
    "warmRed":    (0xB8, 0x54, 0x50),
    "warmGreen":  (0x4A, 0x7C, 0x59),
    "warmYellow": (0xC4, 0xA8, 0x32),
    "warmOrange": (0xE8, 0x71, 0x4A),
}

# Material inference: first keyword family that hits in title+bullets wins.
# Order matters — "faux leather" must be checked before generic "fabric" words.
MATERIAL_KEYWORDS = [
    ("leather",  ["leather"]),
    ("fabric",   ["fabric", "upholster", "linen", "velvet", "boucle", "bouclé", "polyester blend", "chenille"]),
    ("glass",    ["tempered glass", "glass top", "glass door"]),
    ("metal",    ["metal frame", "metal bed", "metal platform", "steel", "iron ", "aluminum"]),
    ("wood",     ["solid wood", "oak", "walnut", "pine", "bamboo", "mdf", "engineered wood", "particle board", "wood"]),
    ("plastic",  ["plastic", "resin", "polypropylene", "acrylic"]),
]

# Categories whose long dimension runs left-right (app-convention WIDTH). On
# unlabeled "L x W x H" listings Amazon's "length" is that long span, so the
# default L→depth mapping would invert the footprint — for these categories we
# put the longer of the first two numbers on width. Beds are deliberately NOT
# here (a bed's Amazon length IS its depth, headboard to foot); chairs and
# nightstands are near-square so the order barely matters. Entries stay
# review-flagged either way — this only makes the default the likely-right one.
WIDE_CATEGORIES = {"sofa", "desk", "coffee_table", "dresser", "wardrobe",
                   "bookshelf", "tv_stand"}

# Plausible HEIGHT band (meters) per category. Sellers shuffle W/D/H template
# slots or list SEAT height as the height; a chair "22 inches tall" or a
# wardrobe "31 inches tall" is a listing error the sane-range gate can't see.
# Outside the band -> review flag (found real cases of both in the first run).
HEIGHT_PLAUSIBLE = {
    "sofa": (0.55, 1.2), "chair": (0.6, 1.2), "dining_chair": (0.7, 1.2),
    "bed": (0.15, 1.6), "desk": (0.6, 1.9), "dining_table": (0.65, 1.1),
    "coffee_table": (0.25, 0.65), "side_table": (0.3, 0.8),
    "dresser": (0.45, 1.5), "wardrobe": (1.2, 2.3), "nightstand": (0.3, 0.9),
    "bookshelf": (0.7, 2.2), "tv_stand": (0.25, 1.9),
}

# Renter-safe gate: anything requiring drilling/permanent mounting is out.
# NOTE: bare "drill" was here and got dropped — it false-positived on
# "pre-drilled holes" (a factory/assembly detail, nothing to do with drilling
# into the renter's wall). "drilling required" is the specific phrase that
# actually indicates customer-side wall drilling.
NOT_REMOVABLE_KEYWORDS = [
    "wall mount", "wall-mount", "wall mounted", "drilling required",
    "hardwired", "hard-wired", "floating shelf", "floating desk", "anchor to wall",
]
# "Anti-tip strap included" is fine (optional safety hardware) and NOT a
# disqualifier — Amazon dressers all mention it. Sellers phrase this many ways
# ("anti-tip strap", "anti-tip kit for wall mounting", "wall anchor included"),
# so the exemption has to look for "anti-tip" near the matched keyword, not
# just the one literal phrase — otherwise "wall mount" still catches the exact
# case the exemption exists for.
ANTI_TIP_CONTEXT_CHARS = 50

# Multi-unit listings ("Set of 2", "2-Pack"...) record correct PER-UNIT dims
# (Amazon's own convention), so they're not dropped -- but the gallery's main
# image nearly always shows both/all units together, which a single-object
# generator (Tripo) will fuse into one wrong mesh. Flag for a human to pick a
# single-unit gallery image instead of the default main image.
MULTI_UNIT_KEYWORDS = [
    "set of 2", "set of 3", "set of 4", "2-pack", "3-pack", "4-pack",
    "pack of 2", "pack of 3", "pack of 4", "pair of", "2 piece", "3 piece",
]


def sold_as_multiple(title: str) -> bool:
    t = title.lower()
    return any(k in t for k in MULTI_UNIT_KEYWORDS)


# --- inference helpers ----------------------------------------------------------

def srgb_to_lab(rgb255: tuple[float, float, float]) -> tuple[float, float, float]:
    """sRGB (0–255) → CIE Lab (D65). Line-for-line port of the app's
    FurnitureColorClassifier.labFromSRGB so both classifiers share one space —
    weighted RGB distance filed dark neutral greys under navy (blue weight 0.11
    made hue mismatches nearly free)."""
    def lin(c: float) -> float:
        c /= 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (lin(c) for c in rgb255)
    x = r * 0.4124 + g * 0.3576 + b * 0.1805
    y = r * 0.2126 + g * 0.7152 + b * 0.0722
    z = r * 0.0193 + g * 0.1192 + b * 0.9505

    def f(t: float) -> float:
        epsilon, kappa = 216.0 / 24389.0, 24389.0 / 27.0
        return t ** (1.0 / 3.0) if t > epsilon else (kappa * t + 16) / 116

    fx, fy, fz = f(x / 0.95047), f(y / 1.00000), f(z / 1.08883)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def infer_color(image_url: str) -> tuple[str | None, list[float] | None, str]:
    """
    Dominant product color from the Amazon hero image.

    Amazon hero shots are the product on a white background, so: downscale,
    drop near-white and near-transparent pixels, take the most common quantized
    color among what's left. Returns (colorCategory, trueColorRGB 0–1, note);
    (None, None, reason) when inference isn't possible.
    """
    try:
        from PIL import Image
    except ImportError:
        return None, None, "Pillow not installed (pip3 install Pillow)"
    try:
        with urllib.request.urlopen(image_url, timeout=30) as resp:
            img = Image.open(io.BytesIO(resp.read())).convert("RGB")
    except Exception as e:  # noqa: BLE001 — any fetch/decode failure = review flag
        return None, None, f"image fetch failed: {e}"

    img.thumbnail((96, 96))
    # Raw RGB bytes instead of Image.getdata() (deprecated, removed Pillow 14).
    raw = img.tobytes()
    pixels = list(zip(raw[0::3], raw[1::3], raw[2::3]))
    counts: dict[tuple[int, int, int], int] = {}
    for r, g, b in pixels:
        if r > 235 and g > 235 and b > 235:
            continue  # white studio background
        q = (r // 24 * 24, g // 24 * 24, b // 24 * 24)
        counts[q] = counts.get(q, 0) + 1
    if not counts:
        return None, None, "image is all-white after background removal"

    dominant = max(counts, key=counts.get)
    # Average the actual pixels in the winning bucket for a truer color than
    # the quantized corner.
    bucket = [(r, g, b) for r, g, b in pixels
              if (r // 24 * 24, g // 24 * 24, b // 24 * 24) == dominant]
    n = len(bucket)
    avg = tuple(sum(c[i] for c in bucket) / n for i in range(3))

    target_lab = srgb_to_lab(avg)

    def dist(anchor):
        # CIE Lab Euclidean — the same space and math as the app's
        # FurnitureColorClassifier, so the shipped bucket and an in-app
        # reclassification can never disagree.
        anchor_lab = srgb_to_lab(anchor)
        return sum((target_lab[i] - anchor_lab[i]) ** 2 for i in range(3))

    category = min(COLOR_ANCHORS, key=lambda k: dist(COLOR_ANCHORS[k]))
    true_rgb = [round(c / 255.0, 3) for c in avg]
    return category, true_rgb, ""


def infer_material(product: dict) -> str | None:
    text = " ".join([
        product.get("title") or "",
        " ".join(product.get("featureBullets") or []),
        " ".join(f"{s.get('name','')} {s.get('value','')}"
                 for s in product.get("technicalSpecifications") or []),
    ]).lower()
    for material, keywords in MATERIAL_KEYWORDS:
        if any(k in text for k in keywords):
            return material
    return None


def infer_removable(product: dict) -> bool:
    text = " ".join([
        product.get("title") or "",
        " ".join(product.get("featureBullets") or []),
    ]).lower()
    for kw in NOT_REMOVABLE_KEYWORDS:
        idx = text.find(kw)
        if idx == -1:
            continue
        window = text[max(0, idx - ANTI_TIP_CONTEXT_CHARS):idx + len(kw) + ANTI_TIP_CONTEXT_CHARS]
        if "anti-tip" in window or "anti tip" in window:
            continue  # optional safety strap/kit, not a permanent-mount disqualifier
        return False
    return True


def pick_archetype(category: str, dims_m: list[float], models: dict) -> tuple[str, float]:
    """Best Quaternius fallback = candidate with the smallest stretch spread."""
    best_name, best_spread = "", float("inf")
    for name in ARCHETYPE_CANDIDATES.get(category, []):
        model = models.get(name)
        if not model:
            continue
        native = model["nativeDimsWDH"]
        factors = [dims_m[i] / native[i] for i in range(3) if native[i] > 1e-6]
        spread = max(factors) / min(factors)
        if spread < best_spread:
            best_name, best_spread = name, spread
    return best_name, best_spread


# --- main ------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="P1: seed asins_draft.json from Canopy search.")
    ap.add_argument("--report", required=True,
                    help="Quaternius pipeline report.json (archetype native dims)")
    ap.add_argument("--out", required=True, help="output draft path (asins_draft.json)")
    ap.add_argument("--per-category", type=int, default=15,
                    help="ASINs looked up per category (default 15)")
    args = ap.parse_args()

    with open(args.report) as f:
        models = {m["assetName"]: m for m in json.load(f)["models"]}

    # Resume support: every kept entry is flushed to --out as it lands, and a
    # re-run skips ASINs already there — a hard API failure at item 190 of a
    # paid PAYG run costs one item, not the whole run.
    entries, dropped = [], []
    if os.path.exists(args.out):
        with open(args.out) as f:
            entries = json.load(f)
        print(f"Resuming: {len(entries)} entries already in {args.out}")
    # The same ASIN can surface in multiple category searches ("side table
    # small" and "nightstand"); duplicates would become duplicate Identifiable
    # ids in the app, so first category wins.
    seen_asins = {e["asin"] for e in entries}

    def flush() -> None:
        with open(args.out, "w") as f:
            json.dump(entries, f, indent=2)

    for category, term in CATEGORY_SEARCHES.items():
        print(f"== {category}: searching '{term}' ...")
        try:
            asins = search_asins(term, args.per_category)
        except CanopyError as err:
            print(f"   SEARCH FAILED for '{category}': {err} — category skipped, "
                  f"re-run to fill it in", file=sys.stderr)
            dropped.append(("(search)", category, f"search failed: {err}"[:160]))
            continue
        print(f"   {len(asins)} ASINs")
        for asin in asins:
            if asin in seen_asins:
                continue
            seen_asins.add(asin)
            # Only rate-limit when we're about to hit the network; a cache hit
            # (re-run of a prior paid run) shouldn't pay the 0.4s politeness tax.
            if not os.path.exists(os.path.join(RAW_CACHE_DIR, f"{asin}.json")):
                time.sleep(0.4)  # stay polite on Canopy PAYG
            try:
                p = cached_lookup(asin)
            except CanopyError as err:
                dropped.append((asin, category, f"lookup failed: {err}"[:160]))
                continue
            if not p:
                dropped.append((asin, category, "lookup failed"))
                continue

            dims = extract_dims(p)
            if not dims["dims_m"]:
                # Package-only or no dims: would lie in the fit check. Drop, never ship.
                dropped.append((asin, category, f"no assembled dims ({dims['source']})"))
                continue
            review_reasons: list[str] = []
            if category in WIDE_CATEGORIES:
                # The long span belongs left-right on wide furniture. Sellers
                # routinely paste W/D into the wrong template slots (real
                # listings like a '70"D x 15.8"W' TV stand — physically absurd),
                # so we swap when depth exceeds width even on axis-LABELED
                # listings. But overriding an EXPLICIT label is a guess, not a
                # correction, so a labeled swap is flagged for the human review
                # pass rather than trusted silently.
                w, d, h = dims["dims_m"]
                if d > w:
                    dims["dims_m"] = [d, w, h]
                    if dims["axis_labeled"]:
                        review_reasons.append(
                            f"swapped W/D on a LABELED wide item (label read "
                            f"D>W: {round(d, 3)}×{round(w, 3)}m) — confirm it "
                            f"isn't legitimately deeper than wide")

            cents, currency = price_cents(p)
            rating, ratings_total, reviews_total = ratings(p)
            color_cat, true_rgb, color_note = infer_color(p.get("mainImageUrl") or "")
            material = infer_material(p)

            if not dims["axis_labeled"]:
                review_reasons.append("dims had no W/D/H axis letters — verify order")
            if color_cat is None:
                review_reasons.append(f"color inference failed: {color_note}")
            if material is None:
                review_reasons.append("material not inferable from listing text")
            if cents is None:
                review_reasons.append("no price on listing")
            if sold_as_multiple(p.get("title") or ""):
                review_reasons.append(
                    "sold as a multi-unit set — main image likely shows multiple "
                    "units together; pick a single-unit gallery image for Tripo")
            # Sanity: furniture between 10 cm and 4 m per axis.
            if any(not (0.10 <= d <= 4.0) for d in dims["dims_m"]):
                review_reasons.append(f"dims out of sane furniture range: {dims['dims_m']}")
            lo_h, hi_h = HEIGHT_PLAUSIBLE.get(category, (0.1, 4.0))
            if not (lo_h <= dims["dims_m"][2] <= hi_h):
                review_reasons.append(
                    f"height {dims['dims_m'][2]}m implausible for {category} "
                    f"(expect {lo_h}-{hi_h}m) — seat height or shuffled W/D/H slots?")

            archetype, spread = pick_archetype(category, dims["dims_m"], models)
            if not archetype:
                review_reasons.append("no archetype candidate found for category")

            entries.append({
                "asin": asin,
                "category": category,
                "title": (p.get("title") or "")[:120],
                "brand": p.get("brand") or "Amazon Seller",
                "priceCents": cents if cents is not None else 0,
                "currencyCode": currency,
                "dimensionsMeters": dims["dims_m"],
                "rawDims": dims["raw"],
                "colorCategory": color_cat or "other",
                "trueColorRGB": true_rgb or [0.54, 0.52, 0.49],
                "material": material or "other",
                "isRemovable": infer_removable(p),
                "mainImageUrl": p.get("mainImageUrl") or "",
                "imageUrls": p.get("imageUrls") or [],
                "rating": rating,
                "ratingsTotal": ratings_total,
                "reviewsTotal": reviews_total,
                "productURL": p.get("url") or f"https://www.amazon.com/dp/{asin}",
                "archetype": archetype,
                "archetypeSpread": round(spread, 2) if archetype else None,
                "_review": bool(review_reasons),
                "_reviewReasons": review_reasons,
            })
            flush()   # checkpoint: a later hard failure can't discard this entry
            flag = "REVIEW" if review_reasons else "ok"
            print(f"   {asin}  {flag:<7} {entries[-1]['title'][:48]}")

    flush()
    total = len(entries)
    review = sum(1 for e in entries if e["_review"])
    print(f"\n== seed summary ==")
    print(f"  kept:    {total}  ({review} flagged _review — "
          f"{round(100 * review / total) if total else 0}%)")
    print(f"  dropped: {len(dropped)} (no assembled dims / lookup fail — never shipped)")
    for asin, cat, why in dropped:
        print(f"    {asin} ({cat}): {why}")
    print(f"\nWrote {args.out}")
    print("Next: review the _review:true entries, save as asins.json, then run generate_3d.py")


if __name__ == "__main__":
    main()
