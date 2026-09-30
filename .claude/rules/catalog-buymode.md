---
paths:
  - "Snug/Features/Catalog/**"
  - "Snug/Core/Models/CatalogItem*"
  - "Snug/Core/Services/CatalogService.swift"
  - "Snug/Core/Rendering/CatalogModelLoader.swift"
  - "Snug/Resources/**"
---

# Catalog / buy-mode — implementation status (for the next engineer)

The commerce loop (scan → redesign → BUY a real product with an honest fit check)
landed on top of the Phase 2 furniture rails — a placed product REUSES
`FurnitureFootprint`/`RoomModel.detectedFurniture`, so there is NO parallel placement,
fit, or persistence system, and NO schema bump (new fields are optional → old blobs
decode). What exists and is unit-tested:
- The value types (`Core/Models/CatalogItem.swift`): real spec `dimensions`,
  `trueColorRGB` (exact true color) + perceptual `colorCategory` (filtering),
  price (cents), `retailerName`/`productURL`/`affiliateTag` (+ `outboundURL`),
  `modelAssetName`/`thumbnailAssetName`, `isRemovable` (renter-safe gate).
- `CatalogService` (`Core/Services/`) — `@MainActor @Observable`; loads the bundled
  `Resources/catalog.json` via the thin `CatalogSource` protocol (one
  `BundledCatalogSource`; the remote Amazon-ingest feed is the planned swap — see
  FounderPivot.md). Local-first with networked product thumbnails (`imageURL`,
  Amazon CDN, cached by `CachedThumbnailImage`);
  `items(in:)`/`search`/`availableCategories`.
- `CatalogItem.makeFootprint(at:)` + `RoomModel.fitResult(for:excluding:)`
  (`Core/Models/CatalogItem+Footprint.swift`) — a placed product is an `isKept`,
  `.detected` footprint with `catalogItemID` set, so `keptObstacles` counts it and
  the pure `FitService` evaluates it (excluding itself). True-color rides on the
  footprint via `FurnitureAppearance.exactColorRGB` (optional).
- `FitResult.State` UI copy lives ONCE in `Features/Catalog/FitBadge.swift` (the
  four honest states; never round "too close" to a green check).
Wired into the app (device-verified 2026-06-21):
- `Features/Catalog/CatalogBrowseOverlay.swift` is the `+ Add` shop (browse, filter
  chips, price, affiliate disclosure). `RoomDioramaScreen` shows the `FitBadge` +
  "View at <retailer>" out-link on the selected piece; `CatalogService` is injected
  at `SnugApp` root. The old generic-category `FurnitureCarouselOverlay` is unused.
- Placed products always show their exact color (`exactColorRGB`)
  (`FurnitureEntityBuilder.tint(_:exact:)` — the `mode` parameter died with the
  PLAY/BUY toggle).
- Realistic product models always render (detected furniture is always a box —
  reconstruction stays out of scope). `CatalogModelLoader` (actor, async
  `Entity(named:in:)`, caches) has TWO fit tracks: Verified assets use the pure
  `fitTransform` 1:1-or-refuse guard; approximate assets (`tripo_*`/`quaternius_*`
  prefixes) use `approximateFitTransform` — footprint always exactly 1:1 to the
  catalog dims, height 1:1 unless the mesh is clutter-tall (then it keeps its
  proportional height, bottom-aligned on the floor, so the clutter pokes above).
  The fit/collision box ALWAYS keeps the catalog's real dimensions.
  The model is a VISUAL-ONLY child of the box root — box stays source of truth for
  collision/fit/gestures/resize. ALL realistic-model code is gated behind
  `hasRealisticModel(box)`, so the no-model path is byte-identical.
  RealityKit ignores USD `displayColor`, so models are tinted at runtime to the
  product's true color (`applyModelTint`) — one shared shape renders per-SKU color.
Still TODO:
- Real product USDZ + thumbnail PNGs. Today `Resources/Models/*.usda` are stylized
  PLACEHOLDER silhouettes (sofa/coffee_table/bed/chair/bookshelf) wired to 8 of 12
  SKUs (rest fall back to the box); `thumbnailAssetName` is null (cards show a
  swatch+glyph). Real USDZ ship their own materials → pass `tint: nil`
  (see `Resources/Models/README.md`).
- Checkout stays out of V1 — we link out to the retailer with disclosure.
