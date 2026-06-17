import Foundation
import Observation
import Vision
import CoreML
import CoreVideo

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
/// is the Vision `perform` (on `detectionQueue`); its result is bridged back and
/// every `@Observable` mutation in `processFrame` is wrapped in `MainActor.run`,
/// so observed state only ever changes on the main actor (no data races for
/// SwiftUI). `finalizeDetections` / `reset` are synchronous and called on main.
///
/// ## Not yet on device
/// `loadModel()` looks for `YOLO26nFurniture` in the bundle; until that asset
/// ships, `modelAvailable` is false (outside DEBUG) and the pipeline degrades to
/// the manual picker. The Vision parsing assumes an object-detection export that
/// yields `VNRecognizedObjectObservation`s (the standard Ultralytics CoreML
/// export with NMS). VALIDATE the label set + observation type before bundling.
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

    // MARK: - State (read from UI; mutated only on the main actor)
    private(set) var isRunning: Bool = false
    /// 0.0–1.0 for the pan progress bar.
    private(set) var progress: Double = 0.0
    private(set) var detectedObservations: [FurnitureObservation] = []

    /// Whether a usable CoreML model loaded. False until the asset is bundled (or
    /// in `#if DEBUG` synthetic mode), which routes the flow to the manual picker.
    private(set) var modelAvailable: Bool = false

    // MARK: - Private
    private var frameBuffer: [FurnitureObservation] = []
    private var processedFrames: Int = 0
    /// Loaded once; immutable after init. `nil` ⇒ synthetic (DEBUG) or unavailable.
    private let visionModel: VNCoreMLModel?
    /// Vision requests run here; results are bridged back and mutations hop to main.
    private let detectionQueue = DispatchQueue(label: "snug.furniture-detection")

    init() {
        let (model, available) = Self.loadModel()
        visionModel = model
        modelAvailable = available
    }

    // MARK: - Model loading

    /// Locate and wrap the bundled model. Returns the Vision model (nil if absent
    /// or in DEBUG synthetic mode) and whether the pipeline should run at all.
    private static func loadModel() -> (model: VNCoreMLModel?, available: Bool) {
        let compiled = Bundle.main.url(forResource: "YOLO26nFurniture", withExtension: "mlmodelc")
        let package = Bundle.main.url(forResource: "YOLO26nFurniture", withExtension: "mlpackage")

        #if DEBUG
        // Without the asset we still want the rendering / de-clutter path exercisable
        // in the simulator, so synthetic mode counts as "available" and `processFrame`
        // injects stand-ins.
        if compiled == nil && package == nil {
            print("ℹ️ Snug: YOLO26nFurniture not bundled — using DEBUG synthetic detections.")
            return (nil, true)
        }
        #endif

        guard let url = compiled ?? package else {
            print("⚠️ Snug: YOLO26nFurniture model not found — furniture detection disabled, manual picker offered.")
            return (nil, false)
        }
        do {
            let model = try MLModel(contentsOf: url)
            return (try VNCoreMLModel(for: model), true)
        } catch {
            print("⚠️ Snug: failed to load YOLO26nFurniture — \(error.localizedDescription). Manual picker offered.")
            return (nil, false)
        }
    }

    // MARK: - Frame processing

    /// Run detection on one frame. `ambientIntensity` is the ARKit light estimate
    /// in lux (passed as a plain `Double` to keep this layer ARKit-free); frames
    /// outside the usable band are counted toward progress but not detected on.
    func processFrame(_ pixelBuffer: CVPixelBuffer, ambientIntensity: Double?) async {
        await MainActor.run { isRunning = true }
        defer { Task { @MainActor in advanceProgress() } }

        if let lux = ambientIntensity, !Self.usableLuxRange.contains(lux) {
            return   // extreme lighting — skip, but still count the frame
        }

        #if DEBUG
        if visionModel == nil {
            await MainActor.run { injectSyntheticObservations() }
            return
        }
        #endif

        guard let observations = await runVision(on: pixelBuffer) else { return }
        await MainActor.run {
            frameBuffer.append(contentsOf: observations)
            detectedObservations = frameBuffer
        }
    }

    @MainActor
    private func advanceProgress() {
        processedFrames += 1
        progress = min(1.0, Double(processedFrames) / Double(Self.totalDetectionFrames))
    }

    /// Bridge Vision's completion-handler API to async. We await the request's
    /// completion before returning, so the `CVPixelBuffer` the handler holds can't
    /// be recycled mid-flight (the cross-thread deallocation hazard).
    private func runVision(on pixelBuffer: CVPixelBuffer) async -> [FurnitureObservation]? {
        guard let visionModel else { return nil }
        let timestamp = Date().timeIntervalSinceReferenceDate
        return await withCheckedContinuation { continuation in
            detectionQueue.async {
                let request = VNCoreMLRequest(model: visionModel)
                request.imageCropAndScaleOption = .scaleFill
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                do {
                    try handler.perform([request])
                    let results = (request.results as? [VNRecognizedObjectObservation]) ?? []
                    let mapped: [FurnitureObservation] = results.compactMap { result in
                        guard let top = result.labels.first,
                              top.confidence >= Self.minimumConfidence else { return nil }
                        let category = FurnitureCategory(rawValue: top.identifier)
                            ?? FurnitureCategory.fuzzyMatch(top.identifier)
                        return FurnitureObservation(
                            category: category,
                            confidence: top.confidence,
                            boundingBox: result.boundingBox,
                            frameTimestamp: timestamp
                        )
                    }
                    continuation.resume(returning: mapped)
                } catch {
                    print("⚠️ Snug: Vision request failed — \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
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
        return bestByCategory.values.compactMap { entry in
            entry.track.max { $0.confidence < $1.confidence }
        }
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

    // MARK: - Material (color sampling is the detector's device job; mapping is pure)

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
        processedFrames = 0
        progress = 0
        isRunning = false
    }

    #if DEBUG
    /// Seed plausible detections so the downstream rendering / de-clutter UI can be
    /// exercised in the simulator without the model asset: a sofa near center and a
    /// chair toward a corner, repeated each frame so they clear the consensus gate.
    @MainActor
    private func injectSyntheticObservations() {
        let t = Date().timeIntervalSinceReferenceDate
        frameBuffer.append(FurnitureObservation(
            category: .sofa, confidence: 0.92,
            boundingBox: CGRect(x: 0.30, y: 0.20, width: 0.40, height: 0.30), frameTimestamp: t))
        frameBuffer.append(FurnitureObservation(
            category: .chair, confidence: 0.81,
            boundingBox: CGRect(x: 0.05, y: 0.15, width: 0.20, height: 0.25), frameTimestamp: t))
        detectedObservations = frameBuffer
    }
    #endif
}

private extension FurnitureCategory {
    /// Map a model label that isn't an exact `rawValue` onto a category where the
    /// intent is obvious (e.g. a COCO-style "couch" or "diningtable"). Anything
    /// unrecognized becomes `.unknown` rather than being dropped, so a detection is
    /// never silently lost — the user can re-categorize it in the de-clutter step.
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
