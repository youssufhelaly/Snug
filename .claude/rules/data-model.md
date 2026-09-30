---
paths:
  - "Snug/Core/Models/RoomModel.swift"
  - "Snug/Core/Persistence/**"
  - "Snug/Core/Services/RoomStore.swift"
  - "Snug/Core/Services/AccuracyStore.swift"
---

# Data model & persistence

- `RoomModel` is the app's ONE canonical room representation: a
  plain `Codable`/`Equatable` value type (floor-corner polygon,
  ceiling height, openings; walls/area/diagonal are derived). Every
  capture method produces it; `FitService`, the diorama, the
  accuracy logger, and the test fixtures all read it. It is NOT a
  SwiftData `@Model` — keep it a value type.
- Persistence wraps it, never replaces it. `StoredRoom` (a SwiftData
  `@Model` inside `SnugSchemaV1`) stores the whole `RoomModel` as a
  JSON `Data` blob plus a few DENORMALIZED columns for listing
  without decoding (`id`, `name`, `capturedAt`, `thumbnailData`).
  This deliberately avoids a second source of geometry truth. The
  blob's evolution rides on `RoomModel`'s own `Codable`; SwiftData
  migrations (`SnugMigrationPlan`) handle the surrounding columns.
- `RoomStore` is the only writer of saved rooms (save / update /
  rename / setThumbnail / delete + encode-decode). Views list rooms
  reactively with `@Query`; mutations go through `RoomStore`. It is
  a plain `@Observable` (not `@MainActor`) holding the container's
  **main** `ModelContext`, so it must be used on the main thread.
- Adding a new persisted field to a room (e.g. Phase 2's detected
  objects) = add it to `RoomModel` (with a Codable default so old
  blobs still decode) and, if `StoredRoom`'s columns change, bump to
  `SnugSchemaV2` with a migration stage. Never add a manual version
  field.
- `RoomModel` has a CUSTOM `Codable` (`decodeIfPresent ?? []`) because Swift's
  synthesized decoder does NOT honor property defaults for missing keys; the custom
  decoder is what lets pre-Phase-2 blobs (no `detectedFurniture`) still decode.
