# Claude Code Prompt Pack v2 — "Snug" (working name)
### The renter-first room design app: scan → de-clutter → play → buy

**Changelog from v1** (so you know what moved and why):
- Phase 0 now requires a **logged accuracy distribution** against tape-measure ground truth — not a vibe of "~5cm"
- **New Phase 0.5**: bare-bones fit math validated *before* any styling work — trust number first, charm second
- Fit badge upgraded to **four uncertainty-honest states**, including "too close to call — measure this wall"
- Buy mode language aligned with reality: **true-to-scale, true-color** — not "photoreal." (Action item: update the pitch deck's slide 4/5 copy to match. The deck and the build must describe the same product.)
- Phase 4 descoped: V1 ships a **before/after image pair**; the orbit reveal video is a separately budgeted V1.1 project where one vetted third-party dependency is allowed
- Dropped the custom `schemaVersion` field — use **SwiftData's native VersionedSchema migrations** instead
- "Show 3 friends" demoted from acceptance gate to directional signal
- De-clutter de-romanticized: it's a satisfying step, not "the magic moment" — the scan is the magic moment
- Phase 0 now explicitly exports a **serialized CapturedRoom fixture** (capturing real RoomPlan output for tests is its own task, not a footnote)
- New ICP homework item: **LiDAR penetration** in your target demographic, before fundraising

---

## ⚠️ ADDENDUM — Capture pivot (2026-06): AR corner-tapping is now the default

Since this pack was written, capture **pivoted away from LiDAR/RoomPlan as the
primary path** so the app runs on non-Pro iPhones (the realistic ICP device).
What changed in the actual build:

- **`RoomCaptureMethod` protocol** abstracts capture; every method produces the
  app's own **`RoomModel`** (floor-corner polygon, ceiling height, openings,
  derived walls/dimensions). The editor, catalog, fit system, and accuracy
  logger depend only on `RoomModel`, never on how it was measured.
- **`ManualARCaptureMethod` (DEFAULT)** — ARKit `ARWorldTrackingConfiguration`
  (no LiDAR): coaching to find the floor, tap-to-raycast each floor corner with
  live markers + edge lengths, close the polygon, then optional door/window
  tapping. ARKit tracking quality is surfaced and low confidence is warned, not
  hidden. Per-session AR state lives in `ManualARCaptureController` (the method
  struct is a stateless factory); none of it leaks into `RoomModel` except the
  resolved ceiling height. Three capability upgrades layer on top:
  - **Floor baseline** — a weighted, spatially-deduplicated running average of
    floor taps (`sessionFloorY`); floor "locks" once cumulative weight > 2.0.
  - **High-wall projection** — a "Corner blocked?" toggle: tap the wall above a
    blocked corner and we keep its X/Z but snap Y to the floor baseline (falling
    back to `cameraTransform.columns.3.y − 1.4` if the floor isn't locked). A
    dotted vertical guide keeps aim true. This *replaces* the old two-tap
    wall-intersection solution (now deprecated, not deleted).
  - **Automatic ceiling height** — estimated, never typed: a passive pass runs
    all scan (feature points / mesh above floor + 1.8 m), with a conditional
    1-second "point at the ceiling" look-up at close. Resolution priority:
    RoomPlan (LiDAR) → active look-up → passive → 2.5 m default. The value is
    always shown with an edit control on the correction canvas.
  - **Conditional correction canvas** — the drag-to-correct floor-plan editor
    opens automatically when high-wall projection was used, the floor never
    locked, or the ceiling is low-confidence; otherwise the result screen offers
    an unobtrusive "Review layout" button. A standalone `GeometryValidator`
    (no self-intersection, walls > 0.3 m, area > 1.0 m²) gates the commit.
- **`RoomPlanCaptureMethod`** — the original LiDAR sweep, KEPT but demoted:
  offered only on Pro devices, never the default. Its `CapturedRoom` is
  converted into `RoomModel`. No RoomPlan code was deleted.
- **Accuracy logger is now method-agnostic** — `GroundTruthView` reads
  `RoomModel`, so tap-derived vs. tape-measured wall/diagonal/opening errors log
  to the same CSV regardless of capture method (the "Method" column replaces the
  old RoomPlan-confidence column, which is *more* useful: it lets you compare AR
  vs. LiDAR accuracy directly).
- Phase 0's accuracy gate is unchanged in spirit, but now you're validating the
  **AR corner-tapping** accuracy distribution, not LiDAR's. The diagonal-error
  proxy matters even more here.

This addendum supersedes LiDAR-specific assumptions in the phase prompts below;
read them as "the active capture method" rather than "RoomPlan" unless a prompt
is explicitly about the RoomPlan conformer.

---

## ⚠️ READ THIS FIRST — How to use this document

**Do NOT paste this entire document as one prompt.** That's the #1 way AI-coded apps fail: you get a beautiful demo that collapses on the first real feature.

Instead:

1. **Part 1** (`CLAUDE.md`) goes in the root of your repository. Claude Code reads it automatically at the start of every session — it's the project's permanent brain.
2. **Part 2** contains phase prompts. Feed them **one at a time**, in order. Do not start a phase until the previous phase's acceptance criteria pass **on a real device**.
3. After each phase, commit to git. If a phase goes sideways, `git reset` and re-prompt rather than patching a mess.

Prerequisites before your first prompt:
- A Mac with Xcode installed (free)
- Any modern iPhone with ARKit world tracking (roughly iPhone 8 / iOS 17+) for
  the default AR corner-tapping capture — a LiDAR Pro is now OPTIONAL, only
  needed to exercise the RoomPlan path. Neither ARKit nor RoomPlan runs in the
  simulator, so capture testing is still on-device.
- A tape measure. Seriously. Phase 0 needs ground truth.
- An Apple Developer account (free tier is fine for device testing)
- Claude Code installed and running in your project folder

**One business-homework item that is not code:** before you fundraise, find a real number for LiDAR-capable iPhone penetration among urban renters 22–35. Your beta sample (Pro-device owners) skews wealthier than your stated ICP — a great Phase 0 among them does not automatically generalize. Frame V1 honestly as "for LiDAR-equipped renters," and keep a manual-dimensions fallback mode in IDEAS.md as the V2 expansion path.

---
---

# PART 1 — `CLAUDE.md` (paste into repo root)

```markdown
# Snug — Project Context

## What this app is
Snug is a native iOS app for renters furnishing a new apartment.
The core loop: scan your room (10-second LiDAR sweep) → clear out
detected furniture → redesign in a playful stylized 3D view →
toggle to a true-to-scale, true-color "buy mode" → purchase real
furniture with an honest, uncertainty-aware fit check.

The product thesis in one line: **trust is the foundation, fun is
the brand.** Accurate geometry underneath, playful rendering on top.

## Who it's for (V1)
Urban renters, age 22–35, with a LiDAR-capable iPhone, furnishing
a first or new apartment on a budget of roughly $500–$2,000.
Everything in the catalog must be no-drill, no-paint, removable,
deposit-safe.

## Tech stack — do not deviate without asking
- Swift 5.10+, SwiftUI for all UI
- iOS 26.0 minimum deployment target
- RoomPlan for room capture (LiDAR devices only — detect capability
  at launch and show a graceful unsupported-device screen)
- RealityKit for the 3D room view and furniture placement
- SwiftData for local persistence (rooms, designs, saved items),
  using SwiftData's native VersionedSchema + SchemaMigrationPlan
  for model evolution. Do NOT add custom version fields to models.
- No third-party dependencies in the core app. One exception is
  pre-approved: the V1.1 video-export module may use a vetted
  Swift Package if offscreen RealityKit→AVFoundation composition
  proves too fragile by hand. Ask before adding it.
- No backend in V1. Everything local. Catalog ships as a bundled
  JSON + USDZ asset pack. Design models so a remote catalog can
  replace the bundled one later.

## Architecture rules
- MVVM. Views are dumb. ViewModels are @Observable classes.
  Business logic lives in plain services (RoomCaptureService,
  FitService, CatalogService, DesignStore), injected via
  environment.
- One feature = one folder under /Features
  (Capture, Editor, Catalog, Saved, Share, Onboarding).
- /Core holds shared services, models, and the design system.
- All RoomPlan / RealityKit work happens off the main thread
  except final scene mutations.
- Write code as if a second engineer joins next month: clear
  naming, no clever tricks, doc comments on every service's
  public API.

## Design system — "playful but trustworthy"
- Aesthetic: warm, rounded, optimistic. Think Headspace meets
  Nintendo, NOT corporate furniture catalog.
- Colors (define in Core/DesignSystem/Theme.swift as a single
  source of truth):
  - background: warm off-white #FAF7F2 (dark mode: #1C1A17)
  - primary accent "Clay": #E8714A
  - secondary "Sage": #7FA886
  - ink (text): #2B2722 (dark mode: #F0EDE8)
  - subtle: #8A847C
- Typography: SF Rounded for headings and buttons, SF Pro for
  body. Generous sizes — minimum body 16pt.
- Corners: 16pt radius on cards, 24pt on sheets, fully rounded
  pill buttons.
- Motion: spring animations (response 0.4, damping 0.8) on every
  state change. Bouncy and alive, never abrupt.
- Haptics on every meaningful action (scan complete, item placed,
  fit result shown).
- Empty states and errors are friendly, never blank or technical.
- Accessibility is not optional: Dynamic Type, VoiceOver labels on
  all interactive elements, reduced-motion variants.

## The two rendering modes (core product mechanic)
- PLAY MODE (default): stylized rendering — soft pastel material
  overrides, slightly exaggerated ambient lighting, simplified
  shadows. Fun to look at, fast to render.
- BUY MODE (toggle): TRUE-TO-SCALE, TRUE-COLOR. Catalog items
  render with their real material colors from the catalog data,
  neutral lighting, and visible dimension labels. We do not claim
  or attempt photorealism in V1 — accuracy of size and color is
  the promise, and stylization must never alter either in this
  mode. One-tap toggle, always visible, cross-fade < 400ms.

## The fit system (the trust layer — highest-stakes code in the app)
- FitService computes placement results against REAL scanned
  geometry, using ONE global error-margin constant in V1, set from
  Phase 0's measured accuracy data. (Per-room, confidence-weighted
  margins are a V2 idea — keep it in IDEAS.md.) It reports four
  states:
  1. "Fits with room to spare" — clearance > error margin × 2
  2. "Fits" — clearance > error margin
  3. "Too close to call — measure this wall" — clearance within
     the error margin. We TELL the user to grab a tape measure.
     This honesty IS the brand; never round it to a green check.
  4. "Won't fit" — negative clearance beyond the error margin
- FitService is pure, deterministic, and unit-tested against
  serialized real-scan fixtures. No UI code inside it. Treat any
  change to it as high-risk and test-first.

## Hard rules
- NEVER fake the scan. If RoomPlan fails or confidence is low,
  say so and offer a rescan. No silently invented geometry.
- Never display false precision. Dimensions shown to users are
  rounded to the centimeter and accompanied by the fit state, not
  presented as exact truth.
- No dark patterns: no fake urgency, no hidden costs. Affiliate
  relationships disclosed in UI copy.
- Build offline-first. Fully usable with no network in V1.

## Out of scope for V1 — do NOT build these even if tempted
Creator marketplace, accounts/auth, co-living multiplayer, room
health score, Android, iPad layouts, in-app checkout (V1 links out
to retailer with disclosure), multi-room projects, photorealistic
rendering, photographic inpainting, orbit reveal VIDEO export
(image pair only in V1 — video is a separately scoped V1.1
project), manual-dimensions mode for non-LiDAR devices (V2).

## Testing & quality bar
- Unit tests for all services using Swift Testing. FitService gets
  the deepest coverage, driven by real serialized CapturedRoom
  fixtures exported in Phase 0.
- Each phase ends with a manual on-device test script.
- Zero compiler warnings policy.
- Run and fix the build before declaring any task done.

## How to work with me
- Before writing code for any task, give me a 5-line plan and wait
  for my OK if the task touches more than 3 files.
- After completing a task: summarize what changed, list files
  touched, and give me the on-device test steps.
- If you're uncertain about an iOS API's behavior, say so and
  propose the safest approach — do not guess silently. This
  matters most for RoomPlan, RealityKit offscreen rendering, and
  AVFoundation, where confident hallucination is a known failure
  mode.
```

---
---

# PART 2 — Phase prompts (feed one at a time)

## Phase 0 — The feasibility spike + accuracy measurement (THE kill-question)
> Goal: prove the scan works AND produce the accuracy number the whole product rests on. Ugly is fine. Skipping the tape measure is not.

**Prompt 0.1:**
```
Create a new iOS app project structure for "Snug" following CLAUDE.md.
For this phase, build the absolute minimum: a single screen with a
"Scan my room" button that launches a RoomPlan capture session, and
on completion shows me:
1. The captured room rendered as a simple 3D model I can orbit/zoom
   (RealityKit, plain gray materials — no styling)
2. A debug panel listing detected walls, doors, windows, and objects
   with their dimensions in meters
3. RoomPlan's own confidence data surfaced per surface
4. An "Export USDZ" share button
5. An "Export fixture" button that serializes the full CapturedRoom
   result (via its Codable representation) to a JSON file and opens
   the share sheet. These fixtures are the foundation of all future
   FitService unit tests — treat this exporter as a real feature,
   not debug scaffolding, and verify a fixture re-imports cleanly.

ALSO build the accuracy logger:
6. A "Ground truth" debug screen where, after a scan, I can select
   any detected wall and type in its tape-measured real length. Also
   let me log one room DIAGONAL (corner to opposite corner) and one
   opening width per room — diagonal error is the real proxy for the
   clearance accuracy FitService depends on, since wall lengths can
   be right while corners are skewed. The app logs (scanned value,
   measured value, error, type: wall/diagonal/opening, room id,
   RoomPlan confidence) to a local CSV I can export. Show me a
   running summary: count, mean absolute error, max error, and the
   share within 2cm / 5cm / 10cm — broken out by type.

Handle these failure paths explicitly: device without LiDAR, camera
permission denied, scan cancelled mid-sweep, RoomPlan throwing
during processing. Each gets a friendly screen, not a crash.

Give me the plan first (5 lines), then build it. End with exact
steps to run this on my physical iPhone.
```

**Acceptance criteria — do not continue past Phase 0 until ALL pass:**
- [ ] Scans 3+ different *real, messy* rooms (small, cluttered, odd-shaped) producing recognizable geometry
- [ ] **Accuracy table exported**: ≥15 wall measurements across those rooms with tape-measure ground truth, giving you a real error distribution — write down the mean and max error; these numbers feed FitService's error margin and belong in your investor data room
- [ ] Survives 10 scans in a row without crashing
- [ ] At least 2 CapturedRoom fixtures exported and re-importable

**Interpreting the accuracy number (the actual gate):**
- Mean error ≤ ~3cm, max ≤ ~8cm → green light; the four-state fit badge works beautifully at these margins
- Mean ~3–6cm → proceed, but expect "too close to call" to fire often; the honest-uncertainty UX becomes even more central
- Mean > ~6–8cm or wildly inconsistent across rooms → **STOP. Pivot moment.** The "buy with confidence" thesis doesn't survive this; the photo-to-inspiration product is the fallback. Better to know in week 2 than month 6.

---

## Phase 0.5 — Bare-bones fit math (trust before charm)
> New in v2. The trust claim gets exercised BEFORE any styling exists.

**Prompt 0.5:**
```
Using only Phase 0's output (no styling, no catalog UI), build
FitService per CLAUDe.md's fit-system spec and a crude harness
around it:

1. FitService: pure Swift, no UI imports. Input: room geometry
   (walls, floor, openings, kept-object bounding boxes), a
   candidate item bounding box + position + rotation, and an
   error-margin parameter. Output: one of the four fit states plus
   the clearance values that produced it.
2. Wire the error margin to a settable constant initialized from
   my Phase 0 accuracy results (I'll give you the number).
3. Debug harness UI: in the gray Phase-0 room view, let me spawn a
   parametric test box (width/depth/height steppers), drag it on
   the floor, rotate it, and see the live fit state + clearances.
4. Unit tests against the Phase 0 fixtures: a box that obviously
   fits, one that obviously doesn't, one inside the error margin
   (must return "too close to call"), one overlapping a kept
   object, one snapped against a wall with a window. Edge cases:
   rotated boxes, non-rectangular rooms, boxes spanning an opening.

This is the highest-stakes code in the app. Plan first; test-first
where practical.
```

**Acceptance criteria:**
- [ ] A test box sized to your real sofa, placed where your real sofa is, returns a sane state
- [ ] A box 1cm inside the error margin returns "too close to call," never a green check
- [ ] All FitService tests pass against real-scan fixtures, not synthetic geometry only

---

## Phase 1 — The room becomes a place (stylized world + navigation)

**Prompt 1.1:**
```
Phases 0/0.5 pass. Now make the captured room feel like a place:

1. Convert RoomPlan output into our own RoomModel (Codable,
   SwiftData-persisted via VersionedSchema): walls, floor plane,
   openings, detected objects with bounding boxes. Reuse the
   fixture format from Phase 0 where sensible.
2. Render it in RealityKit with PLAY MODE styling per CLAUDE.md:
   warm pastel wall/floor materials, soft ambient light, simplified
   contact shadows. It should feel like a cozy diorama.
3. Camera: smooth orbit, pinch zoom, two-finger pan, with sensible
   limits (never below the floor, never inside walls). "Reset view"
   button with a spring animation.
4. Implement the PLAY/BUY mode toggle. BUY mode at this stage =
   neutral materials + visible wall dimension labels; true catalog
   colors arrive in Phase 3. Geometry must be IDENTICAL between
   modes — only materials and lighting change. Cross-fade < 400ms.
5. Persist scanned rooms; "My rooms" list with a RealityKit
   snapshot thumbnail.

Plan first. Unit-test the RoomPlan→RoomModel conversion against
the Phase 0 fixtures.
```

**Acceptance criteria:**
- [ ] Toggle is instant and geometry never changes between modes (overlay a debug wireframe to verify once)
- [ ] Rooms persist across app relaunches
- [ ] *Directional signal, not a gate:* show the diorama to a few people and watch reactions — treat enthusiasm as encouraging and politeness as noise; iterate on materials/lighting on your own taste either way

---

## Phase 2 — De-clutter (a satisfying step, honestly scoped)

**Prompt 2.1:**
```
Build the de-clutter step that runs right after a scan completes.
Scope honestly: V1 removes RoomPlan-DETECTED objects from the 3D
model. No photographic inpainting, and no UI copy implying photo
editing.

1. Show detected objects as a tappable list AND highlighted in the
   3D view.
2. Tap to "clear" — shrink-and-pop animation + haptic. Cleared
   objects are flagged, not deleted, so they can be restored.
3. "Clear everything" / "Keep everything" quick actions.
4. KEEP-THIS-ITEM anchor: a kept object gets a pin badge and its
   bounding box feeds FitService as occupied space (already
   supported from Phase 0.5 — wire it through).
5. Friendly UI copy: "What stays, what goes?"
```

**Acceptance criteria:**
- [ ] Clearing feels good (animation + haptic)
- [ ] Kept items affect fit results in the Phase 0.5 debug harness
- [ ] Restore works

---

## Phase 3 — Catalog & placement (the trust layer meets real products)

**Prompt 3.1:**
```
Build the furniture catalog and placement system on top of
FitService:

1. CatalogService loading a bundled catalog.json: ~30 items across
   sofa/bed/desk/chair/lamp/rug/shelf categories. Each item: id,
   name, category, dimensions (w/d/h in cm), price, retailer name,
   affiliate URL placeholder, renterSafe flags (noDrill, noPaint,
   freestanding), USDZ asset name, true material colors, and a
   stylized "play" color.
2. Source free/CC0 USDZ furniture models for placeholders, or
   generate simple parametric primitives per category — correct
   DIMENSIONS matter more than beauty in this phase.
3. Catalog browser: bottom sheet over the 3D view, category chips,
   renter-safe filter ON by default, budget slider live-filtering.
4. Placement: tap item → appears in room → drag on floor plane,
   rotation handle, snap-to-wall for shelves/desks. Placement calls
   FitService continuously. NEVER hard-block placement — the user
   may always place and save any item anywhere; the fit badge tells
   the truth instead. Blocking overrides user intent and contradicts
   the honest-fit philosophy.
5. THE FIT BADGE: surface FitService's four states on every placed
   item with clear visual language — including the honest
   "too close to call — measure this wall" state, which should
   feel helpful, not like an error.
6. BUY MODE now renders true material colors + dimension callouts
   on the selected item.
7. Running total price pill, always visible, number-roll animation.
```

**Acceptance criteria:**
- [ ] A sofa genuinely too big for your wall shows "won't fit"
- [ ] An item within the measured error margin shows "too close to call," and tapping it explains which wall to measure
- [ ] Budget slider + renter filter compose correctly
- [ ] 10 placed items keep 60fps on device

---

## Phase 4 — Save, share, and the before/after IMAGE engine (descoped, on purpose)

**Prompt 4.1:**
```
1. Designs: a Room can have multiple named Designs (saved furniture
   layouts). Duplicate, rename, delete with confirmation.
2. BEFORE/AFTER IMAGE PAIR export — V1's viral mechanic: render two
   matched RealityKit snapshots from the identical camera pose —
   (a) the cleared, unfurnished gray room, (b) the styled designed
   room — and compose them into a single shareable image in two
   layouts the user picks from: side-by-side 1:1 and top/bottom
   9:16. Subtle "made with Snug" watermark. System share sheet.
   No video in this phase.
3. Shopping list screen per design: items, prices, total, each row
   linking out to the retailer URL with the inline disclosure:
   "Snug may earn a commission — it never affects what we
   recommend."
```

**Acceptance xcriteria:**
- [ ] The exported image pair makes YOU want to post it
- [ ] Share sheet works to Photos, Messages, Instagram

> **V1.1 — Orbit reveal video (separately scoped project, budget ~a week, AFTER TestFlight):** offscreen RealityKit rendering composed via AVFoundation is the single most fragile pipeline in this pack and a known hallucination zone for AI coding tools. When you get to it: prototype the offscreen snapshot loop in isolation first, validate frame pacing on device, and if it fights you for more than two days, this is the one pre-approved place to bring in a vetted Swift Package. Do not let this feature block V1 shipping.

---

## Phase 5 — Onboarding & polish (the first 60 seconds decide everything)

**Prompt 5.1:**
```
1. Onboarding: 3 playful screens max (what it is → renter promise →
   scan tips like "open curtains, slow sweep"), then straight into
   the first scan. No account, no email, no paywall. Include the
   graceful unsupported-device path for non-LiDAR phones, with a
   "notify me when my device is supported" stub.
2. Scan coaching overlay during capture: live hints from RoomPlan's
   session feedback ("move slower", "scan that corner").
3. Full pass on empty/loading/error states — friendly, on-brand,
   clear next action.
4. App icon and launch screen matching the design system.
5. Performance pass: profile with Instruments guidance, fix editor
   hitches, cold launch under 2 seconds.
6. Accessibility audit per CLAUDE.md.
```

---

## Phase 6 — TestFlight & instrumentation

**Prompt 6.1:**
```
1. Lightweight local analytics (privacy-first, no third-party SDK):
   log funnel events to a local store with debug export —
   scan_started, scan_completed, scan_failed(reason),
   accuracy_sample_logged, declutter_done, first_item_placed,
   fit_state_shown(state), design_saved, image_pair_exported,
   retailer_link_tapped.
2. Crash-safe: wrap the capture and export pipelines so failures
   degrade gracefully and get logged.
3. Prepare for TestFlight: walk me through archive/upload, write
   tester notes, and create a 10-step beta test script focused on
   scan reliability across different rooms — including asking
   testers to log 3 tape-measured walls each, so the accuracy
   dataset grows beyond my own apartment and my own device.
```

---
---

# PART 3 — Working rules that will save you weeks

1. **One phase per Claude Code session.** Long sessions accumulate confusion. Start fresh, let it re-read CLAUDE.md.
2. **Test on device after every prompt**, not every phase. RoomPlan behavior on real hardware is the whole game.
3. **Commit after every working step.** Prompt history + git history = recovery from any mess.
4. **When something breaks, paste the FULL error** and say "fix the root cause, not the symptom."
5. **You are the art director.** Claude Code gets structure right; the *feel* (bounce, warmth, timing) needs your taste.
6. **Scope creep is the killer.** Every "while we're at it..." idea goes in IDEAS.md. Already seeded there: orbit video (V1.1), manual-dimensions mode for non-LiDAR devices (V2), inpainting de-clutter (V2+).
7. **The Lovable/web side runs in parallel**: style quiz + waitlist landing page, in a separate repo.
8. **The accuracy CSV is a fundraising asset.** "Mean wall error of X cm across N rooms and M devices" is worth more to a technical investor than any deck slide. Keep logging it through beta.

The fastest path to knowing whether you have a company is a scrappy Phase 0 with a real accuracy number, this week, on three messy real rooms. This document's only job is to get you there faster — close it and go scan.
