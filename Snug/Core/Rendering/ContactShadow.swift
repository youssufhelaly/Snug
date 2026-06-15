import RealityKit
import CoreGraphics
import UIKit
import simd

/// Soft contact-shadow planes that ground furniture in the PLAY diorama.
///
/// The shadow is a textured plane, not a real-time cast shadow: a CoreGraphics
/// radial gradient (warm-dark center → clear edge) baked once into a `CGImage`,
/// wrapped in a `TextureResource`, and applied to an `UnlitMaterial` with
/// transparent blending. `TextureResource.generateRadialGradient(...)` does **not**
/// exist — the CoreGraphics path is the correct one.
///
/// The texture is generated a single time and cached (Step 9: don't regenerate
/// per placement). Shadow planes are added as **siblings** of the furniture so
/// they don't inherit its scale.
enum ContactShadow {

    // MARK: - Texture (cached)

    private static var cached: TextureResource?

    /// The shared, lazily-built shadow texture. Returns `nil` if the texture
    /// can't be created (which simply means no shadow is drawn — the scene still
    /// renders).
    static func sharedTexture(size: Int = 128) -> TextureResource? {
        if let cached { return cached }
        guard let image = makeImage(size: size) else { return nil }
        // Non-deprecated synchronous initializer (the older
        // `TextureResource.generate(from:…)` is deprecated on current SDKs).
        let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        cached = texture
        return texture
    }

    /// The pure CoreGraphics half, factored out so it's unit-testable without a
    /// Metal device: a `size×size` RGBA radial gradient, warm-dark and ~28%
    /// opaque at the center, fully clear at the edge.
    static func makeImage(size: Int = 128) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let warmDark = UIColor(rgb: 0x3D2B1A)
        // Same RGB at the edge with zero alpha avoids a dark fringe under
        // premultiplied compositing.
        let colors = [
            warmDark.withAlphaComponent(0.28).cgColor,
            warmDark.withAlphaComponent(0.0).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else {
            return nil
        }
        let center = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: CGFloat(size) / 2,
            options: []
        )
        return ctx.makeImage()
    }

    // MARK: - Entity

    /// A shadow plane sized to a footprint (slightly inset so it tucks under the
    /// piece). Returns `nil` if the shared texture is unavailable.
    static func plane(footprint: SIMD2<Float>) -> ModelEntity? {
        guard let texture = sharedTexture() else { return nil }
        let mesh = MeshResource.generatePlane(width: footprint.x * 0.85, depth: footprint.y * 0.85)
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Add a contact shadow under `entity`, parented to `entity`'s parent (a
    /// sibling) so it doesn't inherit the entity's scale. The plane sits 2 mm
    /// above the floor at the entity's base to avoid z-fighting.
    @discardableResult
    static func add(to entity: Entity, footprint: SIMD2<Float>) -> ModelEntity? {
        guard let shadow = plane(footprint: footprint) else { return nil }
        let bounds = entity.visualBounds(relativeTo: nil)
        let base = entity.position(relativeTo: nil)
        // 2 mm above the entity's lowest point, centered on it.
        shadow.position = SIMD3(base.x, bounds.min.y + 0.002, base.z)
        entity.parent?.addChild(shadow)
        return shadow
    }
}
