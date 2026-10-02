import RealityKit

/// Pays RealityKit's one-time costs while the home screen is idle, so the first
/// room open doesn't stall its navigation animation.
///
/// A device trace showed room opens hanging for up to half a second, mostly on
/// first-use work: the first texture, the first materials, and 3D text meshes
/// for every furniture label. Doing that here, a little at a time, moves it out
/// of the moment the user is watching.
@MainActor
enum RealityWarmup {
    private static var didWarm = false

    /// Builds shared rendering resources and preloads `modelAssetNames` (the
    /// products in the room the user is most likely to open next). Safe to call
    /// repeatedly; the shared resources are only built once.
    static func prewarm(modelAssetNames: [String]) async {
        if !didWarm {
            didWarm = true
            _ = ContactShadow.sharedTexture()
            await Task.yield()
            _ = PhysicallyBasedMaterial()
            _ = UnlitMaterial()
            for category in FurnitureCategory.allCases {
                _ = FurnitureEntityBuilder.labelMesh(for: category)
                // One label per run-loop turn keeps the home screen responsive.
                await Task.yield()
            }
        }
        for name in Set(modelAssetNames) {
            _ = await CatalogModelLoader.shared.model(named: name)
        }
    }
}
