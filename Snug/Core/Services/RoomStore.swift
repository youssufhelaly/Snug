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
    /// list never shows a blank row. Propagates the save error (like
    /// `save`/`update`/`delete`) so a failed write can't silently leave the
    /// in-memory name ahead of disk.
    func rename(_ stored: StoredRoom, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.name = trimmed.isEmpty
            ? (stored.roomModel.map(Self.defaultName) ?? "Room")
            : trimmed
        try context.save()
    }

    /// Stores a freshly rendered diorama thumbnail (PNG data) for a room.
    /// Throws on a failed write; callers may choose to ignore it (a thumbnail
    /// is cosmetic and regenerated on the next open), but that choice belongs
    /// at the call site, not silently here.
    func setThumbnail(_ data: Data, for stored: StoredRoom) throws {
        stored.thumbnailData = data
        try context.save()
    }

    /// Deletes a saved room. Propagates the save error (like `save`/`update`) so
    /// a failed disk write can't silently leave the in-memory store ahead of disk
    /// — which would resurrect the "deleted" room on the next launch.
    func delete(_ stored: StoredRoom) throws {
        context.delete(stored)
        try context.save()
    }

    /// Forks a saved room into a brand-new one. Geometry, openings, and the
    /// surface style always come along; the furniture is opt-in — `keepingFurnitureIDs`
    /// selects which pieces (none, some, or all) ride into the copy, so you can spin
    /// off a bare shell of the same room or a full clone.
    ///
    /// The copy gets a fresh `id`/`capturedAt` (it's a distinct room, newest in the
    /// list) and no thumbnail (regenerated on first open). Cleared pieces are never
    /// carried over — they're already hidden and a fresh copy has no de-clutter
    /// history to preserve, so an id in the set that points at a cleared piece is
    /// simply ignored. Throws if the source blob can't be read (never fabricates a
    /// room — CLAUDE.md), or on a failed write.
    @discardableResult
    func duplicate(_ stored: StoredRoom, keepingFurnitureIDs ids: Set<UUID>) throws -> StoredRoom {
        guard let source = stored.roomModel else { throw DuplicationError.unreadableSource }
        let kept = source.detectedFurniture.filter { !$0.isCleared && ids.contains($0.id) }
        let copy = RoomModel(
            provenance: source.provenance,
            floorCorners: source.floorCorners,
            ceilingHeight: source.ceilingHeight,
            openings: source.openings,
            detectedFurniture: kept,
            surfaceStyle: source.surfaceStyle
        )
        return try save(copy, name: Self.copyName(for: stored.name))
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

    /// The name for a duplicated room: the source name with a " copy" suffix so the
    /// two are distinguishable in the list. Falls back to "Room" for a blank source
    /// name (the list never shows a blank row). Repeated duplication reads as
    /// "Room copy copy", matching Finder — the user can rename either.
    static func copyName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed.isEmpty ? "Room" : trimmed) copy"
    }
}

/// Errors from a room duplication that can't proceed honestly.
enum DuplicationError: LocalizedError {
    /// The source room's saved blob couldn't be decoded, so there's nothing
    /// trustworthy to copy.
    case unreadableSource

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "The room's saved data couldn't be read."
        }
    }
}
