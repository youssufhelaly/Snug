import Foundation
import Testing
import simd
@testable import Snug

/// The pure fit math behind the BUY-mode realistic product model. The async USDZ
/// load + RealityKit attach are device-verified (no model assets in the repo); the
/// scale/recenter arithmetic that maps a model's bounds onto a footprint's real
/// dimensions is unit-tested here.
struct CatalogModelLoaderTests {

    @Test func scalesUnitModelToTargetDimensionsWithAxisMapping() {
        // A 1×1×1 model centered at origin, fit into a (w 2, d 0.5, h 1.5) box.
        // Axis mapping: width→X, height→model Y(up), depth→model Z.
        let fit = CatalogModelLoader.fitTransform(
            modelExtents: SIMD3(1, 1, 1),
            modelCenter: .zero,
            targetDimensions: SIMD3(2.0, 0.5, 1.5))
        #expect(fit.scale.x == 2.0)   // width
        #expect(fit.scale.y == 1.5)   // height (footprint z → model Y)
        #expect(fit.scale.z == 0.5)   // depth  (footprint y → model Z)
        #expect(fit.position == .zero)
    }

    @Test func nonUnitModelScalesByItsExtents() {
        // A model that is 2 m wide, 4 m tall, 0.5 m deep in its own space.
        let fit = CatalogModelLoader.fitTransform(
            modelExtents: SIMD3(2, 4, 0.5),
            modelCenter: .zero,
            targetDimensions: SIMD3(1.0, 0.6, 2.0))   // (width, depth, height)
        #expect(abs(fit.scale.x - 0.5) < 1e-6)        // width  1.0 / 2
        #expect(abs(fit.scale.y - 0.5) < 1e-6)        // height 2.0 / 4   (footprint z → model Y)
        #expect(abs(fit.scale.z - 1.2) < 1e-6)        // depth  0.6 / 0.5 (footprint y → model Z)
    }

    @Test func recentersAnOffOriginModelOntoTheBoxCenter() {
        // Model bounds centered at (0, 0.5, 0) — its base on the floor, not its
        // center. After scaling, the position must cancel that offset so the model
        // is centered on the box (the box mesh is centered on worldPosition).
        let fit = CatalogModelLoader.fitTransform(
            modelExtents: SIMD3(1, 1, 1),
            modelCenter: SIMD3(0, 0.5, 0),
            targetDimensions: SIMD3(1, 1, 2))   // height scale = 2
        // position = -center * scale  ⇒  y = -0.5 * 2 = -1.0
        #expect(fit.position.y == -1.0)
        #expect(fit.position.x == 0)
        #expect(fit.position.z == 0)
    }

    @Test func zeroExtentAxisDoesNotDivideByZero() {
        // A flat (degenerate) model axis must not produce inf/nan scale.
        let fit = CatalogModelLoader.fitTransform(
            modelExtents: SIMD3(0, 1, 1),
            modelCenter: .zero,
            targetDimensions: SIMD3(1, 1, 1))
        #expect(fit.scale.x.isFinite)
        #expect(fit.scale.x == 1.0)   // safe() falls back to /1
    }

    // MARK: - Verified-track zero-scaling guard

    @Test func nativeSizeDeviation_exactMatchIsZero() {
        // Model extents (x: width, y: height, z: depth) exactly equal the catalog
        // dims (x: width, y: depth, z: height) under the axis mapping.
        let d = CatalogModelLoader.nativeSizeDeviation(
            modelExtents: SIMD3(2.18, 0.84, 0.91),     // w, h, d
            targetDimensions: SIMD3(2.18, 0.91, 0.84)) // w, d, h
        #expect(d == 0)
    }

    @Test func nativeSizeDeviation_returnsLargestPerAxisGap() {
        // Height off by 0.05 (model Y 0.89 vs target height 0.84); width/depth exact.
        let d = CatalogModelLoader.nativeSizeDeviation(
            modelExtents: SIMD3(2.18, 0.89, 0.91),
            targetDimensions: SIMD3(2.18, 0.91, 0.84))
        #expect(abs(d - 0.05) < 1e-6)
    }

    @Test func nativeSizeDeviation_subCentimeterIsWithinTolerance() {
        // Every axis off by 0.005 m — a real asset's authoring rounding. Must pass.
        let d = CatalogModelLoader.nativeSizeDeviation(
            modelExtents: SIMD3(2.185, 0.845, 0.905),
            targetDimensions: SIMD3(2.18, 0.91, 0.84))
        #expect(d <= CatalogModelLoader.verifiedModelTolerance)
    }

    @Test func nativeSizeDeviation_axisSwapIsCaughtNotMasked() {
        // A model authored with depth/height transposed (a real mis-export) must
        // read as a large deviation, not slip through.
        let d = CatalogModelLoader.nativeSizeDeviation(
            modelExtents: SIMD3(2.18, 0.91, 0.84),      // h and d swapped vs below
            targetDimensions: SIMD3(2.18, 0.91, 0.84))  // w, d=0.91, h=0.84
        #expect(d > CatalogModelLoader.verifiedModelTolerance)
    }

    // MARK: - Approximate-track footprint fit (Tripo / archetype meshes)

    @Test func approximateAssetPrefixesAreRecognized() {
        #expect(CatalogModelLoader.isApproximateAsset("tripo_B072DY2MHK"))
        #expect(CatalogModelLoader.isApproximateAsset("quaternius_Sofa"))
        #expect(!CatalogModelLoader.isApproximateAsset("sofa_lina_verified"))
    }

    @Test func cleanMeshFitsExactlyOneToOneOnAllAxes() {
        // A clean mesh proportioned like the real product must land at exactly the
        // catalog dims — footprint AND height (the 1:1 promise).
        let fit = CatalogModelLoader.approximateFitTransform(
            modelExtents: SIMD3(1.0, 0.4, 0.25),        // model axes (w, h, d)
            modelCenter: .zero,
            targetDimensions: SIMD3(2.0, 0.5, 0.8))     // footprint (w, d, h)
        #expect(fit.yRotation == 0)
        #expect(abs(fit.scale.x - 2.0) < 1e-5)          // width  2.0 / 1.0
        #expect(abs(fit.scale.z - 2.0) < 1e-5)          // depth  0.5 / 0.25
        #expect(abs(fit.scale.y - 2.0) < 1e-5)          // height snapped: 0.8 / 0.4
    }

    @Test func rotatedMeshIsDetectedAndFootprintStaysExact() {
        // The pilot bed: Tripo output it long along X, but the real bed is long
        // along DEPTH (w 1.52 × d 2.06). The fit must choose the 90° yaw and still
        // deliver an exact real footprint.
        let fit = CatalogModelLoader.approximateFitTransform(
            modelExtents: SIMD3(1.0, 0.471, 0.742),     // normalized Tripo bbox
            modelCenter: .zero,
            targetDimensions: SIMD3(1.52, 2.06, 0.94))
        #expect(fit.yRotation == .pi / 2)
        // Under 90° yaw: world width comes from local Z, world depth from local X.
        #expect(abs(fit.scale.z * 0.742 - 1.52) < 1e-3)  // world width exact
        #expect(abs(fit.scale.x * 1.0 - 2.06) < 1e-3)    // world depth exact
    }

    @Test func clutterTallMeshKeepsProportionalHeightNeverSquashed() {
        // The pilot desk: monitors modeled on top make the mesh proportionally much
        // taller than the real 0.75 m desk. Height must stay proportional (taller),
        // NOT be forced to 0.75 — squashing would sink the desktop to coffee height.
        let extents = SIMD3<Float>(1.0, 0.6664, 0.4111)  // Tripo desk bbox (w,h,d)
        let target = SIMD3<Float>(1.37, 0.50, 0.75)      // real (w, d, h)
        let fit = CatalogModelLoader.approximateFitTransform(
            modelExtents: extents, modelCenter: .zero, targetDimensions: target)
        let renderedHeight = fit.scale.y * extents.y
        #expect(renderedHeight > target.z)               // taller than real…
        let footUniform = Float((1.37 / 1.0) * (0.50 / 0.4111)).squareRoot()
        #expect(abs(renderedHeight - extents.y * footUniform) < 1e-4) // …proportionally
        // Footprint still exact 1:1.
        #expect(abs(fit.scale.x * extents.x - 1.37) < 1e-3)
        #expect(abs(fit.scale.z * extents.z - 0.50) < 1e-3)
    }

    @Test func slightlyTallMeshSnapsToExactCatalogHeight() {
        // Proportional height within the 10% clutter tolerance → treat as clean and
        // snap to the exact catalog height (true 1:1), not the proportional value.
        let extents = SIMD3<Float>(1.0, 0.53, 0.5)       // prop height would be 0.53
        let target = SIMD3<Float>(1.0, 0.5, 0.5)         // real height 0.5 (6% over)
        let fit = CatalogModelLoader.approximateFitTransform(
            modelExtents: extents, modelCenter: .zero, targetDimensions: target)
        #expect(abs(fit.scale.y * extents.y - 0.5) < 1e-5)
    }

    @Test func rotatedOffOriginMeshRecentersUnderTheYaw() {
        // Center offset along local X must cancel along world Z after the 90° yaw
        // (position = -R·(center·scale)), keeping the mesh centered on the box.
        let fit = CatalogModelLoader.approximateFitTransform(
            modelExtents: SIMD3(2.0, 1.0, 1.0),
            modelCenter: SIMD3(0.5, 0, 0),
            targetDimensions: SIMD3(1.0, 2.0, 1.0))      // long side is depth → rotate
        #expect(fit.yRotation == .pi / 2)
        #expect(abs(fit.position.x) < 1e-5)              // no world-X leakage
        #expect(abs(fit.position.z) > 1e-3)              // offset moved to world Z
    }

    @Test func approximateFitDegenerateAxisIsSafe() {
        let fit = CatalogModelLoader.approximateFitTransform(
            modelExtents: SIMD3(0, 1, 1),
            modelCenter: .zero,
            targetDimensions: SIMD3(1, 1, 1))
        #expect(fit.scale.x.isFinite && fit.scale.y.isFinite && fit.scale.z.isFinite)
    }
}
