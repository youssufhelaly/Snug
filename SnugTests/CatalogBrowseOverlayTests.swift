import Testing
import Foundation
@testable import Snug

/// `CatalogBrowseOverlay.thumbnailSizedURL` rewrites Amazon media URLs to ask for
/// a ~300px card-sized image instead of the multi-megapixel original. It's pure
/// string surgery on user-facing image URLs, so every branch (the rewrite plus
/// each passthrough guard) is worth pinning — a wrong host/extension check would
/// silently break card art or download full-resolution originals per card.
struct CatalogBrowseOverlayTests {

    @Test func rewritesPlainAmazonJPEGToCardSize() {
        let url = URL(string: "https://m.media-amazon.com/images/I/71ABCdef.jpg")!
        let sized = CatalogBrowseOverlay.thumbnailSizedURL(url)
        #expect(sized.absoluteString == "https://m.media-amazon.com/images/I/71ABCdef._AC_SX300_.jpg")
    }

    @Test func passesThroughNonAmazonHost() {
        let url = URL(string: "https://example.com/images/sofa.jpg")!
        #expect(CatalogBrowseOverlay.thumbnailSizedURL(url) == url)
    }

    @Test func passesThroughAlreadySizedURL() {
        // A URL that already carries an Amazon size suffix contains "._" and must
        // be left untouched (never doubly-suffixed).
        let url = URL(string: "https://m.media-amazon.com/images/I/71ABCdef._AC_SX300_.jpg")!
        #expect(CatalogBrowseOverlay.thumbnailSizedURL(url) == url)
    }

    @Test func passesThroughNonJPEGExtension() {
        let url = URL(string: "https://m.media-amazon.com/images/I/71ABCdef.png")!
        #expect(CatalogBrowseOverlay.thumbnailSizedURL(url) == url)
    }
}
