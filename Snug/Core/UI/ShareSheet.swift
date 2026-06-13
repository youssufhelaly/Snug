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

extension View {
    /// Standard presentation for the "generate a file, then share it (or
    /// report why it failed)" pattern used by every export in the app: a
    /// share sheet driven by `shareItem` and a friendly error alert driven by
    /// `errorMessage`. Keeping it in one place means the export-failure copy
    /// and behavior can't drift between screens.
    func exportPresentation(
        shareItem: Binding<ShareItem?>,
        errorMessage: Binding<String?>
    ) -> some View {
        self
            .sheet(item: shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .alert(
                "Export didn't work",
                isPresented: Binding(
                    get: { errorMessage.wrappedValue != nil },
                    set: { if !$0 { errorMessage.wrappedValue = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage.wrappedValue ?? "")
            }
    }
}
