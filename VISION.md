# Snug — Product Vision

This is the single source of truth for **what Snug is trying to become**.
CLAUDE.md holds the engineering rules; this holds the product. When a plan,
an idea, or a doc disagrees with this file, this file wins (or this file is
wrong and should be updated on purpose).

---

## One sentence

**Point at any piece of furniture, see it in a true-to-scale 3D copy of your
own room, judge whether it actually looks good and fits, then buy the one that
does.**

## The heart of it

Not "does it fit." Fit is the floor — it has to fit, and we tell the truth
about that. The real reason someone opens Snug is **"does it look good in my
room, with my other stuff, together?"**

It's the furniture version of trying clothes on before you buy. You can't tell
from a product photo on a white background whether a dresser works against your
wall, next to your bed, under your window. Snug lets you *see it* first, in
your actual space, before you spend the money.

---

## The core loop (the spine everything hangs off)

1. **Scan your room.** You get a measured 3D copy of your real room (accurate
   enough to trust the fit — an accuracy we keep proving; see the make-or-break
   bets at the end).
2. **Make it match reality.** Everything is editable so the model is truly
   *your* room: floor, walls, wall color/background, windows, doors, ceiling
   height. The closer it matches, the more you trust what you see.
3. **Search a real catalog.** A real, buyable catalog (starting small, growing
   to hundreds and beyond), each item with correct real-world dimensions and a
   real 3D model.
4. **Place them in your room.** Drop products in, arrange them, mix pieces.
5. **Judge it.** See if it looks good, if pieces go together, if it all fits.
   The honest fit check (fits / fits tight / too close to call / won't fit) is
   always there as the trust floor.
6. **Buy.** Tap out to the retailer through our affiliate link. Disclosed
   plainly, never changes the user's price.

That loop, working and feeling great, is V1. Every feature below bolts onto
this same spine.

## What "great" looks like (the bar for V1)

"Working and feeling great" needs a number or it's just a vibe. The bar: a
first-time user can scan a room, place 3–5 real products, get a fit verdict on
each, and produce a shareable before/after **in under ~3 minutes** — and want to
send it to someone. The signals we watch: **share of scans that reach at least
one placed product with a fit verdict**, and (once buy links are live)
**attributed purchases per active user**. If people scan and then bounce before
placing anything, the loop isn't great yet — fix that before adding features.

---

## The catalog

- Real products with **correct real-world dimensions** and a **real 3D model
  (USDZ)** you place in your room. The **size is exact** (it comes from the
  product's real dimensions, so the fit is guaranteed by the numbers); the
  **look** is the thing we're chasing — see the make-or-break bets at the end.
- **Amazon is the launch source** — for now, it's the one place with the
  metadata, dimensions, and product images we need to rebuild the 3D models
  without copyright problems. More stores come later.
- The models have to actually *look like the product*. A model rebuilt from a
  single photo can look right from the front and wrong from the back. Model
  **quality**, not just count, is the real work here, because the whole
  "does it look good" promise depends on it.
- **Guardrail (this keeps us honest while we chase the look):** when a generated
  model isn't good enough yet, we show a clean **true-scale archetype** (an
  honest placeholder at the exact real size) instead of a warped fake. We never
  render a bad model as if it were the truth. Bespoke, human-reviewed meshes lead
  on hero products first, and that reviewed set grows over time.

## Detecting existing furniture (the honest status)

Optionally, after a scan the app can detect the furniture already in the room
so you can clear it out. Today this is **rough**: it produces plain boxes, not
the real shape or look of the furniture, and it isn't very accurate. So it's a
"nice if it works" helper for de-cluttering and for marking occupied space in
the fit check — **not** a core promise. Don't over-invest in it until the spine
is great.

---

## The three "get any furniture in" features

These are what make it feel infinite instead of a boutique catalog. Each one is
just a new *way to get a product into the room* — the spine (place, judge, buy)
stays the same.

1. **Paste a link.** Paste an Amazon product link → we pull its data and image
   → build a 3D model → add it to your catalog and drop it in your room.
2. **Snap a photo.** Take a picture of furniture you saw (a store, a friend's
   place, anywhere) → we reverse-search to find that product online (and its
   real dimensions) → bring it into your room to see if it looks good.
   *(Honest note: pulling real measurements from a single photo is unreliable.
   The dependable version is "find the real product, which already has real
   dimensions," not "measure the pixels.")*
3. **Describe a room.** Tell us the vibe — "cozy, wood, has a bed and a desk" —
   and we suggest a preset layout built from your room's real data, so you get a
   starting point instead of a blank room.

## Sharing

**Before / after.** A clean way to show the transformation and share it. This
is also how the app spreads: good-looking before/afters get posted.

---

## Who it's for

Urban renters (roughly 22–35) furnishing a first or new apartment on a budget
around $500–$2,000. Runs on **any modern iPhone** (AR corner-tapping capture is
the default; LiDAR is an optional higher-accuracy path, not a requirement).
Catalog items are no-drill, no-paint, removable, deposit-safe.

## How it makes money

Affiliate commission on what people buy through Snug. The trust-and-buy loop
stays free so purchase volume is high; power/convenience features are where a
paid tier could live. We never paywall the fit check or the buy flow — those
*are* the revenue engine.

**The mechanic that matters:** Amazon's affiliate cookie lasts 24 hours and pays
on the user's *entire* cart, not just the item they clicked. So the
highest-leverage move is **whole-room checkout** ("furnish this room for $1,200"
→ one tap adds every piece), not single-item links. Home/furniture commission is
about 3%.

**Be honest about the risks** (they're why the longer-term / fundraising story in
`FounderPivot.md` reaches past pure affiliate): the rate is set by Amazon and has
been cut before, the 24-hour cookie is tight for a category people research for
weeks, and furniture is a rare purchase (roughly once every several years), so a
user's lifetime value is close to one basket. Affiliate is the wedge that funds
learning and proves the loop — not, by itself, the whole company.

## What Snug is NOT (non-goals)

- Not a general 3D/AR toy or a room-decor social network. It's a *buy real
  furniture that fits and looks good* tool.
- Not precise interior-design CAD. We round to the centimeter and always show the
  fit state; we never claim exact truth.
- Not a marketplace, checkout, or accounts product in V1 — we link out to the
  retailer with disclosure.
- Not trying to reconstruct your *existing* furniture accurately (detection stays
  rough on purpose).
- Not multi-room, not Android/iPad, not photorealistic rendering. (The full V1
  out-of-scope list lives in `CLAUDE.md`.)

## Why it's defensible (the moat)

The single-object AR tools (Apple QuickLook, Amazon "View in Your Room", IKEA
Place, Shopify AR) show *one* item, usually from *one* brand, with no saved
measured room and no fit math. Snug's edge is the combination: a **persistent,
measured, editable copy of your real room** + **many products from many brands
placed together** + **an honest fit verdict**. The deeper moat is the
reverse-search destination below: point at anything and get the real, buyable
version that fits. A single-retailer AR viewer structurally can't do that.

## Why people come back (retention)

Furniture is a rare purchase, so "use once, delete" is a real risk we design
against. The room is saved and reusable: you come back for the next piece (a rug,
a lamp, a desk), for a re-layout when life changes, and for the design-help and
inspiration features. A saved room you keep dropping products into is the reason
to reopen — not a one-shot fit check.

---

## What's built vs. what's next

**Built today:**
- Room capture (AR corner-tapping default) → editable `RoomModel`.
- The honest fit check (`FitService`, four states).
- One truthful 3D rendering (the old PLAY/BUY toggle was removed July 2026).
- A starter bedroom catalog (~15 real Amazon SKUs with real Tripo 3D meshes).
- The Amazon ingest + 3D-generation tooling (built, not yet run at scale
  against live keys).

**The spine still needs** (V1):
- Catalog *search* and a browsing experience that scales past 15 items.
- The "place real products and judge how it looks" experience polished to where
  it actually feels like trying furniture on.
- Editable room surfaces (walls, floor, background) wired through so the room
  truly matches reality.

**Next, in priority order** (paste-a-link is close to spine-level — it makes a
small catalog feel infinite with no research-grade ML and catches the
highest-intent user, someone who already picked a product, so build it early):
1. **Paste-a-link → 3D.** Highest priority after the spine; arguably part of it.
2. **Snap-a-photo → reverse-search → 3D.** This is the destination (see below).
3. Describe-a-room → preset layout suggestion.
4. First-person walkthrough ("step inside" preview at eye height).
5. More retailers beyond Amazon.

## The 10-star destination (where this is going)

The endgame is the reverse-search loop: **point at any piece of furniture — a
photo, a link, a description — and Snug finds the real, buyable version that
actually fits and looks good in your room.** IDEAS.md calls this "the company,"
and it's right. The browsable Amazon catalog in V1 is the on-ramp, not the
summit. Everything in the spine (measured room, honest fit, place-and-judge) is
built so that when the reverse-search backend turns on, the catalog goes from
"our hundreds of SKUs" to "anything you can point at" with no rewrite.

## The make-or-break bets (if these fail, the product fails)

1. **Model fidelity — the #1 bet.** "Does it look good" only works if the couch
   in your room looks like the couch you'd receive. We are betting that
   generative 3D, plus human review on hero products, gets good enough fast
   enough to hold that promise at scale. This is the make-or-break investment.
   Until a model clears the bar, it falls back to the honest true-scale archetype
   (see the catalog guardrail) so we never show a bad model as truth.
2. **Fit accuracy has two sources, and both have to hold.** (a) The room — we
   measure with the regular camera on non-LiDAR phones, so we keep proving that
   is accurate enough. (b) The product — the fit check runs on the item's *own*
   dimensions from Amazon metadata, and if those are missing or wrong the fit
   lies. Hide any product without trustworthy assembled dimensions; a missing
   product beats a wrong fit check.
3. **The affiliate mechanic has to actually pay.** See "How it makes money" — the
   model is real but carries real risk (rate, 24-hour cookie, rare purchases). We
   treat affiliate as the wedge that funds learning, not as the whole company.
