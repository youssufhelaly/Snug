# Catalog asset pipeline

One-time developer toolchain that turns free 3D furniture (Quaternius, Kenney,
ITHappy, …) into ARKit-valid USDZ for Snug's BUY-mode catalog. Nothing here ships
in the app — it produces the `.usdz` files that land in `Snug/Resources/Models/`.

## Why this exists / the architecture decision

The app's `CatalogModelLoader.fitTransform` re-centers and **per-axis stretches**
every model to the SKU's real catalog dimensions at load time. That is correct and
stays — the scale is a property of the *(asset, SKU) pairing*, not the asset, and
one shape is reused across SKUs at different sizes (the `sofa` shape backs both the
Lina 3-seat **2.18 m** and the Koble loveseat **1.62 m**), so the fit cannot be
baked offline. See the long-form rationale in the catalog section of `CLAUDE.md`.

What the per-axis stretch *can* do is distort a model whose native proportions are
far from the SKU's ("taffy legs"). The distortion is purely a function of
aspect-ratio **mismatch**. So this pipeline's job is:

1. **Orientation** — bake every asset to RealityKit's **Y-up / -Z-forward**.
2. **Proportion profiling** — measure each asset's native aspect ratio.
3. **The guardrail** — refuse to pair an asset with a SKU whose proportions differ
   beyond tolerance (`validate_assignments.py`). With aspect-match enforced, the
   runtime stretch is near-uniform → imperceptible → round legs stay round AND
   true-to-scale holds.

Absolute source scale is irrelevant (the app re-scales); the pipeline
uniform-normalizes the longest edge to 1 m only as file hygiene.

## Prerequisites

- **Blender 5.x** (`brew install --cask blender`) — the importer/normalizer.
- **Apple USD tools** at `/usr/bin/usdzip`, `/usr/bin/usdchecker` (ship with macOS)
  — ARKit packaging + compliance. No `usdzconvert` / Reality Converter needed.

## Usage

```sh
cd tools/catalog

# 1. Drop raw meshes into a per-source folder, then:
./build_catalog.sh <raw-dir> <out-dir> <source-key>
#    source-key is a key in sources.json: quaternius | kenney | ithappy | _test

# 2. Validate proportions before assigning models to SKUs:
python3 validate_assignments.py \
    --catalog ../../Snug/Resources/catalog.json \
    --report  <out-dir>/report.json

# 3. Copy the passing .usdz into the app bundle and point catalog.json at them:
cp <out-dir>/*.usdz ../../Snug/Resources/Models/
```

Self-test with no downloads:

```sh
./build_catalog.sh test/raw test/out _test   # converts test/raw/testbox_zup.obj
```

## Files

| File | Role |
|---|---|
| `convert_to_usdz.py` | Blender headless script: import → Y-up → normalize → `.usdc` + report |
| `build_catalog.sh` | Orchestrator: Blender → `usdzip --arkitAsset` → `usdchecker --arkit` |
| `validate_assignments.py` | Aspect-ratio guardrail against `catalog.json` |
| `sources.json` | Per-source import axis + license metadata |
| `test/raw/testbox_zup.obj` | Synthetic 1×2×3 Z-up fixture validating the chain |

## The report / model manifest schema

`build_catalog.sh` writes `<out-dir>/report.json`. One entry per converted model:

```jsonc
{
  "models": [
    {
      "assetName": "quaternius_sofa_01",   // == USDZ basename == catalog modelAssetName
      "source": "quaternius",
      "inputFile": "Sofa.gltf",
      "usdPath": "quaternius_sofa_01.usdc",
      "nativeDimsWDH": [1.0, 0.40, 0.39],  // meters, (width, depth, height), Y-up
      "aspect": {                          // scale-invariant proportion signature
        "width_depth": 2.5, "width_height": 2.56, "depth_height": 1.03
      },
      "normalizeFactorApplied": 0.01,      // uniform scale baked into the .usdc (hygiene)
      "triCount": 3140,
      "license": "CC0",
      "sourceURL": "https://quaternius.com/",
      "tintCompatible": null               // set by the step-4 device tint test (see below)
    }
  ]
}
```

`nativeDimsWDH` ordering matches `catalog.json`'s `dimensions` `(width, depth,
height)` so the guardrail can compare directly. `assetName` is the file basename
**without extension** — set a SKU's `modelAssetName` to it to wire the model in
(per `Snug/Resources/Models/README.md`).

## Still manual (by design)

- **`tintCompatible`** — these sources are stylized CC0 shapes that Snug tints
  per-SKU at runtime (`FurnitureEntityBuilder.applyModelTint`). If a source bakes
  color into a palette-texture atlas, runtime tint can mud the mesh. That is a
  visual judgement on-device (step 4); set `tintCompatible` by hand from that test.
  A `false` model needs a flat-shaded variant or is unusable for tint-per-SKU.
- **Assigning models to SKUs** — `catalog.json`'s `modelAssetName` is edited by a
  human after the guardrail passes. The pipeline never rewrites the catalog.
