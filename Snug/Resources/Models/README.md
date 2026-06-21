# Catalog product models (USDZ)

Drop bundled **USDZ** product models here. They render in **BUY mode only**, as a
true-to-scale replica of an added catalog product. PLAY mode keeps the stylized
box; detected (scanned) furniture is always a box.

## How it wires up
- Each `CatalogItem` in `catalog.json` has a `modelAssetName` field.
- Set it to the USDZ file's **base name without extension** (e.g. `lina_sofa` for
  `lina_sofa.usdz`). The whole `Snug/` folder is a synchronized group, so a file
  dropped here is bundled automatically — no Xcode project edits.
- `CatalogModelLoader` loads it async (`Entity(named:in:)`), caches it, and
  `CatalogModelLoader.fitTransform` scales it to the product's real dimensions.
- If `modelAssetName` is null or the file is missing, the app falls back to the
  stylized box — nothing breaks. So you can add models one product at a time.

## Color
These placeholder `.usda` models are **untextured shapes**. RealityKit ignores USD
`displayColor` without a bound material network, so the app **tints the loaded model
at runtime to the product's `trueColorRGB`** (`FurnitureEntityBuilder.applyModelTint`,
called from the controller). Upside: one shared shape (e.g. `sofa`) renders each SKU
at its real color — charcoal for one, navy for another.

⚠️ Real product USDZ ship their OWN correct PBR materials/textures. When you add
those, pass `tint: nil` to `attachRealisticModel` (don't overwrite their materials).
Today every model is a placeholder, so tinting is always on.

## Sourcing
IKEA, Article, and many retailers publish USDZ models for AR Quick Look — those
are exactly what slot in. Keep them lightweight (the diorama holds up to ~8 pieces).
No network fetching at runtime (offline-first): the pack ships in the app bundle.

## Convention
- One `.usdz` per product, named to match its `modelAssetName`.
- Model should be modeled at real-world scale, Y-up, roughly centered — the loader
  re-centers and re-scales to the catalog dimensions regardless, but a sane origin
  helps.
