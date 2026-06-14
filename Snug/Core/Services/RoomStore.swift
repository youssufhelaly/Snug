import Foundation
import Observation
import SwiftData

/// The room persistence service: the one place that turns a captured
/// `RoomModel` into a saved `StoredRoom` and back, and the only writer of the
/// SwiftData store for rooms (CLAUDE.md: business logic lives in plain services
/// injected via the environment; views stay dumb).
///
/// Listing for the UI is done with SwiftData `@Query` directly in the view (the
/// idiomatic reactive path); this service owns the *mutations* — save, rename,
/// thumbnail, delete — plus the encode/decode that keeps `RoomModel` the single
/// source of truth.
///
/// Holds the container's **main** `ModelContext` (the same one `@Query` reads,
/// so saves reflect immediately) and is therefore main-thread-only — matching
/// the app's other `@Observable` services. Construct it from a main-actor
/// context (e.g. `SnugApp.init`).
@Observable
final class RoomStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Mutations

    /// Persists a freshly captured room and returns the stored row. The blob is
    /// the canonical `RoomModel`; the row's `id`/`capturedAt` mirror it so the
    /// list can sort without decoding.
    @discardableResult
    func save(_ room: RoomModel, name: String? = nil) throws -> StoredRoom {
        let data = try JSONEncoder().encode(room)
        let stored = StoredRoom(
            id: room.id,
            name: name ?? Self.defaultName(for: room),
            capturedAt: room.capturedAt,
            roomData: data
        )
        context.insert(stored)
        try context.save()
        return stored
    }

    /// Overwrites a stored room's geometry with an edited `RoomModel` (e.g.
    /// after the drag-to-correct canvas). Keeps the existing name/thumbnail.
    func update(_ stored: StoredRoom, with room: RoomModel) throws {
        stored.roomData = try JSONEncoder().encode(room)
        stored.capturedAt = room.capturedAt
        try context.save()
    }

    /// Renames a room. Empty/whitespace names fall back to the auto-name so the
    /// list never shows a blank row.
    func rename(_ stored: StoredRoom, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.name = trimmed.isEmpty
            ? (stored.roomModel.map(Self.defaultName) ?? "Room")
            : trimmed
        try? context.save()
    }

    /// Stores a freshly rendered diorama thumbnail (PNG data) for a room.
    func setThumbnail(_ data: Data, for stored: StoredRoom) {
        stored.thumbnailData = data
        try? context.save()
    }

    func delete(_ stored: StoredRoom) {
        context.delete(stored)
        try? context.save()
    }

    // MARK: - Reads (non-reactive; views prefer @Query)

    /// All saved rooms, newest first. Provided for non-view callers and tests;
    /// SwiftUI views use `@Query` for reactive listing instead.
    func allRooms() throws -> [StoredRoom] {
        let descriptor = FetchDescriptor<StoredRoom>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Naming

    /// A friendly default name derived from the room's size, so a brand-new
    /// scan reads as e.g. "Room · 11 m²" instead of a UUID. The user can rename.
    static func defaultName(for room: RoomModel) -> String {
        let area = room.floorArea
        guard area > 0 else { return "New room" }
        return String(format: "Room · %.0f m²", area)
    }
}
