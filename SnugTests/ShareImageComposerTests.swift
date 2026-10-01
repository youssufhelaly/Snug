import Testing
import UIKit
@testable import Snug

/// The shared before/after image: story-sized, with an honest caption.
struct ShareImageComposerTests {

    @Test func captionCountsOnlyWhatFits() {
        #expect(ShareImageComposer.caption(productCount: 4, fittingCount: 4) == "4 real products · all 4 fit")
        #expect(ShareImageComposer.caption(productCount: 3, fittingCount: 2) == "3 real products · 2 of 3 fit")
        #expect(ShareImageComposer.caption(productCount: 1, fittingCount: 1) == "1 real product · it fits")
        #expect(ShareImageComposer.caption(productCount: 0, fittingCount: 0) == "Planning my room")
    }

    @Test func composesAStorySizedImage() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let panel = UIGraphicsImageRenderer(size: ShareImageComposer.panelSize, format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: ShareImageComposer.panelSize))
        }
        let image = ShareImageComposer.compose(before: panel, after: panel, roomName: "Bedroom", caption: "Test")
        #expect(image.size.width * image.scale == ShareImageComposer.canvasSize.width)
        #expect(image.size.height * image.scale == ShareImageComposer.canvasSize.height)
    }
}
