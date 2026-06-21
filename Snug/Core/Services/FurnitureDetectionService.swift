import Foundation
import Observation
@preconcurrency import Vision
import CoreML
import CoreVideo
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Detects existing furniture from a short post-scan camera pan and resolves a
/// stable set of `FurnitureObservation`s via IoU-based consensus.
///
/// ## Layering
/// This is the Vision/CoreML edge of Phase 2. It deliberately does **not** import
/// ARKit: the capture controller pulls `CVPixelBuffer`s and the ambient-light
/// reading off the live `ARFrame` and feeds them in, so this class stays testable
/// with plain frames and the consensus math (`Self.consensus`) is pure.
///
/// ## Threading
/// Like `ManualARCaptureController`, this is driven entirely from the main thread:
/// the controller calls in from main-actor tasks. The one piece of off-main work
/// is the Vision `perform` + the per-region color sampling (both on
/// `detectionQueue`); the result is bridged back and every `@Observable` mutation
/// in `processFrame` is wrapped in `MainActor.run`, so observed state only ever
/// changes on the main actor (no data races for SwiftUI). `finalizeDetections` /
/// `reset` are synchronous and called on main. An `isProcessingFrame` guard drops
/// any frame that arrives while a previous one is still in flight, so a faster
/// caller can never stack Vision work or race the buffer.
///
/// ## The bundled model is `end2end` (NMS-free) — read before touching the parse
/// `YOLO26nFurniture.mlpackage` is an Ultralytics **end-to-end** export
/// (`nms=False`, `end2end=True`): a single image input (640×640) and a single
/// `MLMultiArray` output of shape `(1, 300, 6)` — up to 300 rows of
/// `[x1, y1, x2, y2, score, classIndex]`. Because it carries no object-detection
/// metadata, Vision yields a `VNCoreMLFeatureValueObservation` (a raw tensor),
/// **not** `VNRecognizedObjectObservation`. `parseDetections` decodes that tensor
/// directly. Two things to VALIDATE on device: (1) whether the box coords come out
/// in input pixels (0…640) or normalized (0…1) — we auto-detect by magnitude; and
/// (2) the box layout is xyxy top-left, which we flip to Vision's bottom-left.
///
/// ## Class set caveat
/// The export's `names` map is the **generic COCO-80 set**, not a furniture-
/// specific taxonomy. Only `chair`, `couch`, `bed`, and `dining table` map onto
/// `FurnitureCategory`; everything else (person, laptop, cup, …) is dropped rather
/// than surfaced as a phantom `.unknown` piece. The `names` map is read from the
/// model metadata at load, so a future furniture-retrained export needs no code
/// change here.
@Observable
final class FurnitureDetectionService {

    // MARK: - Configuration
    static let minimumConfidence: Float = 0.70
    static let minimumConsecutiveFrames: Int = 3
    static let minimumTrackDuration: TimeInterval = 1.5
    static let totalDetectionFrames: Int = 10
    /// Skip frames whose ambient light is implausibly low/high for a usable color
    /// + detection read (lux). Outside this band the frame is dropped, not trusted.
    static let usableLuxRange: ClosedRange<Double> = 200...2000
    /// The model's square input edge (from the export's `imgsz`). Used to normalize
    /// pixel-space box coords when the end2end output isn't already normalized.
    static let modelInputSize: Double = 640

    // MARK: - State (read from UI; mutated only on the main actor)
    private(set) var isRunning: Bool = false
    /// 0.0–1.0 for the pan progress bar.
    private(set) var progress: Double = 0.0
    private(set) var detectedObservations: [FurnitureObservation] = []

    /// Whether a usable CoreML model loaded. False until the asset is bundled (or
    /// in `#if DEBUG` synthetic mode), which routes the flow to the manual picker.
    private(set) var modelAvailable: Bool = false

    /// The most recent frame's raw detections, in normalized Vision space — drives
    /// the live bounding-box overlay while the user pans. Per-frame, so it flickers;
    /// the stable, gated tally the user reads is `liveConfirmedCount`.
    private(set) var liveRegions: [DetectedFurnitureRegion] = []
    /// Distinct furniture pieces confirmed by consensus so far — the honest
    /// "Found N" shown during a continuous scan. Recomputed each processed frame.
    private(set) var liveConfirmedCount: Int = 0
    /// The camera image's *oriented* (upright) pixel size, so the overlay and the
    /// floor raycast can map normalized boxes onto the aspect-fill viewport
    /// identically. Nil until the first frame is processed.
    private(set) var orientedImageSize: CGSize?

    /// Additive live-preview seam. Fires on the **main thread** with the raw,
    /// per-frame regions of the frame just processed — intended for an optional
    /// bounding-box overlay. This is *not* the resolved result: the controller
    /// still pulls confirmed furniture from `finalizeDetections()` after the sweep.
    /// Callers must capture `self` weakly to avoid retaining the controller.
    var onDetectionsUpdated: (([DetectedFurnitureRegion]) -> Void)?

    // MARK: - Private
    private var frameBuffer: [FurnitureObservation] = []
    private var processedFrames: Int = 0
    /// Drops overlapping frames so Vision work can't stack. Not observed.
    @ObservationIgnored private var isProcessingFrame: Bool = false
    /// Loaded once; immutable after init. `nil` ⇒ synthetic (DEBUG) or unavailable.
    private let visionModel: VNCoreMLModel?
    /// COCO class-index → label, read from the model's `names` metadata at load.
    private let classLabels: [Int: String]
    /// Vision requests + color sampling run here; results are bridged back and
    /// observed mutations hop to main.
    private let detectionQueue = DispatchQueue(label: "snug.furniture-detection")

    init() {
        let loaded = Self.loadModel()
        visionModel = loaded.model
        classLabels = loaded.labels
        modelAvailable = loaded.available
    }

    // MARK: - Model loading

    /// Initialize the bundled model through Xcode's generated `YOLO26nFurniture`
    /// class (compile-time type safety; no fragile runtime path lookup), wrap it
    /// for Vision, and read its `names` map. Returns the Vision model (nil in DEBUG
    /// synthetic mode or on failure), the class-label table, and whether the
    /// pipeline should run at all.
    private static func loadModel() -> (model: VNCoreMLModel?, labels: [Int: String], available: Bool) {
        do {
            let wrapper = try YOLO26nFurniture(configuration: MLModelConfiguration())
            let vision = try VNCoreMLModel(for: wrapper.model)
            let labels = parseClassNames(from: wrapper.model)
            return (vision, labels, true)
        } catch {
            print("⚠️ Snug: failed to load YOLO26nFurniture — \(error.localizedDescription).")
            #if DEBUG
            // Keep the rendering / de-clutter path exercisable in the simulator
            // without a working model load: synthetic mode counts as "available".
            print("ℹ️ Snug: using DEBUG synthetic detections.")
            return (nil, [:], true)
            #else
            print("⚠️ Snug: furniture detection disabled — manual picker offered.")
            return (nil, [:], false)
            #endif
        }
    }

    /// Parse the Ultralytics `names` metadata (a Python-dict string like
    /// `{0: 'person', 1: 'bicycle', …}`) into an index→label table. Returns empty
    /// if absent; detections then all fall through to `fuzzyMatch`.
    private static func parseClassNames(from model: MLModel) -> [Int: String] {
        guard let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let names = creator["names"],
              let regex = try? NSRegularExpression(pattern: "(\\d+)\\s*:\\s*'([^']*)'") else { return [:] }
        let ns = names as NSString
        var map: [Int: String] = [:]
        for match in regex.matches(in: names, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3,
                  let index = Int(ns.substring(with: match.range(at: 1))) else { continue }
            map[index] = ns.substring(with: match.range(at: 2))
        }
        return map
    }

    // MARK: - Frame processing

    /// Run detection on one frame.
    ///
    /// - Parameters:
    ///   - pixelBuffer: the camera frame. ARKit hands these out in the sensor's
    ///     native landscape-right orientation.
    ///   - orientation: how to rotate the buffer upright before inference. Defaults
    ///     to `.right`, correct for a portrait-held device — without it Vision
    ///     processes the room sideways and accuracy collapses.
    ///   - ambientIntensity: the ARKit light estimate in lux (a plain `Double` to
    ///     keep this layer ARKit-free); frames outside `usableLuxRange` are counted
    ///     toward progress but not detected on.
    func processFrame(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .right,
        ambientIntensity: Double? = nil
    ) async {
        // Drop the frame if a previous one is still being processed — never stack
        // Vision work or race the shared buffer.
        let accepted = await MainActor.run { () -> Bool in
            guard !isProcessingFrame else { return false }
            isProcessingFrame = true
            isRunning = true
            return true
        }
        guard accepted else { return }
        defer { Task { @MainActor in isProcessingFrame = false; advanceProgress() } }

        if let lux = ambientIntensity, !Self.usableLuxRange.contains(lux) {
            return   // extreme lighting — skip, but still count the frame
        }

        #if DEBUG
        if visionModel == nil {
            let regions = Self.syntheticRegions(timestamp: Date().timeIntervalSinceReferenceDate)
            await MainActor.run { ingest(regions, orientedImageSize: CGSize(width: 1080, height: 1920)) }
            return
        }
        #endif

        let oriented = Self.orientedSize(of: pixelBuffer, orientation: orientation)
        guard let regions = await runVision(on: pixelBuffer, orientation: orientation) else { return }
        guard !Task.isCancelled else { return }
        await MainActor.run { ingest(regions, orientedImageSize: oriented) }
    }

    /// Append a frame's regions to the rolling buffer, publish the live overlay
    /// state (latest boxes, oriented image size, gated tally), and fire the
    /// live-preview seam — all on the main actor.
    @MainActor
    private func ingest(_ regions: [DetectedFurnitureRegion], orientedImageSize size: CGSize?) {
        if let size { orientedImageSize = size }
        liveRegions = regions
        frameBuffer.append(contentsOf: regions.map(\.observation))
        detectedObservations = frameBuffer
        liveConfirmedCount = Self.consensus(
            from: frameBuffer,
            minConsecutiveFrames: Self.minimumConsecutiveFrames,
            minTrackDuration: Self.minimumTrackDuration
        ).count
        onDetectionsUpdated?(regions)
    }

    @MainActor
    private func advanceProgress() {
        processedFrames += 1
        progress = min(1.0, Double(processedFrames) / Double(Self.totalDetectionFrames))
    }

    /// Bridge Vision's completion-handler API to async. The Vision `perform` and the
    /// per-region color sampling both run on `detectionQueue`, and we await the
    /// whole block before returning — so the `CVPixelBuffer` the handler (and the
    /// sampler) reads can't be recycled mid-flight (the cross-thread deallocation
    /// hazard; the controller releases the `ARFrame` the instant this returns).
    private func runVision(
        on pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) async -> [DetectedFurnitureRegion]? {
        guard let visionModel else { return nil }
        let timestamp = Date().timeIntervalSinceReferenceDate
        let labels = classLabels
        // Safe: the buffer is handed to a serial queue and we await the
        // continuation, so it's never accessed concurrently (CVPixelBuffer isn't
        // Sendable, hence the explicit opt-out).
        nonisolated(unsafe) let buffer = pixelBuffer
        return await withCheckedContinuation { continuation in
            detectionQueue.async {
                let request = VNCoreMLRequest(model: visionModel)
                request.imageCropAndScaleOption = .scaleFill
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: buffer,
                    orientation: orientation,
                    options: [:]
                )
                do {
                    try handler.perform([request])
                    var regions = Self.parseDetections(request.results, labels: labels, timestamp: timestamp)
                    // Color sampling happens HERE, on the detection queue, while the
                    // pixel buffer is still retained — sampling after the frame is
                    // released would read a recycled buffer. Doing it now also keeps
                    // the heavy pixel work off the main thread (60 FPS rendering).
                    for i in regions.indices {
                        regions[i].color = Self.sampleColor(in: buffer, region: regions[i], orientation: orientation)
                    }
                    continuation.resume(returning: regions)
                } catch {
                    print("⚠️ Snug: Vision request failed — \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Decode the end2end model's `(1, 300, 6)` output tensor into regions. Each row
    /// is `[x1, y1, x2, y2, score, classIndex]`. Rows below `minimumConfidence` are
    /// dropped, as are detections whose class doesn't map onto a real furniture
    /// category (the model is generic COCO, so most classes aren't furniture).
    ///
    /// Coordinates: end2end CoreML may emit pixel coords (0…`modelInputSize`) or
    /// already-normalized coords — we auto-detect by magnitude and normalize. The
    /// model's box is top-left origin (image convention); we flip it to Vision's
    /// bottom-left so the rest of the pipeline (`iou`, `consensus`, the floor
    /// raycast) is unchanged. Pure given the tensor, so it's straightforward to test.
    static func parseDetections(
        _ results: [VNObservation]?,
        labels: [Int: String],
        timestamp: TimeInterval
    ) -> [DetectedFurnitureRegion] {
        guard let array = (results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              array.shape.count == 3 else { return [] }
        let rows = array.shape[1].intValue
        let cols = array.shape[2].intValue
        guard cols >= 6 else { return [] }

        var regions: [DetectedFurnitureRegion] = []
        for row in 0..<rows {
            func value(_ col: Int) -> Double { array[[0, row, col] as [NSNumber]].doubleValue }

            let score = Float(value(4))
            guard score >= minimumConfidence else { continue }

            var x1 = value(0), y1 = value(1), x2 = value(2), y2 = value(3)
            // Normalize pixel-space coords if needed (VALIDATE on device).
            if max(max(x1, y1), max(x2, y2)) > 1.5 {
                x1 /= modelInputSize; y1 /= modelInputSize
                x2 /= modelInputSize; y2 /= modelInputSize
            }
            x1 = x1.clamped01; y1 = y1.clamped01; x2 = x2.clamped01; y2 = y2.clamped01
            guard x2 > x1, y2 > y1 else { continue }

            let label = labels[Int(value(5).rounded())] ?? ""
            let category = FurnitureCategory(rawValue: label) ?? FurnitureCategory.fuzzyMatch(label)
            // Generic COCO export: drop anything that isn't furniture rather than
            // surfacing it as a phantom `.unknown` piece in the de-clutter UI.
            guard category != .unknown else { continue }

            // Top-left image box → Vision bottom-left normalized box.
            let visionBox = CGRect(x: x1, y: 1 - y2, width: x2 - x1, height: y2 - y1)
            regions.append(DetectedFurnitureRegion(
                category: category,
                confidence: score,
                visionBoundingBox: visionBox,
                frameTimestamp: timestamp
            ))
        }
        return regions
    }

    // MARK: - Consensus

    /// Resolve the buffered per-frame observations into confirmed detections —
    /// at most one per category. Pure; see `Self.consensus`. Call on the main
    /// thread (the controller does).
    func finalizeDetections() -> [FurnitureObservation] {
        isRunning = false
        let confirmed = Self.consensus(
            from: frameBuffer,
            minConsecutiveFrames: Self.minimumConsecutiveFrames,
            minTrackDuration: Self.minimumTrackDuration
        )
        detectedObservations = confirmed
        return confirmed
    }

    /// IoU-based rolling consensus. Two observations are the same physical object
    /// when their boxes overlap (IoU > threshold) AND share a category. Observations
    /// are linked into tracks; a track is confirmed when it spans ≥
    /// `minConsecutiveFrames` observations OR ≥ `minTrackDuration` seconds. Returns
    /// the highest mean-confidence confirmed track per category.
    ///
    /// Pure and deterministic (frame order is the input order), so it is unit-tested
    /// directly without Vision.
    static func consensus(
        from observations: [FurnitureObservation],
        minConsecutiveFrames: Int,
        minTrackDuration: TimeInterval,
        iouThreshold: Float = 0.3
    ) -> [FurnitureObservation] {
        var tracks: [[FurnitureObservation]] = []
        for obs in observations {
            // Link to the most-recent matching track (same category, IoU over
            // threshold against that track's latest box).
            let matchIndex = tracks.indices.last { i in
                guard let last = tracks[i].last, last.category == obs.category else { return false }
                return iou(last.boundingBox, obs.boundingBox) > iouThreshold
            }
            if let matchIndex {
                tracks[matchIndex].append(obs)
            } else {
                tracks.append([obs])
            }
        }

        func isConfirmed(_ track: [FurnitureObservation]) -> Bool {
            if track.count >= minConsecutiveFrames { return true }
            guard let first = track.first?.frameTimestamp, let last = track.last?.frameTimestamp else { return false }
            return (last - first) >= minTrackDuration
        }

        func meanConfidence(_ track: [FurnitureObservation]) -> Float {
            track.reduce(0) { $0 + $1.confidence } / Float(track.count)
        }

        // Best confirmed track per category, represented by its highest-confidence
        // observation (so the returned box/confidence is a real frame, not an average).
        var bestByCategory: [FurnitureCategory: (track: [FurnitureObservation], mean: Float)] = [:]
        for track in tracks where isConfirmed(track) {
            let category = track[0].category
            let mean = meanConfidence(track)
            if let existing = bestByCategory[category], existing.mean >= mean { continue }
            bestByCategory[category] = (track, mean)
        }
        return bestByCategory.values.compactMap { entry -> FurnitureObservation? in
            // Box + confidence come from the real best frame; color is aggregated
            // across the whole track so a single noisy read can't decide it.
            guard let representative = entry.track.max(by: { $0.confidence < $1.confidence }) else { return nil }
            return representative.withColorCategory(dominantColor(in: entry.track))
        }
    }

    /// The dominant sampled color across a track: the most frequent non-`.other`
    /// category (ties broken by first appearance, keeping consensus deterministic in
    /// input order). `.other` is treated as "no reading", so a few good reads beat
    /// many unreadable frames; if nothing was readable the result is `.other`.
    static func dominantColor(in track: [FurnitureObservation]) -> FurnitureColorCategory {
        var counts: [FurnitureColorCategory: Int] = [:]
        var firstIndex: [FurnitureColorCategory: Int] = [:]
        for (i, obs) in track.enumerated() where obs.colorCategory != .other {
            counts[obs.colorCategory, default: 0] += 1
            if firstIndex[obs.colorCategory] == nil { firstIndex[obs.colorCategory] = i }
        }
        guard !counts.isEmpty else { return .other }
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : firstIndex[a.key]! > firstIndex[b.key]!
        }!.key
    }

    /// Intersection-over-union of two normalized boxes.
    static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return Float(interArea / union)
    }

    // MARK: - Color sampling (device-side; perceptual mapping is pure elsewhere)

    /// Sample the dominant perceptual color of a detected region from the live
    /// frame's pixels.
    ///
    /// STUB. The real work — lock the buffer, intersect `region.uiKitBoundingBox`
    /// with the instance mask, average sRGB over a ~5×5 grid, hand it to
    /// `FurnitureColorClassifier` — is the remaining device-side task. It is invoked
    /// on `detectionQueue` (see `runVision`) so it runs while the `CVPixelBuffer` is
    /// still retained and never blocks the main thread. Returns `.other` until
    /// implemented.
    ///
    /// - Note: the sampled color flows all the way through — carried on the
    ///   `DetectedFurnitureRegion` → `FurnitureObservation.colorCategory`, aggregated
    ///   across the track by `consensus` (`dominantColor`), and written into the
    ///   persisted `FurnitureFootprint.appearance` by the controller.
    ///
    /// This detector is detection-only (no instance mask), so we sample the center
    /// 60% of the box to favor the object over its background. The frame is oriented
    /// upright first so the box (in oriented space) lines up, and CoreImage handles
    /// the camera's YUV→sRGB conversion. Returns `.other` if the crop can't be read.
    private static func sampleColor(
        in pixelBuffer: CVPixelBuffer,
        region: DetectedFurnitureRegion,
        orientation: CGImagePropertyOrientation
    ) -> FurnitureColorCategory {
        let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let extent = upright.extent
        guard extent.width > 1, extent.height > 1 else { return .other }

        // Center 60% of the box, normalized top-left.
        let box = region.uiKitBoundingBox
        let core = box.insetBy(dx: box.width * 0.2, dy: box.height * 0.2)
        guard core.width > 0, core.height > 0 else { return .other }

        // Normalized top-left → CIImage pixel rect (bottom-left origin → flip Y).
        let cropRect = CGRect(
            x: extent.minX + core.minX * extent.width,
            y: extent.minY + (1 - core.maxY) * extent.height,
            width: core.width * extent.width,
            height: core.height * extent.height
        ).integral
        guard cropRect.width >= 1, cropRect.height >= 1,
              let rgb = Self.averageRGB(of: upright, in: cropRect) else { return .other }
        return FurnitureColorClassifier.category(forRGB: rgb)
    }

    /// Shared CoreImage context + sRGB space for the area-average reduction (a
    /// context is expensive to build, so it's created once).
    private static let samplingContext = CIContext(options: [.cacheIntermediates: false])
    private static let samplingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// Mean sRGB (0–1 components) of an image region via `CIAreaAverage` — a GPU
    /// reduction to a single pixel, far cheaper than reading the crop by hand.
    private static func averageRGB(of image: CIImage, in rect: CGRect) -> SIMD3<Float>? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        samplingContext.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: samplingColorSpace)
        return SIMD3(Float(pixel[0]) / 255, Float(pixel[1]) / 255, Float(pixel[2]) / 255)
    }

    /// Heuristic material for a category (V2). Color extraction from the masked
    /// pixel grid lives device-side; the perceptual mapping is in
    /// `FurnitureColorClassifier` so it can be tested independently.
    func inferMaterial(for category: FurnitureCategory) -> FurnitureMaterialClass {
        .inferred(for: category)
    }

    // MARK: - Lifecycle

    func reset() {
        frameBuffer.removeAll()
        detectedObservations.removeAll()
        liveRegions.removeAll()
        liveConfirmedCount = 0
        orientedImageSize = nil
        processedFrames = 0
        progress = 0
        isRunning = false
        isProcessingFrame = false
    }

    /// The camera image's oriented (upright) pixel size — `.right`/`.left` swap the
    /// landscape buffer's dimensions to portrait, matching what Vision detected on.
    private static func orientedSize(of buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGSize {
        let w = CGFloat(CVPixelBufferGetWidth(buffer))
        let h = CGFloat(CVPixelBufferGetHeight(buffer))
        return orientation.swapsDimensions ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    #if DEBUG
    /// Plausible stand-in regions so the downstream rendering / de-clutter UI can be
    /// exercised without a working model load: a sofa near center and a chair toward
    /// a corner, repeated each frame so they clear the consensus gate.
    private static func syntheticRegions(timestamp: TimeInterval) -> [DetectedFurnitureRegion] {
        [
            DetectedFurnitureRegion(
                category: .sofa, confidence: 0.92,
                visionBoundingBox: CGRect(x: 0.30, y: 0.20, width: 0.40, height: 0.30),
                frameTimestamp: timestamp),
            DetectedFurnitureRegion(
                category: .chair, confidence: 0.81,
                visionBoundingBox: CGRect(x: 0.05, y: 0.15, width: 0.20, height: 0.25),
                frameTimestamp: timestamp),
        ]
    }
    #endif
}

// MARK: - DetectedFurnitureRegion

/// A single furniture detection in one frame, at the Vision/UI boundary.
///
/// It isolates the Vision↔UIKit Y-axis mismatch in one testable place: it stores
/// the raw `visionBoundingBox` (normalized, origin **bottom-left** per Vision) and
/// exposes a computed `uiKitBoundingBox` (origin **top-left**) for SwiftUI overlays
/// and pixel-level color samplers, which use top-left conventions.
///
/// This is a per-frame edge type for the live-preview seam and color sampling — it
/// is deliberately *not* a second source of truth for geometry. The canonical
/// persisted/consensus unit is `FurnitureObservation`; `observation` bridges to it.
struct DetectedFurnitureRegion: Identifiable, Equatable, Sendable {
    let id: UUID
    let category: FurnitureCategory
    /// Vision model confidence, 0.0–1.0.
    let confidence: Float
    /// Normalized box, origin bottom-left (Vision's convention).
    let visionBoundingBox: CGRect
    /// Perceptual color sampled on the detection queue (`.other` until device
    /// sampling lands). Carried for the live overlay; see `sampleColor`.
    var color: FurnitureColorCategory
    let frameTimestamp: TimeInterval

    init(
        id: UUID = UUID(),
        category: FurnitureCategory,
        confidence: Float,
        visionBoundingBox: CGRect,
        color: FurnitureColorCategory = .other,
        frameTimestamp: TimeInterval
    ) {
        self.id = id
        self.category = category
        self.confidence = confidence
        self.visionBoundingBox = visionBoundingBox
        self.color = color
        self.frameTimestamp = frameTimestamp
    }

    /// The same box with origin flipped to **top-left** (the UIKit/SwiftUI and
    /// pixel-sampler convention), via vertical inversion `1 - y - height`.
    ///
    /// - Important: this is a *top-left image-space* rect, not the final on-screen
    ///   rect. Mapping to actual view coordinates still needs the AR frame's
    ///   `displayTransform` for the current interface orientation.
    var uiKitBoundingBox: CGRect {
        CGRect(
            x: visionBoundingBox.minX,
            y: 1 - visionBoundingBox.minY - visionBoundingBox.height,
            width: visionBoundingBox.width,
            height: visionBoundingBox.height
        )
    }

    /// Bridge to the canonical consensus/persistence value type (shares `id`,
    /// carries the sampled `color` so consensus can aggregate it into the footprint).
    var observation: FurnitureObservation {
        FurnitureObservation(
            id: id,
            category: category,
            confidence: confidence,
            boundingBox: visionBoundingBox,
            frameTimestamp: frameTimestamp,
            colorCategory: color
        )
    }
}

private extension Double {
    /// Clamp to the normalized `0...1` range.
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

extension CGImagePropertyOrientation {
    /// Whether applying this orientation swaps width and height (a 90°/270° turn).
    var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }
}

// MARK: - Camera projection

/// Maps normalized points/rects in the camera's *oriented* (upright) image space —
/// **top-left origin** — onto a viewport that renders the feed aspect-**fill**
/// (RealityKit `ARView`'s default). Used by BOTH the live detection overlay and
/// the floor raycast so the boxes the user sees and the points we raycast agree;
/// having one definition is what keeps them from drifting.
///
/// Pure and value-typed, so the mapping is unit-testable without a camera.
struct CameraAspectFillProjection: Equatable {
    /// Oriented (upright) image dimensions, e.g. 1440×1920 for a portrait frame.
    let imageSize: CGSize
    let viewport: CGSize

    /// The aspect-fill scale and centering offset of the image within the viewport.
    private var fit: (scale: CGFloat, offset: CGPoint)? {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let scale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let displayed = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return (scale, CGPoint(x: (viewport.width - displayed.width) / 2,
                               y: (viewport.height - displayed.height) / 2))
    }

    /// A normalized top-left point → a viewport point.
    func point(_ normalizedTopLeft: CGPoint) -> CGPoint {
        guard let fit else {
            return CGPoint(x: normalizedTopLeft.x * viewport.width,
                           y: normalizedTopLeft.y * viewport.height)
        }
        return CGPoint(x: normalizedTopLeft.x * imageSize.width * fit.scale + fit.offset.x,
                       y: normalizedTopLeft.y * imageSize.height * fit.scale + fit.offset.y)
    }

    /// A normalized top-left rect → a viewport rect.
    func rect(_ normalizedTopLeft: CGRect) -> CGRect {
        let origin = point(normalizedTopLeft.origin)
        let scale = fit?.scale ?? (viewport.width / max(imageSize.width, 1))
        return CGRect(x: origin.x, y: origin.y,
                      width: normalizedTopLeft.width * imageSize.width * scale,
                      height: normalizedTopLeft.height * imageSize.height * scale)
    }
}

private extension FurnitureCategory {
    /// Map a model label that isn't an exact `rawValue` onto a category where the
    /// intent is obvious (e.g. a COCO-style "couch" or "diningtable"). Anything
    /// unrecognized becomes `.unknown`; `parseDetections` then drops it (the model
    /// is generic COCO, so most labels aren't furniture).
    static func fuzzyMatch(_ label: String) -> FurnitureCategory {
        switch label.lowercased().replacingOccurrences(of: " ", with: "") {
        case "couch", "settee":              return .sofa
        case "armchair", "chair":            return .chair
        case "diningchair":                  return .diningChair
        case "bed":                          return .bed
        case "desk":                         return .desk
        case "diningtable", "table":         return .diningTable
        case "coffeetable":                  return .coffeeTable
        case "dresser", "chestofdrawers":    return .dresser
        case "bookshelf", "bookcase":        return .bookshelf
        case "tvstand", "tvunit":            return .tvStand
        default:                             return .unknown
        }
    }
}
