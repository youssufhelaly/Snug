import Testing
import Foundation
import SwiftData
@testable import Snug

/// Phase 1 persistence: the `RoomModel` ⇄ `StoredRoom` mapping and the
/// `RoomStore` mutations. The store is the only writer of saved rooms, and
/// `RoomModel` must survive the JSON-blob round-trip unchanged (it's the single
/// source of geometry — fixtures, fit math, and the diorama all read it).
@MainActor
struct RoomPersistenceTests {

    /// A fresh in-memory store per test, using the real versioned schema.
    private func makeStore() throws -> RoomStore {
        let schema = Schema(versionedSchema: SnugSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return RoomStore(context: container.mainContext)
    }

    @Test func roomModelCodableRoundTrips() throws {
        for room in [FitFixtures.rectangularBedroom, FitFixtures.bedroomWithWindow, FitFixtures.lShapedStudio] {
            let data = try JSONEncoder().encode(room)
            let decoded = try JSONDecoder().decode(RoomModel.self, from: data)
            #expect(decoded == room)
        }
    }

    @Test func savePersistsRoomAndDecodesUnchanged() throws {
        let store = try makeStore()
        let room = FitFixtures.bedroomWithWindow

        let stored = try store.save(room, name: "Test room")
        #expect(stored.id == room.id)
        #expect(stored.name == "Test room")
        #expect(stored.capturedAt == room.capturedAt)

        let decoded = try #require(stored.roomModel)
        #expect(decoded == room)
    }

    @Test func allRoomsReturnsNewestFirst() throws {
        let store = try makeStore()
        let older = RoomModel(
            capturedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            provenance: .manualAR,
            floorCorners: FitFixtures.rectangularBedroom.floorCorners,
            ceilingHeight: 2.5
        )
        let newer = RoomModel(
            capturedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            provenance: .manualAR,
            floorCorners: FitFixtures.rectangularBedroom.floorCorners,
            ceilingHeight: 2.5
        )
        try store.save(older, name: "Older")
        try store.save(newer, name: "Newer")

        let all = try store.allRooms()
        #expect(all.count == 2)
        #expect(all.first?.id == newer.id)
    }

    @Test func updateOverwritesGeometryButKeepsName() throws {
        let store = try makeStore()
        let stored = try store.save(FitFixtures.rectangularBedroom, name: "Bedroom")
        #expect(stored.roomModel?.openings.isEmpty == true)

        try store.update(stored, with: FitFixtures.bedroomWithWindow)
        #expect(stored.name == "Bedroom")
        #expect(stored.roomModel?.openings.count == 1)
    }

    @Test func renameTrimsAndFallsBackOnBlank() throws {
        let store = try makeStore()
        let stored = try store.save(FitFixtures.rectangularBedroom, name: "Original")

        try store.rename(stored, to: "  Living room  ")
        #expect(stored.name == "Living room")

        try store.rename(stored, to: "   ")
        #expect(!stored.name.isEmpty)
    }

    @Test func deleteRemovesRoom() throws {
        let store = try makeStore()
        let stored = try store.save(FitFixtures.rectangularBedroom)
        
        try store.delete(stored)
        #expect(try store.allRooms().isEmpty)
    }

    @Test func setThumbnailPersists() throws {
        let store = try makeStore()
        let stored = try store.save(FitFixtures.rectangularBedroom)
        let data = Data([0x1, 0x2, 0x3])
        try store.setThumbnail(data, for: stored)
        #expect(stored.thumbnailData == data)
    }

    @Test func defaultNameReflectsArea() {
        let name = RoomStore.defaultName(for: FitFixtures.rectangularBedroom)
        #expect(name.contains("m²"))
    }

    // MARK: - Duplication

    /// A footprint helper for the duplication tests — the geometry doesn't matter,
    /// only the id/`isCleared` flags the copy filters on.
    private func footprint(cleared: Bool = false) -> FurnitureFootprint {
        FurnitureFootprint(
            category: .sofa,
            worldPosition: .zero,
            dimensions: SIMD3(1.0, 0.8, 0.9),
            appearance: FurnitureAppearance(colorCategory: .navy, materialClass: .fabric),
            detectionConfidence: .detected,
            isCleared: cleared
        )
    }

    private func roomWithFurniture(_ pieces: [FurnitureFootprint]) -> RoomModel {
        RoomModel(
            provenance: .manualAR,
            floorCorners: FitFixtures.rectangularBedroom.floorCorners,
            ceilingHeight: 2.5,
            detectedFurniture: pieces
        )
    }

    @Test func duplicateKeepsAllChosenFurnitureAndCopiesGeometry() throws {
        let store = try makeStore()
        let a = footprint(), b = footprint()
        let source = roomWithFurniture([a, b])
        let stored = try store.save(source, name: "Studio")

        let copy = try store.duplicate(stored, keepingFurnitureIDs: [a.id, b.id])
        let model = try #require(copy.roomModel)
        #expect(Set(model.detectedFurniture.map(\.id)) == [a.id, b.id])
        // Geometry rides along; identity does not.
        #expect(model.floorCorners == source.floorCorners)
        #expect(copy.id != stored.id)
        #expect(copy.name == "Studio copy")
        // Both rooms now exist independently.
        #expect(try store.allRooms().count == 2)
    }

    @Test func duplicateKeepsOnlyTheSelectedSubset() throws {
        let store = try makeStore()
        let a = footprint(), b = footprint()
        let stored = try store.save(roomWithFurniture([a, b]))

        let copy = try store.duplicate(stored, keepingFurnitureIDs: [a.id])
        let model = try #require(copy.roomModel)
        #expect(model.detectedFurniture.map(\.id) == [a.id])
    }

    @Test func duplicateWithEmptySelectionCopiesBareRoom() throws {
        let store = try makeStore()
        let stored = try store.save(roomWithFurniture([footprint(), footprint()]))

        let copy = try store.duplicate(stored, keepingFurnitureIDs: [])
        #expect(copy.roomModel?.detectedFurniture.isEmpty == true)
    }

    @Test func duplicateNeverCarriesClearedPieces() throws {
        let store = try makeStore()
        let cleared = footprint(cleared: true)
        let stored = try store.save(roomWithFurniture([cleared]))

        // Even explicitly selected, a cleared piece is dropped from the copy.
        let copy = try store.duplicate(stored, keepingFurnitureIDs: [cleared.id])
        #expect(copy.roomModel?.detectedFurniture.isEmpty == true)
    }

    @Test func duplicateLeavesSourceUnchanged() throws {
        let store = try makeStore()
        let a = footprint(), b = footprint()
        let stored = try store.save(roomWithFurniture([a, b]), name: "Bedroom")

        _ = try store.duplicate(stored, keepingFurnitureIDs: [a.id])
        #expect(stored.name == "Bedroom")
        #expect(stored.roomModel?.detectedFurniture.count == 2)
    }

    @Test func copyNameFallsBackForBlankSource() {
        #expect(RoomStore.copyName(for: "  ") == "Room copy")
        #expect(RoomStore.copyName(for: "Loft") == "Loft copy")
    }

    /// The surface style and openings must ride into the copy — the doc promises
    /// "geometry, openings, and the surface style always come along," and a future
    /// refactor dropping either from the copy's `RoomModel(...)` init would
    /// otherwise pass every existing duplication test.
    @Test func duplicateCopiesSurfaceStyleAndOpenings() throws {
        let store = try makeStore()
        let window = FitFixtures.bedroomWithWindow
        #expect(!window.openings.isEmpty)   // guard the fixture actually has one
        let source = RoomModel(
            provenance: .manualAR,
            floorCorners: window.floorCorners,
            ceilingHeight: 2.5,
            openings: window.openings,
            surfaceStyle: RoomSurfaceStyle(wall: .sage, floor: .walnut, backdrop: .charcoal)
        )
        let stored = try store.save(source, name: "Styled")

        let copy = try #require(try store.duplicate(stored, keepingFurnitureIDs: []).roomModel)
        #expect(copy.surfaceStyle == source.surfaceStyle)
        #expect(copy.openings == source.openings)
    }

    /// A source whose saved blob can't be decoded must make `duplicate` THROW,
    /// never fabricate an empty room (CLAUDE.md: never invent geometry).
    @Test func duplicateThrowsOnUnreadableSource() throws {
        let store = try makeStore()
        let stored = try store.save(FitFixtures.rectangularBedroom)
        // Corrupt the blob so `stored.roomModel` decodes to nil.
        stored.roomData = Data([0xFF, 0xFF, 0xFF])
        #expect(throws: DuplicationError.self) {
            try store.duplicate(stored, keepingFurnitureIDs: [])
        }
    }
}
