import UIKit

/// Builds the shareable before/after image: the empty room above the
/// furnished one, branded, in a story-sized portrait frame.
///
/// This is Snug's growth loop (VISION.md): the image a user sends a friend or
/// posts is what brings the next user in. Both halves are true renders of the
/// room; nothing is stylized or retouched.
enum ShareImageComposer {
    /// A 9:16 story frame, the size Instagram, TikTok and Messages handle best.
    static let canvasSize = CGSize(width: 1080, height: 1920)
    /// Each render's size inside the frame. Snapshots should be rendered at
    /// exactly this size so nothing is resampled.
    static let panelSize = CGSize(width: 984, height: 720)

    private static let margin: CGFloat = 48
    private static let clay = UIColor(red: 0xE8 / 255, green: 0x71 / 255, blue: 0x4A / 255, alpha: 1)
    private static let clayDeep = UIColor(red: 0xD8 / 255, green: 0x65 / 255, blue: 0x3B / 255, alpha: 1)
    private static let cream = UIColor(red: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
    private static let ink = UIColor(red: 0x2B / 255, green: 0x27 / 255, blue: 0x22 / 255, alpha: 1)

    /// The caption under the panels, e.g. "4 real products · all 4 fit".
    /// Honest by construction: it counts only products whose fit check passed.
    static func caption(productCount: Int, fittingCount: Int) -> String {
        guard productCount > 0 else { return "Planning my room" }
        let products = productCount == 1 ? "1 real product" : "\(productCount) real products"
        let fit: String
        if fittingCount == productCount {
            fit = productCount == 1 ? "it fits" : "all \(productCount) fit"
        } else {
            fit = "\(fittingCount) of \(productCount) fit"
        }
        return "\(products) · \(fit)"
    }

    static func compose(before: UIImage, after: UIImage, roomName: String, caption: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            let cg = context.cgContext

            // Brand backdrop: the same terracotta gradient as the app's frame.
            let colors = [clay.cgColor, clayDeep.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: canvasSize.height), options: [])
            }

            var y: CGFloat = 96
            draw(roomName, font: rounded(64, .bold), color: .white, at: CGPoint(x: margin, y: y), maxWidth: canvasSize.width - margin * 2)
            y += 104

            for (label, image) in [("Before", before), ("After", after)] {
                let panel = CGRect(x: margin, y: y, width: panelSize.width, height: panelSize.height)
                drawPanel(image, in: panel, context: cg)
                drawChip(label, at: CGPoint(x: panel.minX + 24, y: panel.minY + 24))
                y = panel.maxY + 36
            }

            draw(caption, font: rounded(46, .semibold), color: .white, at: CGPoint(x: margin, y: y + 4), maxWidth: canvasSize.width - margin * 2)
            draw("Try furniture in your room before you buy · Snug", font: rounded(32, .medium),
                 color: UIColor.white.withAlphaComponent(0.85),
                 at: CGPoint(x: margin, y: canvasSize.height - 96), maxWidth: canvasSize.width - margin * 2)
        }
    }

    // MARK: - Drawing helpers

    private static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func draw(_ text: String, font: UIFont, color: UIColor, at point: CGPoint, maxWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = font.lineHeight * 1.2
        (text as NSString).draw(in: CGRect(x: point.x, y: point.y, width: maxWidth, height: height), withAttributes: attributes)
    }

    /// The render, aspect-filled into a rounded card with a soft shadow.
    private static func drawPanel(_ image: UIImage, in rect: CGRect, context cg: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 40)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 32, color: UIColor.black.withAlphaComponent(0.18).cgColor)
        cream.setFill()
        path.fill()
        cg.restoreGState()

        cg.saveGState()
        path.addClip()
        let scale = max(rect.width / max(image.size.width, 1), rect.height / max(image.size.height, 1))
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height))
        cg.restoreGState()
    }

    private static func drawChip(_ text: String, at origin: CGPoint) {
        let font = rounded(34, .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let chip = CGRect(x: origin.x, y: origin.y, width: textSize.width + 44, height: textSize.height + 20)
        cream.withAlphaComponent(0.92).setFill()
        UIBezierPath(roundedRect: chip, cornerRadius: chip.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: chip.minX + 22, y: chip.minY + 10),
                                withAttributes: [.font: font, .foregroundColor: ink])
    }
}
