import Foundation
import RoomPlan
import simd

extension CapturedRoom.Confidence {
    /// Short human label for the debug panel and the accuracy CSV.
    var snugLabel: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        @unknown default: "Unknown"
        }
    }
}

extension CapturedRoom.Object.Category {
    /// Human label for RoomPlan's detected-object categories.
    var snugLabel: String {
        switch self {
        case .bathtub: "Bathtub"
        case .bed: "Bed"
        case .chair: "Chair"
        case .dishwasher: "Dishwasher"
        case .fireplace: "Fireplace"
        case .oven: "Oven"
        case .refrigerator: "Refrigerator"
        case .sink: "Sink"
        case .sofa: "Sofa"
        case .stairs: "Stairs"
        case .storage: "Storage"
        case .stove: "Stove"
        case .table: "Table"
        case .television: "TV"
        case .toilet: "Toilet"
        case .washerDryer: "Washer/dryer"
        @unknown default: "Object"
        }
    }
}

extension CapturedRoom {
    /// Corner-to-opposite-corner length of the room footprint, in meters —
    /// the value to compare against a tape-measured floor diagonal.
    ///
    /// Prefers the largest detected floor surface (its plane extents are the
    /// footprint's bounding box, so this is exact for rectangular rooms and
    /// an approximation for L-shapes). Falls back to the horizontal bounding
    /// box of all wall corners when no floor was captured. Nil when the scan
    /// produced nothing to measure against.
    var scannedDiagonalMeters: Double? {
        if let floor = largestFloor {
            return Double(hypotf(floor.dimensions.x, floor.dimensions.y))
        }
        guard !walls.isEmpty else { return nil }
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude
        for wall in walls {
            // A wall plane's local x-axis spans its width; the two end
            // points projected to the floor are enough for a footprint box.
            for offset: Float in [-0.5, 0.5] {
                let corner = wall.transform * SIMD4<Float>(offset * wall.dimensions.x, 0, 0, 1)
                minX = min(minX, corner.x)
                maxX = max(maxX, corner.x)
                minZ = min(minZ, corner.z)
                maxZ = max(maxZ, corner.z)
            }
        }
        return Double(hypotf(maxX - minX, maxZ - minZ))
    }

    /// Confidence to attach to a diagonal sample: the floor's confidence
    /// when the diagonal came from a floor, nil otherwise.
    var scannedDiagonalConfidence: Confidence? {
        largestFloor?.confidence
    }

    private var largestFloor: Surface? {
        floors.max { $0.dimensions.x * $0.dimensions.y < $1.dimensions.x * $1.dimensions.y }
    }
}

/// Single source of truth for user-facing measurement strings.
/// Hard rule (CLAUDE.md): dimensions are rounded to the centimeter and never
/// shown with false precision.
enum SnugFormat {
    static func meters(_ value: Float) -> String {
        String(format: "%.2f m", value)
    }

    static func meters(_ value: Double) -> String {
        String(format: "%.2f m", value)
    }

    /// Signed error in centimeters, e.g. "+2.3 cm" (scan over-measured).
    static func errorCentimeters(_ meters: Double) -> String {
        String(format: "%+.1f cm", meters * 100)
    }

    static func absoluteCentimeters(_ meters: Double) -> String {
        String(format: "%.1f cm", meters * 100)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
