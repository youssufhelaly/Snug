**Project Overview**
- **Name:** Snug — a native iOS app for renters to scan rooms, place true-to-scale 3D furniture, and evaluate fit & style.
- **Why it exists:** Helps renters make confident buy decisions by visualizing real products in their real room with honest fit checks and dimension-aware placement.

**Highlights (for recruiters)**
- **Problem & impact:** Solves the hard UX problem of "will this furniture fit and look right?" by combining AR-assisted capture, accurate geometry, and a curated commerce catalog. Emphasize user trust: local-first persistence + transparent fit confidence margins.
- **Scale & complexity:** Combines AR (RealityKit / ARKit), SwiftUI, `SwiftData` persistence, unit-tested fit logic, and a production-quality catalog ingestion pipeline. The codebase contains feature-level separation, automated tests, and realistic fixtures used by tests.
- **Role-fit signals:** Clear engineering ownership (MVVM + services), unit test coverage for core algorithms (fit checks, footprint geometry), and clean separation of capture vs. catalog concerns — strong indicators for internships in systems, mobile, or applied ML teams.

**Tech Stack**
- **Language:** Swift 5.10+
- **UI:** SwiftUI (iOS 26+)
- **3D / AR:** RealityKit, ARKit (Manual AR capture + optional RoomPlan)
- **Persistence:** SwiftData (versioned schema + migrations)
- **Testing:** Swift unit tests (see `SnugTests`) — heavy coverage around `FitService` and geometry utilities
- **ML / Detection:** YOLO model bundles in `YOLO26nFurniture.mlpackage`

**Architecture & Design**
- **Pattern:** MVVM; Views are thin SwiftUI views, ViewModels are `@Observable` classes, core logic lives in plain service classes (e.g., `RoomStore`, `FitService`, `CatalogService`).
- **Key design rules:** Local-first data, never invent scans, round dimensions to cm, and clarify fit confidence rather than pretending precision.
- **Where to look:**
  - App entry: [SnugApp.swift](Snug/SnugApp.swift)
  - Capture flow: [App/RoomCaptureFlow.swift](Snug/App/RoomCaptureFlow.swift)
  - Core services & models: [Snug/Core/Services](Snug/Core/Services)
  - Rendering & Scene: [Snug/Features/RoomScene](Snug/Features/RoomScene)
  - Tests: [SnugTests](SnugTests)

**Key Features**
- AR-assisted manual room capture by corner-tapping (default, non-LiDAR friendly).
- Accurate fit evaluation with confidence margins (fit states + unit-tested `FitService`).
- RealityKit diorama + a truthful buy-overlay (dimensions, prices, fit state).
- Catalog integration with an ingest pipeline and cached offline fallback (`Resources/catalog.json`).
- Unit test suite covering geometry, placement validation, and model rendering.

**How to build & run (quick)**
- Open the workspace in Xcode and run on a device (AR requires a physical iPhone):

```bash
open Snug.xcworkspace
# In Xcode: select the Snug scheme and a physical device, then Run
```

- Run unit tests from Xcode (Product → Test) or command-line with `xcodebuild`:

```bash
xcodebuild -workspace Snug.xcworkspace -scheme Snug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' test
```

**What to call out in interviews**
- Architecture decisions: why MVVM + services, tradeoffs between ManualARCaptureMethod vs RoomPlan (LiDAR), and how RealityKit rendering is kept truthful rather than stylized.
- Testing strategy: fixtures for `FitService` and geometry edge cases; how rounding & confidence prevents overclaiming accuracy.
- Data & privacy: local-first SwiftData stores for rooms/designs; catalog is network-backed but degrades gracefully to cached data.

**Notable files (quick links)**
- App entry: [SnugApp.swift](Snug/SnugApp.swift)
- Capture flow: [App/RoomCaptureFlow.swift](Snug/App/RoomCaptureFlow.swift)
- Core services: [Snug/Core/Services](Snug/Core/Services)
- Design system: [Snug/Core/DesignSystem](Snug/Core/DesignSystem)
- Tests: [SnugTests](SnugTests)

**Tests & Quality**
- Unit tests live in the `SnugTests` folder. Examples:
  - [FitServiceTests.swift](SnugTests/FitServiceTests.swift)
  - [FurnitureDetectionServiceTests.swift](SnugTests/FurnitureDetectionServiceTests.swift)
- The project follows a zero-compiler-warnings policy and uses SwiftData versioned schema + migration plans.

**For recruiters — quick elevator pitch**
- "Snug helps renters avoid the cost and hassle of buying furniture that doesn't fit. I built the iOS app end-to-end: AR-assisted capture, a truthful 3D diorama, a robust fit-evaluation service with unit tests, and a production-feasible catalog ingestion and caching flow. The app balances UX, geometry correctness, and practical engineering tradeoffs for real devices."

**Future work / improvements to highlight in interviews**
- Add CI with iOS simulator tests + unit test reporting (fastlane or GitHub Actions) — CI workflow added at `.github/workflows/ci.yml`.
- Improve detection model pipeline reproducibility and model quantization for on-device inference.
- Add a small demo video or screenshots in `/Resources` for faster recruiter review.

**Contact & Next Steps**
- If you want, I can: add a runnable GitHub Actions badge by replacing `<OWNER>/<REPO>` in the badge URL, produce a short demo GIF from an on-device capture, or tailor the README to highlight specific contributions you want emphasized (system design, ML, or mobile engineering).

