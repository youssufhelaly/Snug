import UIKit
import ImageIO

/// Decodes room thumbnails off the main thread, downsampled to tile size and
/// cached in memory.
///
/// `UIImage(data:)` inside a view body decodes the full image on the main
/// thread on every render. Rooms saved before thumbnails were stored
/// downscaled carry full-screen PNGs, so the room list could stall long enough
/// to drop touches. ImageIO's thumbnail path decodes straight to the target size.
enum ThumbnailDecoder {
    /// Longest side, in pixels, of a decoded room card picture (full width at 3x).
    static let tilePixelSize = 1200

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        return cache
    }()

    /// The cached image for `key`, if this thumbnail was already decoded.
    static func cachedImage(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// Decodes `data` on a background thread, downsampled to tile size, and
    /// caches it under `key`. Returns nil for unreadable data.
    static func image(forKey key: String, data: Data) async -> UIImage? {
        if let hit = cachedImage(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            downsample(data, maxPixelSize: tilePixelSize)
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// Decodes `data` directly at `maxPixelSize` on its longest side, without
    /// ever materializing the full-size bitmap.
    static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
