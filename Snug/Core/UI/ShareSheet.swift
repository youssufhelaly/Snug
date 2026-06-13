import SwiftUI
import UIKit

/// Identifiable wrapper so an exported file URL can drive `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Thin UIActivityViewController wrapper for exporting files (USDZ, fixture
/// JSON, accuracy CSV). SwiftUI's ShareLink wants its item up front; our
/// exports are generated on tap and may fail, so presentation has to happen
/// after the file exists — hence the representable.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
