import UIKit

extension UIImage {
    /// A copy scaled down so its longest side is at most `maxPixelDimension`
    /// pixels, keeping the aspect ratio and transparency. Returns `self` when the
    /// image is already small enough, so it never upscales.
    ///
    /// Room thumbnails are captured at the full screen size (often 1290 × 2796
    /// px), but they're only shown as small list tiles, so storing them
    /// downscaled keeps the SwiftData store small and list decoding fast.
    func downscaled(toMaxPixelDimension maxPixelDimension: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard maxPixelDimension > 0, longest > maxPixelDimension else { return self }

        let factor = maxPixelDimension / longest
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
