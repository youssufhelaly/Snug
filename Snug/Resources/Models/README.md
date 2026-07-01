# Verified catalog product models (USDZ)

Drop bundled **real-product USDZ** here. They render in **BUY mode only**, as a
true-to-scale replica of an added catalog product. PLAY mode keeps the stylized
box; detected (scanned) furniture is always a box.

## The Verified-track rule (read this before adding a model)

This folder is the **Verified Catalog** — real, buyable products. It is governed by
one uncompromising rule (see IDEAS.md → "two named catalogs"):

- A model here is the **manufacturer's real asset, placed 1:1 — ZERO scaling.** The
  USDZ must be authored at the product's true real-world dimensions, matching the
  SKU's `dimensions` in `catalog.json` within **1 cm**.
- The loader **validates this at runtime**: on load it measures the model's native
  `visualBounds` and compares to the catalog dims via
  `CatalogModelLoader.nativeSizeDeviation`. If it deviates by more than
  `verifiedModelTolerance` (0.01 m), the model is **refused** (loud `os_log` error +
  `assertionFailure` in DEBUG) and the SKU falls back to the **honest box**. It is
  NEVER silently stretched to fit. If a model breaks this, **re-author the asset to
  true scale at the source** — do not patch the transform layer.
- Real USDZ ship their **own PBR materials**, so the loader attaches them with
  `tint: nil` (it does NOT recolor them).

A Verified SKU with **no** real USDZ yet (the state today — all `modelAssetName` are
`null`) renders the honest stylized **box** with true color + dimension labels. We do
**not** dress it up with a generic look-alike shape — a stretched generic asset
impersonating a specific real product is the exact anti-pattern this rule forbids.

> Generic, stylized, *elastic* shapes (the kind you freely stretch to sketch a
> layout) belong to the future **Ideation Sandbox** track, produced by the
> `tools/catalog/` pipeline — NOT here. Don't mix the two.

## How it wires up

- Each `CatalogItem` in `catalog.json` has a `modelAssetName` field.
- Set it to the USDZ file's **base name without extension** (e.g. `article_lina_sofa`
  for `article_lina_sofa.usdz`). The whole `Snug/` folder is a synchronized group, so
  a file dropped here is bundled automatically — no Xcode project edits.
- `CatalogModelLoader` loads it async (`Entity(named:in:)`) and caches it;
  `RoomSceneController.updateRealisticModel` runs the zero-scaling guard above, then
  attaches it as a **visual-only child** of the box. The box stays the source of
  truth for collision / fit / gestures / resize.
- If `modelAssetName` is null or the file is missing, the app falls back to the
  stylized box — nothing breaks. So you can add real models one product at a time.

## Sourcing

IKEA, Article, and many retailers publish USDZ models for AR Quick Look at the
product's real scale — those are exactly what slot in (mind each retailer's terms).
Keep them lightweight (the diorama holds up to ~8 pieces). No network fetching at
runtime (offline-first): the pack ships in the app bundle.
