"""
Blender-headless mesh -> USD converter for the Snug catalog asset pipeline.

Run via:
    blender --background --factory-startup --python convert_to_usdz.py -- \
        --in <raw-dir> --out <usd-dir> --source <key> \
        --sources <sources.json> --report <report.json>

What it does, per mesh file in <raw-dir> (.gltf/.glb/.fbx/.obj):
  1. Import with the source's axis convention (glTF is Y-up by spec, so it needs
     no override; obj/fbx read their axis from sources.json).
  2. Uniform-normalize the longest edge to 1.0 m (HYGIENE ONLY: preserves
     proportions, keeps files at a sane scale / float precision. The app's
     CatalogModelLoader.fitTransform re-scales to real catalog dims regardless,
     so this never affects final size — it just keeps the source files clean).
  3. Export USD (.usdc) converted to RealityKit's Y-up / -Z-forward convention.
  4. Record the asset's native (pre-normalization) Y-up bbox and ASPECT RATIOS
     into the report. Aspect ratio is the input to the assignment guardrail
     (validate_assignments.py) that refuses to pair a square chair asset with a
     long-sofa SKU — the one thing that turns fitTransform's per-axis fit into
     visible distortion.

This script does NOT package usdz or run ARKit compliance — build_catalog.sh
does that with `usdzip --arkitAsset` + `usdchecker --arkit`.
"""

import bpy
import sys
import os
import json
import glob
from mathutils import Matrix, Vector

# --- arg parsing (everything after the literal "--") ---------------------------

def parse_args():
    argv = sys.argv
    if "--" not in argv:
        raise SystemExit("error: pass script args after `--`")
    argv = argv[argv.index("--") + 1:]
    out = {}
    i = 0
    while i < len(argv):
        key = argv[i].lstrip("-")
        out[key] = argv[i + 1]
        i += 2
    for required in ("in", "out", "source", "sources", "report"):
        if required not in out:
            raise SystemExit(f"error: missing --{required}")
    return out

# --- axis token translation ----------------------------------------------------
# sources.json uses the canonical "Y" / "-Z" style. The two importers disagree on
# the negative-axis token: obj_import wants NEGATIVE_Z, fbx wants -Z.

def axis_for_obj(tok):
    return {"X": "X", "Y": "Y", "Z": "Z",
            "-X": "NEGATIVE_X", "-Y": "NEGATIVE_Y", "-Z": "NEGATIVE_Z"}[tok]

def axis_for_fbx(tok):
    return tok  # fbx already uses X/Y/Z/-X/-Y/-Z

# --- scene helpers --------------------------------------------------------------

def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def mesh_objects():
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]

def world_bbox():
    """Combined world-space AABB of all mesh objects, in Blender (Z-up) coords."""
    mins = Vector((float("inf"),) * 3)
    maxs = Vector((float("-inf"),) * 3)
    found = False
    for obj in mesh_objects():
        for corner in obj.bound_box:                       # 8 local-space corners
            wc = obj.matrix_world @ Vector(corner)
            for k in range(3):
                mins[k] = min(mins[k], wc[k])
                maxs[k] = max(maxs[k], wc[k])
            found = True
    if not found:
        return None, None
    return mins, maxs

def uniform_normalize(longest_target=1.0):
    """Scale the whole assembly about the world origin so its longest edge ==
    longest_target. Uniform => proportions preserved. Returns the factor used."""
    mins, maxs = world_bbox()
    if mins is None:
        return 1.0
    ext = maxs - mins
    longest = max(ext.x, ext.y, ext.z)
    if longest < 1e-6:
        return 1.0
    s = longest_target / longest
    S = Matrix.Scale(s, 4)
    for obj in mesh_objects():
        obj.matrix_world = S @ obj.matrix_world
    return s

# --- import ---------------------------------------------------------------------

def do_import(path, ext, src_cfg):
    if ext in (".gltf", ".glb"):
        # glTF is Y-up by spec; Blender's importer auto-orients to its Z-up world.
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        ax = src_cfg.get("axis", {}).get("obj", {"up": "Y", "forward": "-Z"})
        bpy.ops.wm.obj_import(
            filepath=path,
            up_axis=axis_for_obj(ax["up"]),
            forward_axis=axis_for_obj(ax["forward"]),
        )
    elif ext == ".fbx":
        ax = src_cfg.get("axis", {}).get("fbx")
        if ax:
            bpy.ops.import_scene.fbx(
                filepath=path,
                use_manual_orientation=True,
                axis_up=axis_for_fbx(ax["up"]),
                axis_forward=axis_for_fbx(ax["forward"]),
            )
        else:
            # No override: trust the FBX file's own embedded axis metadata.
            bpy.ops.import_scene.fbx(filepath=path)
    else:
        raise ValueError(f"unsupported extension {ext}")

# --- export ---------------------------------------------------------------------

def do_export(out_path):
    # Blender is Z-up internally; convert to RealityKit Y-up / -Z forward.
    bpy.ops.wm.usd_export(
        filepath=out_path,
        selected_objects_only=False,
        export_materials=True,
        generate_preview_surface=True,      # UsdPreviewSurface -> RealityKit reads it
        export_textures_mode="NEW",         # copy textures next to the usd for usdzip
        export_normals=True,
        export_uvmaps=True,
        triangulate_meshes=True,            # RealityKit prefers triangles
        convert_orientation=True,
        export_global_up_selection="Y",
        export_global_forward_selection="NEGATIVE_Z",
        convert_scene_units="METERS",
        root_prim_path="/root",
        xform_op_mode="TRS",
    )

def tri_count():
    n = 0
    for obj in mesh_objects():
        me = obj.data
        n += sum(len(p.vertices) - 2 for p in me.polygons)  # fan-triangulation count
    return n

# --- main -----------------------------------------------------------------------

def main():
    args = parse_args()
    with open(args["sources"]) as f:
        sources = json.load(f)["sources"]
    src_cfg = sources.get(args["source"], {})

    os.makedirs(args["out"], exist_ok=True)
    patterns = ("*.gltf", "*.glb", "*.fbx", "*.obj")
    files = sorted(p for pat in patterns for p in glob.glob(os.path.join(args["in"], pat)))
    if not files:
        raise SystemExit(f"error: no mesh files in {args['in']}")

    report = []
    for path in files:
        base = os.path.splitext(os.path.basename(path))[0]
        ext = os.path.splitext(path)[1].lower()
        asset_name = f"{args['source']}_{base}" if args["source"] != "_test" else base

        reset_scene()
        do_import(path, ext, src_cfg)
        if not mesh_objects():
            print(f"SKIP {path}: imported no mesh")
            continue

        # Native (pre-normalization) bbox in Blender Z-up coords...
        mins, maxs = world_bbox()
        ext_b = maxs - mins
        # ...mapped to the exported Y-up convention and packed as catalog.json does:
        #   (x: width, y: depth, z: height)  [the footprint dimension order]
        width  = round(ext_b.x, 4)            # Blender X stays width
        height = round(ext_b.z, 4)            # Blender Z (up) -> height
        depth  = round(ext_b.y, 4)            # Blender Y (forward) -> depth
        dims_wdh = [width, depth, height]

        def ratio(a, b):
            return round(a / b, 4) if b > 1e-6 else None

        norm_factor = uniform_normalize(1.0)
        out_path = os.path.join(args["out"], f"{asset_name}.usdc")
        do_export(out_path)

        report.append({
            "assetName": asset_name,
            "source": args["source"],
            "inputFile": os.path.basename(path),
            "usdPath": os.path.basename(out_path),
            "nativeDimsWDH": dims_wdh,         # meters, (width, depth, height)
            "aspect": {                        # scale-invariant proportion signature
                "width_depth":  ratio(width, depth),
                "width_height": ratio(width, height),
                "depth_height": ratio(depth, height),
            },
            "normalizeFactorApplied": round(norm_factor, 6),
            "triCount": tri_count(),
            "license": src_cfg.get("license"),
            "sourceURL": src_cfg.get("url"),
            # filled by the step-4 device tint test; null = untested
            "tintCompatible": None,
        })
        print(f"OK  {asset_name}  dims(w,d,h)={dims_wdh}  tris={report[-1]['triCount']}")

    with open(args["report"], "w") as f:
        json.dump({"models": report}, f, indent=2)
    print(f"\nWROTE report: {args['report']}  ({len(report)} models)")

if __name__ == "__main__":
    main()
