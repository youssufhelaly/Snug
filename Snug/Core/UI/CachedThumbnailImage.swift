import SwiftUI
import ImageIO

/// A remote thumbnail that stays put once loaded.
///
/// `AsyncImage` refetches on every appearance and treats a transient network
/// blip as a permanent failure, which made catalog cards randomly show their
/// fallback swatch. This view fixes both: decoded images live in a shared
/// in-memory cache keyed by URL (scrolling away and back is instant), the
/// download is retried once before giving up, and the full-resolution photo is
/// downsampled off the main thread to the card's pixel size so 180 cards don't
/// hold 180 multi-megapixel decodes.
struct CachedThumbnailImage<Placeholder: View>: View {
    let url: URL
    /// The display size the image will be shown at, in points.
    let targetSize: CGSize
    /// `.fill` crops the photo to cover the frame; `.fit` letterboxes it whole.
    /// Use `.fit` for product shots on white backgrounds — filling zooms and
    /// crops them past the tile bounds.
    var contentMode: ContentMode = .fill
    /// Shown while loading and after a failed load (e.g. offline).
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
        }
        .task(id: url) { await load() }
    }

    // Runs on the MainActor so the `@State` writes below (`image`, `isLoading`,
    // and the `withAnimation` swap) happen on the main thread — SwiftUI requires
    // it, and `.task` calling a `nonisolated async` method would otherwise run
    // this body off-main. The network `await` suspends without blocking main, and
    // the CPU-heavy decode already hops off-main via `Task.detached` in `downsample`.
    @MainActor
    private func load() async {
        if let cached = ThumbnailCache.shared.image(for: url) {
            image = cached
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        // One retry with a short pause covers the transient failures
        // (cell blips, server hiccups) that used to leave a swatch forever.
        for attempt in 0..<2 {
            if Task.isCancelled { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                guard let decoded = await Self.downsample(
                    data, to: targetSize, scale: displayScale
                ) else {
                    throw URLError(.cannotDecodeContentData)
                }
                ThumbnailCache.shared.store(decoded, for: url)
                withAnimation(.easeIn(duration: 0.15)) { image = decoded }
                return
            } catch is CancellationError {
                return
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                if attempt == 0 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    /// Decodes `data` at no more than `size` × `scale` pixels, off the main thread.
    private static func downsample(
        _ data: Data, to size: CGSize, scale: CGFloat
    ) async -> UIImage? {
        let maxPixel = max(size.width, size.height) * scale
        return await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary
            ) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

/// Process-wide in-memory cache of decoded, downsampled thumbnails.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
