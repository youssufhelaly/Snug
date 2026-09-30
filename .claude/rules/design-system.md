---
paths:
  - "Snug/Features/**"
  - "Snug/Core/DesignSystem/**"
  - "Snug/Core/UI/**"
---

# Design system — "playful but trustworthy"

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
