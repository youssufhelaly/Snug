#!/usr/bin/env python3
"""
P0 SPIKE — Amazon assembled-dimension coverage check (via Canopy API free tier).

WHY THIS EXISTS
    The Amazon-catalog pivot (see FounderPivot.md "Execution Plan") bets the whole
    product on one thing: that Amazon listings reliably expose *assembled* furniture
    dimensions we can trust for the honest fit check. Snug's entire premise is
    "accurate geometry / honest fit" — if the dims are missing or are the shipping
    BOX size instead of the set-up piece, the fit check lies and the premise collapses.

    So before we build any backend, this spike answers exactly one question:
        "For real furniture ASINs, how often do we get usable ASSEMBLED dimensions
         (not package dims), and how many clean image angles come back for 3D?"

    Nothing here ships in the app. It's a throwaway de-risking probe. If coverage is
    good -> proceed to P1 (ingest backend). If it's bad -> the pivot needs rethinking.

WHAT IT DOES
    1. Uses Canopy's Amazon *search* to self-seed real ASINs per furniture category
       (sofa, bed frame, desk, ...), so we test live listings, not hardcoded guesses.
    2. Looks up each ASIN and pulls dimension-bearing fields + image URLs.
    3. Heuristically classifies dimensions as ASSEMBLED/ITEM vs PACKAGE/SHIPPING and
       reports, per product, whether we got usable assembled dims + image-angle count.
    4. Prints a coverage verdict and writes spike_report.json.

SCHEMA NOTE (important)
    Canopy is GraphQL. Field names below are from Canopy's public docs, but blog/docs
    examples drift from the live schema. DO NOT trust the parse until you've run:

        CANOPY_API_KEY=... python3 spike_amazon_dims.py --introspect

    That dumps the live AmazonProduct type's real fields. Fix FIELDS below if they
    differ, then run for real. `--raw <ASIN>` pretty-prints one full product so you
    can see exactly where assembled dims actually live.

USAGE
    export CANOPY_API_KEY=...           # free tier: 100 req/mo, canopyapi.co
    python3 spike_amazon_dims.py --introspect          # 1. confirm live schema
    python3 spike_amazon_dims.py --raw B08XXXXXXX      # 2. eyeball one product
    python3 spike_amazon_dims.py                       # 3. run the coverage spike
    python3 spike_amazon_dims.py --asins B08.. B09..   # or test specific ASINs

    Budget: default run is ~ (#categories) search calls + (#categories * PER_CATEGORY)
    lookups. With defaults that's ~9 + 18 = 27 calls, well under the 100/mo free tier.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

# --- config ------------------------------------------------------------------

ENDPOINT = "https://graphql.canopyapi.co/"
DOMAIN = "US"  # AmazonDomain enum value

# Furniture categories mirroring Snug's catalog spine. Two ASINs each keeps the
# free-tier budget tiny while still sampling every shape class the fit check covers.
SEARCH_TERMS = [
    "sofa couch",
    "bed frame queen",
    "computer desk",
    "bookshelf 5 shelf",
    "nightstand",
    "coffee table",
    "office chair",
    "dresser drawer",
    "wardrobe closet",
]
PER_CATEGORY = 2  # ASINs looked up per search term

# Real fields, confirmed via `--introspect AmazonProduct` against the live schema.
# There is NO top-level `dimensions` field — furniture dims live inside
# `technicalSpecifications` as name/value pairs ("Product Dimensions",
# "Package Dimensions", "Item Dimensions"), which lets us classify assembled-vs-
# package by the spec NAME rather than guessing from a blob.
PRODUCT_FIELDS = """
    asin
    title
    brand
    mainImageUrl
    imageUrls
    itemWeight
    packageWeight
    featureBullets
    technicalSpecifications { name value }
"""

# Keywords that mark a dimension blob as the shipping BOX, not the assembled piece.
PACKAGE_HINTS = ("package", "shipping", "carton", "box dimension", "parcel")
ASSEMBLED_HINTS = ("assembled", "item dimension", "product dimension", "overall", "set up", "set-up")

# Matches "80"D x 32"W x 34"H", "200 x 90 x 100 cm", "34.5 inches", etc.
DIM_TRIPLE_RE = re.compile(
    r"(\d+(?:\.\d+)?)\s*[\"']?\s*[a-zA-Z]?\s*[x×X]\s*"
    r"(\d+(?:\.\d+)?)\s*[\"']?\s*[a-zA-Z]?\s*[x×X]\s*"
    r"(\d+(?:\.\d+)?)"
)
# Unit detection: matches the inch abbreviation " (quote/double-prime), or spelled-out units.
UNIT_RE = re.compile(r'("|\'\'|\b(inch|inches|in\b|cm|centimet|mm|millimet|feet|foot|ft)\b)', re.I)


# --- graphql plumbing --------------------------------------------------------

def _api_key() -> str:
    key = os.environ.get("CANOPY_API_KEY", "").strip()
    if not key:
        sys.exit("ERROR: set CANOPY_API_KEY (free tier at https://www.canopyapi.co/).")
    return key


def gql(query: str, variables: dict | None = None) -> dict:
    """POST a GraphQL query. Prints full errors so schema drift is obvious, not silent."""
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {_api_key()}",
            # Cloudflare fronts Canopy and 403s (error 1010) the default
            # "Python-urllib/x" agent. A browser-like UA + Accept get past it.
            "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                           "AppleWebKit/537.36 (KHTML, like Gecko) "
                           "Chrome/124.0 Safari/537.36"),
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} from Canopy: {e.read().decode(errors='replace')[:800]}")
    except urllib.error.URLError as e:
        sys.exit(f"Network error reaching Canopy: {e}")
    if payload.get("errors"):
        # Most common cause: a field name below is wrong for the live schema.
        print("GraphQL errors (check field names in this script against --introspect):",
              file=sys.stderr)
        print(json.dumps(payload["errors"], indent=2), file=sys.stderr)
    return payload.get("data") or {}


# --- schema discovery --------------------------------------------------------

def introspect(type_name: str = "AmazonProduct") -> None:
    """Dump a live type's fields so we fix the parse against truth.
    Use `Query` to see top-level queries (e.g. the search field name)."""
    q = """
    query IntrospectType($name: String!) {
      __type(name: $name) {
        name
        fields { name type { name kind ofType { name kind } } }
      }
    }
    """
    data = gql(q, {"name": type_name})
    t = data.get("__type")
    if not t:
        print(f"Could not introspect '{type_name}' — the type name may differ. "
              "Open the playground at https://graphql.canopyapi.co/ and check the Docs panel.")
        return
    print(f"{t['name']} fields ({len(t['fields'])}):")
    for f in t["fields"]:
        ty = f["type"]
        name = ty.get("name") or (ty.get("ofType") or {}).get("name") or ty.get("kind")
        print(f"  {f['name']:<28} {name}")


# --- queries -----------------------------------------------------------------

def search_asins(term: str, limit: int) -> list[str]:
    """Return up to `limit` ASINs for a search term."""
    q = f"""
    query Search($term: String!) {{
      amazonProductSearchResults(input: {{ searchTerm: $term, domain: {DOMAIN} }}) {{
        productResults {{ results {{ asin }} }}
      }}
    }}
    """
    data = gql(q, {"term": term})
    node = (data.get("amazonProductSearchResults") or {}).get("productResults") or {}
    results = node.get("results") or []
    asins = [r["asin"] for r in results if r.get("asin")]
    return asins[:limit]


def lookup(asin: str) -> dict:
    q = f"""
    query GetProduct($asin: String!) {{
      amazonProduct(input: {{ asinLookup: {{ asin: $asin, domain: {DOMAIN} }} }}) {{
        {PRODUCT_FIELDS}
      }}
    }}
    """
    return gql(q, {"asin": asin}).get("amazonProduct") or {}


# --- dimension analysis ------------------------------------------------------

def _stringify(val) -> str:
    """Flatten any value to clean text. Structured dims (dict/list) become
    "key: value" pairs WITHOUT JSON escaping — escaped quotes (\\") would break
    the triple regex on inch marks."""
    if val is None:
        return ""
    if isinstance(val, str):
        return val
    if isinstance(val, dict):
        return "; ".join(f"{k}: {_stringify(v)}" for k, v in val.items())
    if isinstance(val, list):
        return "; ".join(_stringify(v) for v in val)
    return str(val)


def _triple(text: str):
    m = DIM_TRIPLE_RE.search(text)
    return [float(m.group(1)), float(m.group(2)), float(m.group(3))] if m else None


def analyze_dims(product: dict) -> dict:
    """
    Classify the dimension signal from technicalSpecifications name/value pairs.
    The assembled-vs-package distinction is the crux of P0, and here it's driven by
    the spec NAME (e.g. "Item Dimensions" vs "Package Dimensions") — far more reliable
    than regexing a free-text blob. featureBullets is a last-resort fallback.
    Returns: { assembled, package_only, triple, unit_present, source_field, raw }
    """
    specs = product.get("technicalSpecifications") or []
    assembled_val = ""   # value string from an assembled/item/product-dimensions spec
    package_val = ""     # value string from a package/shipping-dimensions spec

    for spec in specs:
        name = (spec.get("name") or "").lower()
        value = spec.get("value") or ""
        if "dimension" not in name and "size" not in name:
            continue
        if not _triple(value):
            continue
        if any(h in name for h in PACKAGE_HINTS):
            package_val = package_val or value
        elif any(h in name for h in ASSEMBLED_HINTS):
            assembled_val = assembled_val or value
        else:
            # A bare "Dimensions" spec with no package/assembled qualifier —
            # treat as assembled (Amazon's "Product Dimensions" is the set-up size).
            assembled_val = assembled_val or value

    # Fallback: scan featureBullets for an assembled-tagged triple.
    if not assembled_val:
        bullets = _stringify(product.get("featureBullets"))
        for line in re.split(r"[;\n]", bullets):
            if any(h in line.lower() for h in ASSEMBLED_HINTS) and _triple(line):
                assembled_val = line.strip()
                break

    chosen = assembled_val or package_val
    triple = _triple(chosen)
    return {
        "assembled": bool(assembled_val) and triple is not None,
        "package_only": bool(package_val) and not assembled_val,
        "triple": triple,
        "unit_present": bool(UNIT_RE.search(chosen)),
        "source_field": "assembled" if assembled_val else ("package" if package_val else "none"),
        "raw": chosen[:160],
    }


def image_count(product: dict) -> int:
    urls = product.get("imageUrls")
    if isinstance(urls, list):
        return len(urls)
    if isinstance(urls, str) and urls:
        return 1
    return 1 if product.get("mainImageUrl") else 0


# --- run ---------------------------------------------------------------------

def run(asins: list[str] | None) -> None:
    if not asins:
        print("Seeding ASINs via Canopy search per category...\n")
        asins = []
        for term in SEARCH_TERMS:
            found = search_asins(term, PER_CATEGORY)
            print(f"  {term:<22} -> {found or '(none — check search schema)'}")
            asins.extend(found)
        print()
    asins = list(dict.fromkeys(asins))  # de-dupe, preserve order
    if not asins:
        sys.exit("No ASINs to test. Fix search fields (--introspect) or pass --asins.")

    rows = []
    print(f"Looking up {len(asins)} products...\n")
    for asin in asins:
        p = lookup(asin)
        if not p:
            rows.append({"asin": asin, "title": "(lookup failed)", "usable": False})
            continue
        dims = analyze_dims(p)
        imgs = image_count(p)
        usable = dims["assembled"] and dims["unit_present"]
        rows.append({
            "asin": asin,
            "title": (p.get("title") or "")[:52],
            "usable_assembled_dims": usable,
            "dim_source": dims["source_field"],
            "package_only": dims["package_only"],
            "triple": dims["triple"],
            "image_angles": imgs,
            "raw_dims": dims["raw"],
        })

    # Report table
    print(f"{'ASIN':<12} {'DIMS':<6} {'SRC':<10} {'IMGS':<5} TITLE")
    print("-" * 88)
    for r in rows:
        flag = "OK" if r.get("usable_assembled_dims") else ("PKG" if r.get("package_only") else "--")
        print(f"{r['asin']:<12} {flag:<6} {r.get('dim_source',''):<10} "
              f"{str(r.get('image_angles','')):<5} {r.get('title','')}")

    # Verdict
    total = len(rows)
    ok = sum(1 for r in rows if r.get("usable_assembled_dims"))
    pkg = sum(1 for r in rows if r.get("package_only"))
    avg_imgs = round(sum(r.get("image_angles", 0) for r in rows) / total, 1) if total else 0
    print("\n=== P0 VERDICT ===")
    print(f"  Usable assembled dims : {ok}/{total} ({round(100*ok/total)}%)")
    print(f"  Package-dims-only      : {pkg}/{total}  (these would LIE in the fit check)")
    print(f"  Avg image angles       : {avg_imgs}  (3D input quality proxy)")
    if total:
        if ok / total >= 0.8:
            print("  -> GREEN: dimension coverage supports the honest fit check. Proceed to P1.")
        elif ok / total >= 0.5:
            print("  -> YELLOW: partial coverage. Viable only if we HIDE package-only SKUs and")
            print("     source dims from a second provider for the gaps.")
        else:
            print("  -> RED: coverage too thin. Amazon dims alone can't back the fit promise.")
            print("     Rethink: manufacturer feeds, a dims-specialized provider, or manual curation.")

    with open("spike_report.json", "w") as f:
        json.dump({"products": rows}, f, indent=2)
    print("\nWrote spike_report.json")


def main() -> None:
    ap = argparse.ArgumentParser(description="P0: Amazon assembled-dimension coverage spike (Canopy).")
    ap.add_argument("--introspect", nargs="?", const="AmazonProduct", metavar="TYPE",
                    help="Dump a live schema type's fields (default AmazonProduct; try 'Query').")
    ap.add_argument("--raw", metavar="ASIN", help="Fetch one product and pretty-print the full JSON.")
    ap.add_argument("--asins", nargs="+", metavar="ASIN", help="Test specific ASINs instead of search-seeding.")
    args = ap.parse_args()

    if args.introspect:
        introspect(args.introspect)
    elif args.raw:
        print(json.dumps(lookup(args.raw), indent=2))
    else:
        run(args.asins)


if __name__ == "__main__":
    main()
