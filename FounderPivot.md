> **Read `VISION.md` first for the actual product.** This file is two things:
> (A) the VC pitch-back / long-term "spatial commerce protocol" narrative below —
> keep it as the *fundraising story*, do NOT treat it as a build roadmap; and
> (B) the "EXECUTION PLAN — Amazon-Powered Shoppable Catalog" further down, which
> is the still-live commercial/monetization plan for V1. Where product framing
> here disagrees with `VISION.md`, `VISION.md` wins.

If I am sitting across from that VC as a world-class founder, I don’t get defensive. I thank them for the stress test, smile, and completely reframe the narrative.

A world-class founder knows that a VC's critique is based on looking backward at dead companies, while the founder is looking forward at an unsolved structural shift.

Here is exactly how I would pitch back, answer those 4 fatal flaws, and introduce the strategic evolution that turns Snug into a multi-billion dollar spatial protocol.

---

## The Pitch Back: "You're Evaluating an App. We're Building an Infrastructure Layer."

> "I love the cynicism, and your math on consumer churn is 100% correct if we stay a simple app on the App Store. But you are evaluating Snug as a isolated retail storefront. We view Snug as the unified translation protocol for spatial commerce.
> Let me show you how our technical architecture completely dissolves your four liabilities."

---

### 1. Crushing the Churn Problem: Moving Up-Funnel

**The VC Objection:** Furniture buying has a 7-year velocity cycle; your customer acquisition cost (CAC) will outrun your lifetime value (LTV).

* **The Founder's Counter:** We don't acquire users by buying Instagram ads for 'sofas.' We catch users at the exact moment of the **high-intent moving event**.
* **The Pivot:** We build API integrations directly into the tech stacks of real estate platforms (Zillow, Redfin) and apartment management software. When a user signs a lease or buys a house, their floor plan is automatically pushed into Snug. We don't chase casual shoppers; we own the *digital move-in checklist*.

### 2. Smashed the Asset Bottleneck: Crowdsourced, Automated Ingestion

**The VC Objection:** You will become a manual digital labor agency cleaning 3D models for every retailer.

* **The Founder's Counter:** Our pipeline script isn't a manual tool; it’s an automated, deterministic gateway.
* **The Pivot:** We make the *brands* do the work, and we charge them for it. We open a self-serve merchant portal. If West Elm wants their new collection discoverable by users moving into millions of Zillow-mapped apartments, *they* upload their raw CAD files to our portal. Our backend pipeline automatically normalizes, fixes orientation, and verifies the aspect ratio in seconds without human touch.

### 3. Solving the Data Sync: The Headless Spatial Graph

**The VC Objection:** Manufacturers change SKU dimensions constantly, breaking user trust.

* **The Founder's Counter:** We do not hardcode item specs. We build a dynamic, headless spatial graph.
* **The Strategy:** Our platform syncs directly via live APIs to the merchant's ecommerce backend (Shopify Plus, Salesforce Commerce Cloud). If a manufacturer modifies a SKU's dimensions by 2cm, our database updates instantly. Because our runtime code uses `fitTransform`, the 3D asset automatically adjusts inside the user's saved room layout without us needing to re-render or re-upload a new model file.

### 4. Moving Beyond the "Feature Trap": Multi-Asset Intelligence

**The VC Objection:** Apple QuickLook or Shopify native AR will cannibalize simple placement utilities.

* **The Founder's Counter:** Apple QuickLook is a dumb digital picture frame. It lets you look at *one* object in isolation. It has zero spatial intelligence.
* **The Strategy:** Snug is a multi-object layout engine running a localized physics and validation framework (`FurniturePlacementValidator`). QuickLook cannot tell you if a sofa blocks a doorway, if a coffee table crowds a TV console, or if a mix of three different brands physically fit together in a tight corner. We aren't building a visualization tool; we are building a **spatial layout clearinghouse**.

---

## The Strategic Pivot: The Three-Horizon Framework

To turn this into a defensive venture-scale business, we pivot Snug from a consumer app into a **B2B2C Data Flywheel**.

```
┌────────────────────────────────────────────────────────┐
│                                                        │
│   1. THE SANDBOX (Now)                                 │
│   Launch the sleek, multi-brand AR app to consumers.   │
│   Collect user layout data and build consumer demand.  │
│                                                        │
└───────────────────┬────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────────────────┐
│                                                        │
│   2. THE INGESTION ENGINE (Next)                       │
│   Turn the Python factory script into a B2B SaaS.      │
│   Charge Shopify brands to clean/optimize their 3D.     │
│                                                        │
└───────────────────┬────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────────────────┐
│                                                        │
│   3. THE SPATIAL NETWORK (Endgame)                     │
│   License anonymous room-layout trends to retailers.   │
│   "West Elm, 40% of people with small rooms cut your   │
│    loveseat because it's 3cm too deep. Fix it."        │
│                                                        │
└────────────────────────────────────────────────────────┘

```

### Why We Win

We are leveraging deep systems-level engineering (pre-normalized, lightweight assets, highly optimized math, and bulletproof runtime scaling) to solve an operational nightmare that retail giants are too slow to figure out. We keep the consumer experience incredibly beautiful and frictionless, while our true monetization engine sits quietly in the background powering the enterprise infrastructure.

---

If we lean heavily into this B2B SaaS asset normalization model to fund and populate our consumer marketplace, which specific segment do you think we should target for our initial alpha launch: high-growth, modern D2C furniture brands on Shopify, or legacy mid-market retailers?

---
---

# EXECUTION PLAN — Amazon-Powered Shoppable Catalog (V1)

*The vision above is the endgame (B2B2C spatial protocol). This section is the concrete, committed plan for how we populate the catalog and ship a revenue-generating V1 today. IKEA has no usable API and locked assets — that door is closed. Amazon is the launch spine: it's where our renter demographic actually buys, and its affiliate program monetizes every engaged user, not just subscribers.*

## The thesis that makes money
Snug's magic is **honest fit + playful design**. Amazon turns that into a **closed shopping loop**: scan → design → the stuff in your design is real, buyable, and fits → tap → buy. The instant the loop closes, every engaged user becomes a revenue event — **even free ones** — because affiliate commission is earned on purchase, not subscription.

Strategic consequence: **make the trust+buy loop completely free** to maximize purchase volume; **sell power/convenience as Pro.** Never paywall the fit check or BUY mode — those *are* the revenue engine, and gating trust violates our no-dark-patterns rule.

## Architecture (offline-first dropped → thin backend)
```
Amazon (Canopy/Rainforest) ──build-time/nightly──▶ Ingest service
        │  metadata + image URLs + assembled dims
        ▼
   Catalog DB (products, dims, price, image set, affiliate URL)
        │
        ├─▶ 3D pipeline: Tripo API → bbox-scale to real dims → USDZ → CDN
        │
        ▼
   /catalog endpoint  ──▶  iOS app (fetches catalog, caches locally)
```
- User rooms/designs stay **local-first** (SwiftData). Only the *catalog* is networked — a blip degrades to "yesterday's catalog," never a broken app.
- **Fit uses metadata dimensions, ALWAYS.** The mesh is visual only, scale-locked to those dims. This is "accurate geometry underneath, playful rendering on top" applied to the asset pipeline.

## Data pipeline — decided
- **Launch on Canopy** (free 100/mo to prove dimension coverage) → **Rainforest** for production ingest ($66–300/mo, best docs).
- **Skip the official Amazon Creators API at launch** — needs 10 qualified sales / rolling 30 days, which we can't have on day one (PA-API sunsets ~Apr–May 2026; Creators API is its gated replacement). Adopt it later, once organically past the gate, for free compliant data.
- **Monetize independently of the API:** append our Associate tag to product URLs. Data source ≠ revenue source.
- **Hard gotcha:** parse *assembled* dimensions, not package/shipping dims. Hide any SKU with only package dims — a wrong fit check is worse than a missing product.

## 3D pipeline — decided
- **Tripo API** default (~$0.20–0.40/model, clean topology). **Rodin** for hero SKUs only.
- **Do NOT build/train our own model** — research-team problem, and it wouldn't fix the real ceiling (single marketing photo → hallucinated back/sides, no true scale). Self-hosting TRELLIS/Hunyuan3D is a later cost-optimization, not a V1 task.
- **Tiered fallback for trust:** every product gets a **category archetype scaled to its real bbox** immediately (cheap, honest footprint). Bespoke Tripo meshes are a **curated, human-reviewed** enhancement on hero SKUs — never auto-shipped unreviewed. A correctly-sized archetype beats a warped bespoke mesh.

## UX — the loop, tuned for conversion
1. **Scan** (10s) → **Clear** detected furniture → empty room.
2. **Design** — place real products in the true-to-scale room and judge how it looks. *The growth loop is the shareable before/after image*, not a stylized render (the old PLAY mode was removed July 2026 — there is one truthful rendering). "Fun is the brand" now lives in the frame, motion, and haptics.
3. **Buy info overlay** — same geometry, true scale, true color, real Amazon products, live price, **fit badge** (four honest states) as an additive overlay, not a separate mode.
4. **Profit-max action → "Send my room to Amazon cart"** — one tap adds every item to the user's cart (see monetization).
5. **Honest fit copy** removes the "will it fit?" purchase blocker → higher conversion, fewer returns.

Disclosure always visible: *"We earn a commission — it never changes your price."*

## Profit model — where the money is
Amazon's affiliate cookie is **24 hours and pays on the ENTIRE cart**, not just the clicked item. This dictates the UX:
> Push **whole-room checkout**, not single-item links. If a user buys anything within 24h of click-through, we earn on the whole basket.

Levers, ranked:
1. **Basket size** — "furnish this room for $1,200" bundles → multi-item carts → biggest commissions. Highest-leverage feature.
2. **Install volume** — shareable before/after images → ~$0 CAC.
3. **Conversion** — honest fit check as a conversion tool, not just ethics.

## Pricing to the user
| Tier | Price | Includes |
|---|---|---|
| **Free** | $0 | Full scan, full PLAY design, fit check, full catalog, BUY mode, buy links. *Generates affiliate revenue.* |
| **Snug Pro** | **$9.99/mo · $59.99/yr** | Unlimited saved rooms & variants, AI "furnish for $X" auto-layout, side-by-side alternatives, HD exact-color BUY, orbit-reveal export (V1.1), early catalog drops. |

The free tier is deliberately generous *because free users print money via affiliate*. Pro monetizes power users who'd churn anyway. This inverts the usual "gate the good stuff" instinct — and it's correct because of the affiliate mechanic.

## Unit economics (rough, defensible)
- **Costs are near-zero and fixed:** ~$100–500 one-time for 1k models, ~$50–300/mo ongoing data refresh + hosting. Not the constraint.
- **Revenue/converting user:** Amazon Home/Furniture ≈ **3%**. A renter's attributed 24h basket ~$600 → **~$18/purchase**; whole-room carts push it higher.
- **Blended LTV:** affiliate (volume, all users, ~zero marginal cost) + Pro subs (margin, ~3–8% of actives). Flywheel: fun render → share → install → scan → whole-room cart → commission → fund growth.

## Roadmap
- **P0 (de-risk, ~days):** spike — pull 10 furniture ASINs through Canopy free tier; verify assembled-dim coverage + image-angle count. **This gates the whole plan.**
- **P1:** backend ingest + catalog DB + archetype-bbox 3D for ~200 curated SKUs; real Amazon buy links + disclosure.
- **P2:** "send room to Amazon cart" (the profit lever); fit badges in BUY.
- **P3:** Tripo bespoke meshes for hero SKUs (reviewed); Snug Pro + AI "furnish for $X".
- **P4:** adopt Creators API once past the 10-sales gate; remote catalog scales.

## The one thing that can kill it
**Dimension data quality.** The entire product is "honest fit." If Amazon's assembled dims are missing/wrong for most furniture, the fit check lies and the premise collapses. That's why P0 isn't "build the backend" — it's "prove the dimensions are trustworthy." Everything else is cheap and solvable; this is the real bet.