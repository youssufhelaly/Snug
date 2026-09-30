---
paths:
  - "Snug/Core/Services/FitService.swift"
  - "Snug/Core/Services/FitConfiguration.swift"
  - "Snug/Core/Models/FurnitureFootprint+FitObstacle.swift"
  - "Snug/Features/Fit/**"
---

# The fit system (the trust layer — highest-stakes code in the app)

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
- Per-obstacle margin widening via `FitObstacle.Confidence` (`.estimated` ⇒ 1.5×)
  is implemented by NORMALIZING each constraint's clearance by its multiplier and
  classifying against the base margin — the four-state thresholds scale linearly
  with the margin, so this is exact and leaves the all-`.measured` path
  byte-identical. It never blocks placement — only shifts toward "too close".
