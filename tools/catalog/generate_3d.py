#!/usr/bin/env python3
"""
P1 STEP 2 — Generate a 3D mesh per Amazon product from its hero photo (Tripo API).

Two-phase tool, because the aspect-ratio verdict needs bbox data that only
exists AFTER build_catalog.sh has converted the GLBs:

  PHASE A (default)   asins.json -> images_cache/<asin>.jpg -> Tripo image-to-3D
                      -> out-tripo/<ASIN>.glb  (idempotent: skips existing GLBs)

  PHASE B (--finalize)  reads build_catalog.sh's usdz report, checks each Tripo
                      mesh's stretch spread against the product's REAL dims
                      (same 1.15x tolerance as validate_assignments.py), then:
                        pass -> copy usdz into the app bundle, modelAssetName = tripo_<ASIN>
                        fail -> fall back to the product's Quaternius archetype
                      and writes generate_report.json for ingest_amazon.py.
                      Every product always ends with a valid model; no
                      unreviewed bad mesh ever reaches the app.

USAGE
    export TRIPO_API_KEY=...

    # Pilot: first N ASINs (one per category comes first in asins.json order)
    python3 generate_3d.py --asins asins.json --limit 10 --out-dir out-tripo/

    # Full run (idempotent — already-downloaded GLBs are skipped)
    python3 generate_3d.py --asins asins.json --out-dir out-tripo/

    # Convert:  ./build_catalog.sh out-tripo/ out-tripo-usdz/ tripo

    # Validate + copy passing USDZs + write the outcome report:
    python3 generate_3d.py --asins asins.json --out-dir out-tripo/ --finalize \
        --usdz-report out-tripo-usdz/report.json \
        --usdz-dir out-tripo-usdz/ \
        --models-dir ../../Snug/Resources/Models \
        --report out-tripo/generate_report.json

COST  ~$0.40/model. Pilot of 10 ≈ $4; full 160 ≈ $64 (one-time; re-runs skip
      existing GLBs so iterating is free).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request

TRIPO_ENDPOINT = "https://api.tripo3d.ai/v2/openapi/task"
# Pinned Tripo model version. multiview_to_model REJECTS a task with no
# model_version (HTTP 400 code 1004); image_to_model tolerates its absence but
# we pin both for reproducible meshes. Bump deliberately, not silently.
TRIPO_MODEL_VERSION = "v3.1-20260211"
POLL_INTERVAL_S = 8
POLL_TIMEOUT_S = 600
SPREAD_TOLERANCE = 1.15  # legacy full-3-axis guardrail (validate_assignments.py)
# Footprint-primary gate: width×depth is what the fit check cares about; height
# is cosmetic (top-clutter like a monitor/speaker only inflates height). We match
# the footprint and let height scale proportionally, so a clean-footprint mesh is
# usable even when Tripo added stuff on top. Looser than the 3-axis gate on
# purpose — a mild in-plane stretch is invisible; only reject genuine taffy.
# Bumped 1.25->1.4 2026-07-03 after rendering forced-fit comparisons at 1.29x/
# 1.37x spread (both, once viewed from the correct un-rotated camera angle,
# read as visually fine in normal 3/4 views) — user decision to prefer a real
# mesh over an archetype box for these near-miss cases.
FOOTPRINT_TOLERANCE = 1.4


def _api_key() -> str:
    key = os.environ.get("TRIPO_API_KEY", "").strip()
    if not key:
        sys.exit("ERROR: set TRIPO_API_KEY (https://platform.tripo3d.ai/).")
    return key


def _tripo(method: str, url: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {_api_key()}",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Tripo HTTP {e.code}: {e.read().decode(errors='replace')[:400]}") from e
    if payload.get("code") not in (0, None):
        raise RuntimeError(f"Tripo API error: {json.dumps(payload)[:400]}")
    return payload.get("data") or {}


def _download(url: str, path: str, timeout: int) -> None:
    """Download to `<path>.part` then rename. The `os.path.exists` skip logic
    treats any present file as complete, so an interrupted write must never
    leave a truncated file at the final path (it would poison the cache and
    flow a corrupt mesh into USDZ conversion)."""
    part = path + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(part, "wb") as f:
        f.write(resp.read())
    os.replace(part, path)


def _tasks_path(out_dir: str) -> str:
    return os.path.join(out_dir, "tripo_tasks.json")


def _load_tasks(out_dir: str) -> dict:
    """asin -> in-flight Tripo task_id, persisted so an interrupted run resumes
    polling the PAID task instead of submitting (and paying for) a new one."""
    try:
        with open(_tasks_path(out_dir)) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_tasks(out_dir: str, tasks: dict) -> None:
    with open(_tasks_path(out_dir), "w") as f:
        json.dump(tasks, f, indent=2)


def _versions_path(out_dir: str) -> str:
    return os.path.join(out_dir, "model_versions.json")


def _record_model_version(out_dir: str, asin: str, version: str) -> None:
    """asin -> Tripo model_version used to generate its GLB. TRIPO_MODEL_VERSION
    gets bumped over time (deliberately, see its definition), so without this a
    mix-version batch is indistinguishable after the fact — this is the paper
    trail for "was this mesh made with the old or new model"."""
    path = _versions_path(out_dir)
    try:
        with open(path) as f:
            versions = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        versions = {}
    versions[asin] = version
    with open(path, "w") as f:
        json.dump(versions, f, indent=2)


def cache_image(asin: str, url: str, cache_dir: str) -> str:
    """Download the Amazon hero image once; re-runs hit the cache."""
    os.makedirs(cache_dir, exist_ok=True)
    path = os.path.join(cache_dir, f"{asin}.jpg")
    if os.path.exists(path):
        return path
    _download(url, path, timeout=30)
    return path


def _tripo_payload(image_urls: list[str]) -> dict:
    """
    Build the task body. One URL -> image_to_model; several -> multiview_to_model
    with files ordered front, left, back, right (front mandatory, per Tripo docs).
    Amazon galleries rarely give a clean 4-view set, so callers pass whatever
    clean angles exist (usually 1-2) and the mesh quality reflects that.
    """
    if len(image_urls) == 1:
        return {"type": "image_to_model", "model_version": TRIPO_MODEL_VERSION,
                "file": {"type": "jpg", "url": image_urls[0]}}
    # Multiview wants 4 FIXED positional slots — front, left, back, right —
    # with an empty {} for any view we don't have (front is mandatory). A short
    # array (e.g. just [front,left]) is rejected HTTP 400. Matches the official
    # SDK, which passes [front, None, back, None] and maps None -> {}.
    slots = [{} for _ in range(4)]
    for i, u in enumerate(image_urls[:4]):
        slots[i] = {"type": "jpg", "url": u}
    return {"type": "multiview_to_model", "model_version": TRIPO_MODEL_VERSION,
            "files": slots}


def generate_glb(asin: str, image_urls: list[str], out_dir: str) -> str:
    """
    Run one image->3D (or multiview->3D) task and download the resulting GLB.

    Passes the (public) Amazon image URLs straight to Tripo — no upload dance.
    If Tripo's schema drifts (task shape / output field names), the raw payload
    is in the raised error; fix the field paths here against their live docs.
    """
    glb_path = os.path.join(out_dir, f"{asin}.glb")
    if os.path.exists(glb_path):
        print(f"  {asin}  cached GLB, skipping")
        return glb_path

    _record_model_version(out_dir, asin, TRIPO_MODEL_VERSION)

    # Resume an in-flight paid task from a prior interrupted run before
    # submitting (and paying for) a new one.
    tasks = _load_tasks(out_dir)
    task_id = tasks.get(asin)
    if task_id:
        print(f"  {asin}  resuming task {task_id}")
    else:
        data = _tripo("POST", TRIPO_ENDPOINT, _tripo_payload(image_urls))
        task_id = data.get("task_id")
        if not task_id:
            raise RuntimeError(f"no task_id in Tripo response: {data}")
        tasks[asin] = task_id
        _save_tasks(out_dir, tasks)

    deadline = time.time() + POLL_TIMEOUT_S
    poll_errors = 0
    while True:
        if time.time() > deadline:
            raise RuntimeError(f"task {task_id} timed out after {POLL_TIMEOUT_S}s")
        time.sleep(POLL_INTERVAL_S)
        try:
            task = _tripo("GET", f"{TRIPO_ENDPOINT}/{task_id}")
        except (RuntimeError, urllib.error.URLError) as err:
            # A transient poll blip must not orphan a paid task — the id is on
            # disk, so even raising here lets the next run resume it.
            poll_errors += 1
            if poll_errors > 3:
                raise
            print(f"  {asin}  poll error ({err}), retrying...", file=sys.stderr)
            continue
        poll_errors = 0
        status = task.get("status")
        if status in ("queued", "running"):
            continue
        if status != "success":
            # Terminal failure: forget the task so a re-run submits fresh.
            tasks.pop(asin, None)
            _save_tasks(out_dir, tasks)
            raise RuntimeError(f"task {task_id} ended '{status}'")
        break

    output = task.get("output") or {}
    model_url = output.get("pbr_model") or output.get("model")
    if isinstance(model_url, dict):  # some API versions nest {url: ...}
        model_url = model_url.get("url")
    if not model_url:
        raise RuntimeError(f"task {task_id} succeeded but no model URL in output: {output}")

    _download(model_url, glb_path, timeout=120)
    tasks.pop(asin, None)   # done — the GLB on disk is now the skip signal
    _save_tasks(out_dir, tasks)
    print(f"  {asin}  GLB downloaded ({os.path.getsize(glb_path) // 1024} KB)")
    return glb_path


# --- phase A: generate ----------------------------------------------------------

def run_generate(entries: list[dict], out_dir: str, limit: int | None,
                 views: dict[str, list[str]] | None = None) -> None:
    os.makedirs(out_dir, exist_ok=True)
    cache_dir = os.path.join(out_dir, "images_cache")
    views = views or {}
    if limit:
        entries = entries[:limit]
    print(f"Generating {len(entries)} model(s): "
          f"{', '.join(e['asin'] + '/' + e['category'] for e in entries)}\n")
    ok, failed = 0, []
    for e in entries:
        asin = e["asin"]
        # Prefer hand-picked clean angles from the views map; fall back to the
        # seeded hero image. 2+ urls trigger multiview.
        urls = views.get(asin) or ([e["mainImageUrl"]] if e.get("mainImageUrl") else [])
        if not urls:
            failed.append((asin, "no image url"))
            continue
        try:
            cache_image(asin, urls[0], cache_dir)
            n = len(urls)
            print(f"  {asin}  {'multiview x' + str(n) if n > 1 else 'single'}")
            generate_glb(asin, urls, out_dir)
            ok += 1
        except (RuntimeError, urllib.error.URLError, OSError) as err:
            print(f"  {asin}  FAIL: {err}", file=sys.stderr)
            failed.append((asin, str(err)[:200]))
    print(f"\n== generate summary: {ok} GLBs ready, {len(failed)} failed ==")
    for asin, why in failed:
        print(f"  {asin}: {why}")
    print(f"\nNext: ./build_catalog.sh {out_dir} out-tripo-usdz/ tripo")
    print("Then re-run with --finalize to validate + copy into the app bundle.")


# --- phase B: finalize ----------------------------------------------------------

def run_finalize(entries: list[dict], out_dir: str, usdz_report: str,
                 usdz_dir: str, models_dir: str, report_path: str) -> None:
    with open(usdz_report) as f:
        converted = {m["assetName"]: m for m in json.load(f)["models"]}

    rows = []
    for e in entries:
        asin = e["asin"]
        asset = f"tripo_{asin}"
        target = e["dimensionsMeters"]
        model = converted.get(asset)

        if model is None:
            # No GLB made it through conversion (API fail, usdchecker fail, ...)
            rows.append({"asin": asin, "outcome": "tripo_api_fail", "spread": None,
                         "modelAssetName": e.get("archetype") or None,
                         "notes": "no converted usdz for this ASIN"})
            continue

        native = model["nativeDimsWDH"]   # [width, depth, height], normalized
        # Tripo doesn't preserve our width/depth convention — it often outputs a
        # piece rotated 90° in the ground plane. Try both ground-plane orientations
        # (as-is, and width<->depth swapped) and keep whichever matches the real
        # FOOTPRINT best. rotationDeg is what the app must apply so the mesh's long
        # side lines up with the product's real long side.
        best = None
        for rot_deg, (wi, di) in ((0, (0, 1)), (90, (1, 0))):
            nw, nd = native[wi], native[di]
            if nw <= 1e-6 or nd <= 1e-6:
                continue
            fp = [target[0] / nw, target[1] / nd]          # width, depth factors only
            fp_spread = max(fp) / min(fp)
            if best is None or fp_spread < best[0]:
                best = (fp_spread, rot_deg)
        fp_spread, rot_deg = best if best else (float("inf"), 0)

        if fp_spread <= FOOTPRINT_TOLERANCE:
            src = os.path.join(usdz_dir, f"{asset}.usdz")
            os.makedirs(models_dir, exist_ok=True)
            shutil.copy2(src, os.path.join(models_dir, f"{asset}.usdz"))
            rows.append({"asin": asin, "outcome": "tripo_ok",
                         "footprintSpread": round(fp_spread, 2),
                         "modelYRotationDeg": rot_deg,
                         "modelAssetName": asset, "notes": ""})
        else:
            # Footprint too distorted even after rotation — honest archetype box
            # instead. The failing usdz is never copied into the bundle.
            rows.append({"asin": asin, "outcome": "tripo_fallback",
                         "footprintSpread": round(fp_spread, 2),
                         "modelYRotationDeg": 0,
                         "modelAssetName": e.get("archetype") or None,
                         "notes": f"footprint {fp_spread:.2f}x > {FOOTPRINT_TOLERANCE}x -> archetype"})

    os.makedirs(os.path.dirname(report_path) or ".", exist_ok=True)
    with open(report_path, "w") as f:
        json.dump({"models_dir": models_dir, "results": rows}, f, indent=2)

    total = len(rows)
    n = lambda o: sum(1 for r in rows if r["outcome"] == o)  # noqa: E731
    print(f"{total} products attempted")
    print(f"  Tripo OK (used):        {n('tripo_ok')} ({round(100 * n('tripo_ok') / total) if total else 0}%)")
    print(f"  Tripo fail -> archetype: {n('tripo_fallback')}")
    print(f"  API / download fail:     {n('tripo_api_fail')}")
    print(f"\nWrote {report_path}")
    print("Next: ingest_amazon.py to assemble catalog.json")


def main() -> None:
    ap = argparse.ArgumentParser(description="P1: Tripo image->3D per Amazon product.")
    ap.add_argument("--asins", required=True, help="reviewed asins.json from seed_catalog.py")
    ap.add_argument("--out-dir", required=True, help="GLB output dir (out-tripo/)")
    ap.add_argument("--limit", type=int, help="pilot mode: only the first N ASINs")
    ap.add_argument("--only", nargs="+", metavar="ASIN",
                    help="target specific ASINs (overrides --limit) — for a "
                         "one-per-category quality pilot")
    ap.add_argument("--views-file", metavar="JSON",
                    help="{asin: [url, ...]} hand-picked clean angles; 2+ urls "
                         "per asin use multiview. Falls back to hero image.")
    ap.add_argument("--finalize", action="store_true",
                    help="phase B: validate converted USDZs + copy + write report")
    ap.add_argument("--usdz-report", help="[finalize] build_catalog report.json")
    ap.add_argument("--usdz-dir", help="[finalize] dir holding tripo_<ASIN>.usdz")
    ap.add_argument("--models-dir", help="[finalize] app bundle Resources/Models dir")
    ap.add_argument("--report", help="[finalize] generate_report.json output path")
    args = ap.parse_args()

    with open(args.asins) as f:
        entries = json.load(f)
    unreviewed = [e["asin"] for e in entries if e.get("_review")]
    if unreviewed:
        sys.exit(f"ERROR: {len(unreviewed)} entries still flagged _review:true in {args.asins} "
                 f"(first: {unreviewed[:5]}). Review them and clear the flag first.")

    if args.only:
        by_asin = {e["asin"]: e for e in entries}
        missing = [a for a in args.only if a not in by_asin]
        if missing:
            sys.exit(f"ERROR: --only ASINs not in {args.asins}: {missing}")
        entries = [by_asin[a] for a in args.only]

    if args.finalize:
        for required in ("usdz_report", "usdz_dir", "models_dir", "report"):
            if not getattr(args, required):
                sys.exit(f"ERROR: --finalize requires --{required.replace('_', '-')}")
        run_finalize(entries, args.out_dir, args.usdz_report,
                     args.usdz_dir, args.models_dir, args.report)
    else:
        views = None
        if args.views_file:
            with open(args.views_file) as f:
                views = json.load(f)
        run_generate(entries, args.out_dir, args.limit, views)


if __name__ == "__main__":
    main()
