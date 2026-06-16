import Foundation
import SwiftData

/// Snug's persisted SwiftData schema, expressed with SwiftData's native
/// `VersionedSchema` so the model can evolve through `SchemaMigrationPlan`
/// stages later (CLAUDE.md: use native VersionedSchema migrations — never a
/// custom `schemaVersion` field).
///
/// ## Why a blob, not exploded geometry
/// `RoomModel` is the app's single canonical room representation — a `Codable`
/// value type shared by the capture methods, `FitService`, and the test
/// fixtures. To avoid a *second* source of truth that must be kept in sync, the
/// persisted `StoredRoom` stores the whole `RoomModel` as one encoded blob and
/// denormalizes only the few fields the UI needs to list/sort rooms without
/// decoding every blob (id, name, capture date, thumbnail). Geometry evolution
/// is handled by `RoomModel`'s own `Codable` form; SwiftData migrations handle
/// the surrounding queryable columns.
enum SnugSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] { [StoredRoom.self] }

    /// A scanned room saved to the local store. Persists the canonical
    /// `RoomModel` as `roomData`; the other fields are denormalized projections
    /// for the "My rooms" list.
    @Model
    final class StoredRoom {
        /// Mirrors `RoomModel.id` so a stored row maps back to its room value.
        @Attribute(.unique) var id: UUID
        /// User-facing name, editable. Defaults to a friendly auto-name.
        var name: String
        /// When the underlying room was captured (drives list ordering).
        var capturedAt: Date
        /// The full `RoomModel`, JSON-encoded. The single source of geometry.
        var roomData: Data
        /// A RealityKit snapshot of the diorama, captured the first time the
        /// room is viewed. Stored inline (not `.externalStorage`): the thumbnail
        /// is a small downscaled snapshot, and `.externalStorage` traps when
        /// written to an in-memory store — which both the unit tests and SwiftUI
        /// previews rely on.
        var thumbnailData: Data?

        init(id: UUID, name: String, capturedAt: Date, roomData: Data, thumbnailData: Data? = nil) {
            self.id = id
            self.name = name
            self.capturedAt = capturedAt
            self.roomData = roomData
            self.thumbnailData = thumbnailData
        }
    }
}

/// The current persisted model, version-independent alias the app refers to.
/// When a `SnugSchemaV2` arrives, this alias moves and the migration plan gains
/// a stage — call sites don't change.
typealias StoredRoom = SnugSchemaV1.StoredRoom

/// Native SwiftData migration plan. One version so far; future versions append
/// to `schemas` and add `MigrationStage`s here.
enum SnugMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SnugSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

extension StoredRoom {
    /// Decodes the persisted blob back into the canonical `RoomModel`.
    /// Returns nil only if the stored data is corrupt (which shouldn't happen
    /// for data this app wrote); callers treat nil as an unreadable room.
    var roomModel: RoomModel? {
        try? JSONDecoder().decode(RoomModel.self, from: roomData)
    }
}
