---
paths:
  - "Snug/Features/RoomScene/**"
  - "Snug/Core/Rendering/**"
---

# The one truthful rendering (core product mechanic)

There is NO render-mode toggle. The old PLAY/BUY split (stylized pastels vs
neutral measuring view) was removed in July 2026: both modes had identical
interactions, so the stylized layer was just a lie between the user and the
colors they were about to buy. The replacement principle:

- **Everything inside the room is always true-to-color under neutral (white)
  lighting.** Room surfaces, furniture tints, catalog models — never lightened,
  warmed, or pastelized. Seeing your real colors together IS the product.
  Lighting counts: a warm key or IBL shifts perceived color as surely as a
  material override, so the rig is white-only and there is no image-based light.
- **The playfulness lives in the FRAME, not the room**: the warm terracotta
  backdrop (a SwiftUI `Color` behind the `RealityView` — the scene renders
  transparent, there is no skybox), the platform base, the soft drop shadow,
  the warm-white wall-cap rims, plus motion/haptics. Future "style/background
  themes" may restyle the frame; they must NEVER touch scene lighting or any
  in-room material.
- **"Buy info" is an additive overlay, not a mode**: the "Measure" pill in
  `RoomDioramaScreen` toggles `showsDimensions`, which only flips the
  blueprint dimension labels' `isEnabled`. Fit chips / prices / retailer links
  live on the selection inspector card. Nothing about the rendering changes.

Implementation (`Features/RoomScene`): the diorama is one RealityKit scene
built once from `RoomModel`. Colors come from the single `RoomPalette.standard`
(+ `palette(style:)` overlaying the room's chosen wall/floor colors) in
`Theme.swift`; materials from `RoomMaterials`. It's an open-top "dollhouse":
no ceiling, and walls between the camera and the interior are culled each
frame so you can see in. The room-list thumbnail is produced offscreen by
`OffscreenSnapshotRenderer` (RealityKit `RealityRenderer`), which clones the
live scene and FAILS LOUDLY rather than faking a frame. Realistic product
USDZ models always render (async load; the true-color identity box shows
until they arrive and remains the interaction/collision proxy).

> Aesthetic target: free-orbit isometric diorama, cozy detailing confined to
> the frame. If you're tempted to add a stylized in-room look, that's a
> product-thesis change — raise it, don't code it.
