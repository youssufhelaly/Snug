import Testing
import Foundation
import UIKit
@testable import Snug

/// The per-room surface choices: backward-compatible persistence inside the
/// `RoomModel` JSON blob, and the palette overlay that turns a choice into
/// concrete true colors without disturbing anything the user didn't set.
struct RoomSurfaceStyleTests {

    // MARK: - Codable

    @Test func preSurfaceStyleBlobDecodesToUnset() throws {
        // A blob written before `surfaceStyle` existed (the field is absent).
        var room = FitFixtures.rectangularBedroom
        room.surfaceStyle = .unset
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(room)) as! [String: Any]
        json.removeValue(forKey: "surfaceStyle")
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(RoomModel.self, from: legacy)
        #expect(decoded.surfaceStyle == .unset)
        #expect(decoded == room)
    }

    @Test func surfaceStyleRoundTrips() throws {
        var room = FitFixtures.rectangularBedroom
        room.surfaceStyle = RoomSurfaceStyle(wall: .sage, floor: .walnut, backdrop: .lavender)
        let data = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(RoomModel.self, from: data)
        #expect(decoded.surfaceStyle == RoomSurfaceStyle(wall: .sage, floor: .walnut, backdrop: .lavender))
        #expect(decoded == room)
    }

    @Test func preBackdropBlobDecodesWithNilBackdrop() throws {
        // A blob written before `backdrop` existed (wall/floor present, no
        // backdrop key) must keep decoding — backdrop simply reads back nil.
        var room = FitFixtures.rectangularBedroom
        room.surfaceStyle = RoomSurfaceStyle(wall: .sage, floor: .walnut)
        let data = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(RoomModel.self, from: data)
        #expect(decoded.surfaceStyle.backdrop == nil)
    }

    @Test func partialChoiceRoundTrips() throws {
        var room = FitFixtures.rectangularBedroom
        room.surfaceStyle = RoomSurfaceStyle(wall: nil, floor: .lightOak)
        let data = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(RoomModel.self, from: data)
        #expect(decoded.surfaceStyle.wall == nil)
        #expect(decoded.surfaceStyle.floor == .lightOak)
    }

    // MARK: - Palette overlay

    @Test func unsetStyleMatchesStandardPalette() {
        let styled = RoomPalette.palette(style: .unset)
        #expect(styled.wall == RoomPalette.standard.wall)
        #expect(styled.floor == RoomPalette.standard.floor)
        #expect(styled.base == RoomPalette.standard.base)
        #expect(styled.background == RoomPalette.standard.background)
    }

    @Test func chosenWallAppliesHonestly() {
        let styled = RoomPalette.palette(style: RoomSurfaceStyle(wall: .dustyBlue))
        #expect(styled.wall == WallColorChoice.dustyBlue.color)
        // Only the wall moves — the floor was not chosen.
        #expect(styled.floor == RoomPalette.standard.floor)
        #expect(styled.base == RoomPalette.standard.base)
    }

    @Test func chosenFloorDrivesBase() {
        let palette = RoomPalette.palette(style: RoomSurfaceStyle(floor: .greyLaminate))
        #expect(palette.floor == FloorMaterialChoice.greyLaminate.color)
        // The platform base is the chosen floor, darkened — never the standard
        // default, or the shell would clash with the chosen floor.
        #expect(palette.base != RoomPalette.standard.base)
        var floorB: CGFloat = 0, baseB: CGFloat = 0
        palette.floor.getHue(nil, saturation: nil, brightness: &floorB, alpha: nil)
        palette.base.getHue(nil, saturation: nil, brightness: &baseB, alpha: nil)
        #expect(baseB < floorB)
    }

    @Test func chosenBackdropRestylesFrameOnly() {
        // The backdrop is frame, not room: picking one moves ONLY the scene
        // background and never a surface or light the user's colors depend on.
        let styled = RoomPalette.palette(style: RoomSurfaceStyle(backdrop: .charcoal))
        #expect(styled.background == BackdropColorChoice.charcoal.color)
        #expect(styled.wall == RoomPalette.standard.wall)
        #expect(styled.floor == RoomPalette.standard.floor)
        #expect(styled.base == RoomPalette.standard.base)
        #expect(styled.keyTint == .white)
    }

    @Test func unsetBackdropKeepsBrandTerracotta() {
        let styled = RoomPalette.palette(style: RoomSurfaceStyle(wall: .sage))
        #expect(styled.background == RoomPalette.standard.background)
    }

    @Test func lightingStaysNeutralRegardlessOfStyle() {
        // The true-color promise: a chosen surface color must never tint the
        // lights — lighting shifts perceived color as surely as a material would.
        let styled = RoomPalette.palette(
            style: RoomSurfaceStyle(wall: .blush, floor: .beigeCarpet))
        #expect(styled.keyTint == .white)
        #expect(styled.fillTint == .white)
        #expect(styled.backTint == .white)
    }
}
