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
}
