// `@preconcurrency`: RealityKit/Metal aren't Sendable-audited yet, and
// `updateAndRender`'s `onComplete` is a `@Sendable` closure. We deliberately
// capture the (non-Sendable) renderer / output / texture there to keep the GPU
// work alive and read the result back — all on the same render-completion thread.
@preconcurrency import RealityKit
@preconcurrency import Metal
import UIKit
import CoreGraphics

/// Offscreen RealityKit snapshot for the RoomScene diorama.
///
/// `RealityView` — unlike the legacy `ARView` it replaced — exposes no
/// `snapshot(...)`, so the PLAY↔BUY cross-fade freeze-frame and the room-list
/// thumbnail are produced here with `RealityRenderer`, RealityKit's
/// render-to-texture engine. The caller hands us a **detached clone** of the live
/// scene; we drive it through an orthographic camera into an offscreen Metal
/// texture and read that back into a `UIImage`.
///
/// ## Fail loud, never fake (deliberate — mirrors `StudioEnvironment`)
/// If any step fails (no Metal device, renderer / texture / camera-output creation,
/// or the render pass itself) this returns `nil` *after* surfacing the failure:
/// `assertionFailure` in debug, a console warning always. Callers must NOT invent a
/// substitute frame — a missing snapshot degrades to an instant, un-animated
/// material swap, and the failure is reported rather than masked. This matches the
/// project rule: never display a frame the renderer did not actually produce.
///
/// VERIFY ON DEVICE (no Xcode on the dev Mac, so these can't be compile-checked):
/// 1. The exact `updateAndRender` argument list — drawn from Apple's RealityRenderer
///    samples; if the build complains, adjust `whenScheduled` / `actionsBefore/After`.
/// 2. Whether `RealityRenderer`'s empty (no-geometry) pixels clear to *transparent*.
///    This code assumes they do, so the caller composites the frame over the mode's
///    background colour. If they clear to opaque black instead, the cross-fade will
///    flash the wrong backdrop — a loud, obvious on-device failure, by design.
@MainActor
enum OffscreenSnapshotRenderer {

    enum SnapshotError: Error, CustomStringConvertible {
        case noMetalDevice
        case rendererInitFailed(any Error)
        case textureAllocationFailed
        case cameraOutputFailed(any Error)
        case renderFailed(any Error)
        case textureReadbackFailed

        var description: String {
            switch self {
            case .noMetalDevice: return "no Metal device (MTLCreateSystemDefaultDevice returned nil)"
            case .rendererInitFailed(let e): return "RealityRenderer() threw: \(e)"
            case .textureAllocationFailed: return "MTLDevice.makeTexture returned nil"
            case .cameraOutputFailed(let e): return "RealityRenderer.CameraOutput init threw: \(e)"
            case .renderFailed(let e): return "updateAndRender threw: \(e)"
            case .textureReadbackFailed: return "could not build a CGImage from the rendered texture"
            }
        }
    }

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Render `scene` through `camera` into a `pixelSize`-sized `UIImage`, or `nil`
    /// (with a loud surfaced failure) if any step fails.
    ///
    /// - Important: `scene` and `camera` MUST be detached clones the caller owns.
    ///   Appending a live, parented entity to a second renderer removes it from the
    ///   on-screen scene — the exact bug this clone-first contract avoids.
    static func image(scene: Entity, camera: Entity, pixelSize: CGSize) async -> UIImage? {
        guard let device else { surface(.noMetalDevice); return nil }
        let width = max(Int(pixelSize.width.rounded()), 1)
        let height = max(Int(pixelSize.height.rounded()), 1)

        let renderer: RealityRenderer
        do {
            renderer = try RealityRenderer()
        } catch {
            surface(.rendererInitFailed(error)); return nil
        }

        renderer.entities.append(scene)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared   // CPU-readable after GPU completion (iOS unified memory)
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            surface(.textureAllocationFailed); return nil
        }

        let output: RealityRenderer.CameraOutput
        do {
            let descriptor = RealityRenderer.CameraOutput.Descriptor.singleProjection(colorTexture: texture)
            output = try RealityRenderer.CameraOutput(descriptor)
        } catch {
            surface(.cameraOutputFailed(error)); return nil
        }

        return await withCheckedContinuation { continuation in
            do {
                try renderer.updateAndRender(
                    deltaTime: 0,
                    cameraOutput: output,
                    whenScheduled: { _ in },
                    onComplete: { _ in
                        // Retain the renderer + output until the GPU work that backs
                        // this texture has finished; without these captures they can
                        // deallocate the instant `updateAndRender` returns.
                        _ = renderer
                        _ = output
                        let image = Self.makeImage(from: texture)
                        if image == nil { Self.surface(.textureReadbackFailed) }
                        continuation.resume(returning: image)
                    },
                    actionsBeforeRender: [],
                    actionsAfterRender: []
                )
            } catch {
                Self.surface(.renderFailed(error))
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Texture readback

    /// Copy a `.bgra8Unorm` texture into a `UIImage`. `nonisolated` so it can run on
    /// whatever thread `updateAndRender`'s completion handler fires on without an
    /// actor hop. The texture is `.shared`, so `getBytes` is valid once the GPU is
    /// done (which `onComplete` guarantees).
    nonisolated private static func makeImage(from texture: MTLTexture) -> UIImage? {
        let width = texture.width, height = texture.height
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        // BGRA8Unorm in memory is little-endian 32-bit ARGB: premultipliedFirst +
        // byteOrder32Little reads the B,G,R,A byte order back correctly.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return bytes.withUnsafeMutableBytes { buffer -> UIImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: rowBytes,
                    space: colorSpace, bitmapInfo: bitmapInfo),
                  let cgImage = context.makeImage() else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }

    nonisolated private static func surface(_ error: SnapshotError) {
        assertionFailure("Snug offscreen snapshot failed: \(error)")
        print("⚠️ Snug: offscreen snapshot unavailable — \(error)")
    }
}
