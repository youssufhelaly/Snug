#!/usr/bin/env python3
"""
Shared Canopy API (GraphQL) plumbing for the Amazon catalog pipeline.

Extracted from the P0 spike (spike_amazon_dims.py) so seed_catalog.py and
ingest_amazon.py share one tested transport + dimension parser instead of three
drifting copies. The spike stays untouched as the historical de-risking record.

SCHEMA NOTE
    Canopy is GraphQL and their docs drift from the live schema. If a query here
    starts erroring, run the spike's introspection first:

        CANOPY_API_KEY=... python3 spike_amazon_dims.py --introspect
        CANOPY_API_KEY=... python3 spike_amazon_dims.py --introspect Query

    and fix PRODUCT_FIELDS / query shapes here against truth.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "https://graphql.canopyapi.co/"
DOMAIN = "US"  # AmazonDomain enum value

# Every lookup() writes its full raw product node here, keyed by ASIN, the
# moment it lands — regardless of which fields we parse today. Canopy is paid
# PAYG, so a field we didn't think we'd need (galleries, bullets, specs,
# rating/reviews once added) is on disk forever and never costs a second call.
# Anchored to this file's dir so the cache is stable no matter the caller's cwd.
RAW_CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw_cache")


class CanopyError(RuntimeError):
    """A Canopy call failed after retries (HTTP/network) or returned
    GraphQL-level errors. Raised — never sys.exit — so callers can catch it
    per-ASIN and checkpoint: one Cloudflare 403 at item 190 of a paid PAYG run
    must not discard everything fetched so far."""

# Real fields confirmed via --introspect against the live schema during P0,
# plus price/url used by P1. There is NO top-level `dimensions` field —
# dims live in `technicalSpecifications` as name/value pairs.
PRODUCT_FIELDS = """
    asin
    title
    brand
    url
    mainImageUrl
    imageUrls
    price { display value currency }
    featureBullets
    rating
    ratingsTotal
    reviewsTotal
    technicalSpecifications { name value }
"""

PACKAGE_HINTS = ("package", "shipping", "carton", "box dimension", "parcel")
ASSEMBLED_HINTS = ("assembled", "item dimension", "product dimension", "overall",
                   "set up", "set-up")

# Matches dimension triples with optional per-number axis letters, e.g.
#   31.5"D x 72.8"W x 28.7"H     200 x 90 x 100 cm     30L x 20W x 40H inches
_NUM = r"(\d+(?:\.\d+)?)"
_AXIS = r"\s*[\"']?\s*([DdWwHhLl])?"
DIM_TRIPLE_RE = re.compile(
    rf"{_NUM}{_AXIS}\s*[x×X]\s*{_NUM}{_AXIS}\s*[x×X]\s*{_NUM}{_AXIS}"
)
INCH_RE = re.compile(r'("|\'\'|\b(inch|inches|in)\b)', re.I)
CM_RE = re.compile(r"\b(cm|centimet)", re.I)


def _api_key() -> str:
    key = os.environ.get("CANOPY_API_KEY", "").strip()
    if not key:
        sys.exit("ERROR: set CANOPY_API_KEY (https://www.canopyapi.co/).")
    return key


def gql(query: str, variables: dict | None = None, retries: int = 2) -> dict:
    """
    POST a GraphQL query. Prints full errors so schema drift is loud, and
    raises `CanopyError` on any hard failure (after retries) or GraphQL-level
    errors — so "no results" and "broken query/transport" are distinguishable
    to callers.
    """
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {_api_key()}",
            # Cloudflare fronts Canopy and 403s the default urllib agent.
            "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                           "AppleWebKit/537.36 (KHTML, like Gecko) "
                           "Chrome/124.0 Safari/537.36"),
            "Accept": "application/json",
        },
        method="POST",
    )
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                payload = json.loads(resp.read().decode())
            break
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:400]
            if e.code in (429, 500, 502, 503) and attempt < retries:
                wait = 3 * (attempt + 1)
                print(f"  HTTP {e.code} from Canopy, retrying in {wait}s...", file=sys.stderr)
                time.sleep(wait)
                continue
            raise CanopyError(f"HTTP {e.code} from Canopy: {detail}") from e
        except urllib.error.URLError as e:
            if attempt < retries:
                time.sleep(3)
                continue
            raise CanopyError(f"Network error reaching Canopy: {e}") from e
    if payload.get("errors"):
        print("GraphQL errors (check field names against spike --introspect):",
              file=sys.stderr)
        print(json.dumps(payload["errors"], indent=2), file=sys.stderr)
        raise CanopyError(f"GraphQL errors: {json.dumps(payload['errors'])[:300]}")
    return payload.get("data") or {}


def search_asins(term: str, limit: int) -> list[str]:
    """Return up to `limit` ASINs for an Amazon search term."""
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
    return [r["asin"] for r in results if r.get("asin")][:limit]


def _raw_cache_path(asin: str) -> str:
    return os.path.join(RAW_CACHE_DIR, f"{asin}.json")


def lookup(asin: str) -> dict:
    """
    Fetch a product from Canopy AND write its full raw node to
    raw_cache/<asin>.json before returning. The write happens here (not in the
    caller) so every code path that looks up an ASIN — seed, ingest, ad-hoc —
    populates the cache uniformly. A failed lookup writes nothing.
    """
    q = f"""
    query GetProduct($asin: String!) {{
      amazonProduct(input: {{ asinLookup: {{ asin: $asin, domain: {DOMAIN} }} }}) {{
        {PRODUCT_FIELDS}
      }}
    }}
    """
    product = gql(q, {"asin": asin}).get("amazonProduct") or {}
    if product:
        os.makedirs(RAW_CACHE_DIR, exist_ok=True)
        with open(_raw_cache_path(asin), "w") as f:
            json.dump(product, f, indent=2)
    return product


def cached_lookup(asin: str) -> dict:
    """
    Return the raw product from raw_cache/<asin>.json if present, else call
    lookup() (which fetches AND caches). Lets a re-run of a paid PAYG job skip
    the network entirely for ASINs already fetched — independent of whether the
    ASIN survived into a kept catalog entry. A corrupt/empty cache file falls
    through to a live lookup rather than poisoning the run.
    """
    path = _raw_cache_path(asin)
    if os.path.exists(path):
        try:
            with open(path) as f:
                cached = json.load(f)
            if cached:
                return cached
        except (json.JSONDecodeError, OSError):
            pass  # unreadable cache -> refetch below
    return lookup(asin)


# --- dimension parsing --------------------------------------------------------

def _unit_factor(text: str, m: re.Match) -> float:
    """
    Meters-per-unit for the SPECIFIC matched triple, judged from the matched
    text plus a short trailing window — never the whole string. Dual-unit
    listings like '72"W x 30"D x 28"H (183 x 76 x 71 cm)' contain both units;
    converting the inch triple with the cm factor would ship a 1.83 m sofa as
    0.72 m and sail through the sanity gate (CLAUDE.md: no fake dimensions).
    """
    trailing = text[m.end():m.end() + 16]
    for candidate in (m.group(0), trailing):
        cm = CM_RE.search(candidate)
        inch = INCH_RE.search(candidate)
        if cm and inch:  # both in one window: the one nearest the numbers wins
            return 0.01 if cm.start() < inch.start() else 0.0254
        if cm:
            return 0.01
        if inch:
            return 0.0254
    # Unitless: US furniture listings are overwhelmingly inches; values in
    # meters would be absurd (a 72 "meter" desk). Caller flags for review.
    return 0.0254

def parse_dims_meters(text: str) -> tuple[list[float] | None, bool]:
    """
    Parse a dimension string into app-order [width, depth, height] in METERS.

    Returns (dims, axis_labeled). `axis_labeled` is True when the listing carried
    explicit per-number axis letters (31.5"D x 72.8"W x 28.7"H) — the trustworthy
    case. Without letters we assume Amazon's conventional L x W x H order
    (length == depth) and the caller should flag the entry for human review.
    """
    m = DIM_TRIPLE_RE.search(text)
    if not m:
        return None, False
    nums = [float(m.group(i)) for i in (1, 3, 5)]
    letters = [(m.group(i) or "").upper() for i in (2, 4, 6)]
    to_m = _unit_factor(text, m)

    axis_labeled = all(letters) and len(set(letters)) == 3 and "H" in letters
    if axis_labeled:
        w = d = h = None
        for val, letter in zip(nums, letters):
            if letter == "W":
                w = val
            elif letter == "H":
                h = val
            elif letter == "D":
                d = val
        # "L" is Amazon's depth by convention — unless "D" already claimed it,
        # in which case L is the remaining horizontal span, i.e. width
        # (69"L x 17.7"H x 15.7"D on a TV stand).
        for val, letter in zip(nums, letters):
            if letter == "L":
                if d is None:
                    d = val
                else:
                    w = val
        if None in (w, d, h):
            axis_labeled = False
    if not axis_labeled:
        # Amazon's bare "Product Dimensions" convention is L x W x H.
        d, w, h = nums[0], nums[1], nums[2]

    return [round(w * to_m, 4), round(d * to_m, 4), round(h * to_m, 4)], axis_labeled


def extract_dims(product: dict) -> dict:
    """
    Pull the best ASSEMBLED dimension string from a Canopy product, using spec
    NAMES to separate assembled vs package dims (the P0-proven approach).

    Returns { dims_m, axis_labeled, source, raw } — dims_m is None when only
    package dims (or nothing) exist; those SKUs must not ship (they'd lie in
    the fit check).
    """
    specs = product.get("technicalSpecifications") or []
    assembled_val, package_val = "", ""

    for spec in specs:
        name = (spec.get("name") or "").lower()
        value = spec.get("value") or ""
        if "dimension" not in name and "size" not in name:
            continue
        if not DIM_TRIPLE_RE.search(value):
            continue
        if any(h in name for h in PACKAGE_HINTS):
            package_val = package_val or value
        elif any(h in name for h in ASSEMBLED_HINTS):
            assembled_val = assembled_val or value
        else:
            # Bare "Dimensions" with no qualifier — Amazon's "Product
            # Dimensions" is the set-up size, so treat as assembled.
            assembled_val = assembled_val or value

    if not assembled_val:
        bullets = product.get("featureBullets") or []
        if isinstance(bullets, str):
            bullets = re.split(r"[;\n]", bullets)
        for line in bullets:
            if any(h in line.lower() for h in ASSEMBLED_HINTS) and DIM_TRIPLE_RE.search(line):
                assembled_val = line.strip()
                break

    if not assembled_val:
        return {"dims_m": None, "axis_labeled": False,
                "source": "package" if package_val else "none",
                "raw": (package_val or "")[:160]}

    dims_m, axis_labeled = parse_dims_meters(assembled_val)
    return {"dims_m": dims_m, "axis_labeled": axis_labeled,
            "source": "assembled", "raw": assembled_val[:160]}


def ratings(product: dict) -> tuple[float | None, int | None, int | None]:
    """
    Extract (rating, ratingsTotal, reviewsTotal) from a Canopy product.

    Field names confirmed via `spike_amazon_dims.py --introspect AmazonProduct`:
    `rating` is a Float (0–5 stars); `ratingsTotal`/`reviewsTotal` are GraphQL
    BigInt — which arrives as either a JSON number or a numeric string depending
    on magnitude, so both are coerced defensively. `ratingsTotal` is the count
    shown next to the stars on Amazon; `reviewsTotal` is written reviews only.
    """
    def _as_int(v):
        if v is None:
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    rating = product.get("rating")
    rating = float(rating) if isinstance(rating, (int, float)) else None
    return rating, _as_int(product.get("ratingsTotal")), _as_int(product.get("reviewsTotal"))


def price_cents(product: dict) -> tuple[int | None, str]:
    """Extract (priceCents, currencyCode) from Canopy's price object."""
    price = product.get("price") or {}
    value = price.get("value")
    if value is None:
        display = price.get("display") or ""
        m = re.search(r"(\d+(?:,\d{3})*(?:\.\d+)?)", display)
        if not m:
            return None, "USD"
        value = float(m.group(1).replace(",", ""))
    return int(round(float(value) * 100)), (price.get("currency") or "USD")
