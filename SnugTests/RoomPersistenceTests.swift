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

        store.rename(stored, to: "  Living room  ")
        #expect(stored.name == "Living room")

        store.rename(stored, to: "   ")
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
        store.setThumbnail(data, for: stored)
        #expect(stored.thumbnailData == data)
    }

    @Test func defaultNameReflectsArea() {
        let name = RoomStore.defaultName(for: FitFixtures.rectangularBedroom)
        #expect(name.contains("m²"))
    }
}
