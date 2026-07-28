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
import bmesh
import sys
import os
import json
import glob
from collections import deque
import numpy as np
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
    """Combined world-space AABB of all mesh objects, in Blender (Z-up) coords.

    Measured from actual vertices, NOT obj.bound_box: Blender does not refresh
    the cached bound_box after a bmesh vertex delete (remove_side_clutter), so a
    bound_box read post-crop would return the stale pre-crop extent — silently
    feeding the old, inflated footprint into the reported dims and the normalize
    scale. For an unmodified mesh this returns exactly what bound_box would."""
    mins = Vector((float("inf"),) * 3)
    maxs = Vector((float("-inf"),) * 3)
    found = False
    for obj in mesh_objects():
        n = len(obj.data.vertices)
        if n == 0:
            continue
        arr = np.empty(n * 3, dtype=np.float64)
        obj.data.vertices.foreach_get("co", arr)
        local = arr.reshape(-1, 3)
        mw = np.array(obj.matrix_world, dtype=np.float64)
        world = local @ mw[:3, :3].T + mw[:3, 3]
        wmin = world.min(axis=0)
        wmax = world.max(axis=0)
        for k in range(3):
            mins[k] = min(mins[k], wmin[k])
            maxs[k] = max(maxs[k], wmax[k])
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

# --- clutter removal (tripo meshes only) ----------------------------------------

def remove_side_clutter(res=64, dilate=1, footprint_margin=0.08, keep_frac=0.5):
    """
    Delete staged props that Tripo fuses BESIDE a product (e.g. a stool next to a
    dresser, a second unit in frame) while preserving anything sitting ON TOP of
    it (lamps, vases, a mirror standing on the surface).

    Tripo emits the product and each detached prop as separate geometry islands
    with small empty gaps between them. We voxelize (Blender Z-up, so the
    footprint plane is X-Y), find connected components (a light dilation bridges
    the product's own surface fragmentation), and treat the largest component as
    the product body. A separate component is KEPT when most of it lies within
    the body's X-Y footprint (it's on top) and REMOVED when it lies beside the
    body (it would inflate the footprint the fit check depends on). Props resting
    on the surface are welded into the body component and are never touched.

    Runs before world_bbox()/uniform_normalize() so the reported dims and the
    normalization reflect the de-cluttered footprint. Returns verts removed.
    """
    objs = mesh_objects()
    if not objs:
        return 0
    # Collapse to one object so components are found across the whole mesh.
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active

    co = np.array([(obj.matrix_world @ v.co)[:] for v in obj.data.vertices],
                  dtype=np.float64)
    n = len(co)
    if n == 0:
        return 0
    mn = co.min(axis=0)
    ext = np.maximum(co.max(axis=0) - mn, 1e-9)
    idx = np.clip(np.floor((co - mn) / ext * (res - 1e-6)).astype(np.int32), 0, res - 1)

    occ = np.zeros((res, res, res), dtype=bool)
    occ[idx[:, 0], idx[:, 1], idx[:, 2]] = True

    def _dilate(grid):
        g = grid.copy()
        for ax in range(3):
            g |= np.roll(grid, 1, axis=ax) | np.roll(grid, -1, axis=ax)
        return g
    docc = occ.copy()
    for _ in range(dilate):
        docc = _dilate(docc)

    labels = np.zeros((res, res, res), dtype=np.int32)
    neigh = [(dx, dy, dz) for dx in (-1, 0, 1) for dy in (-1, 0, 1)
             for dz in (-1, 0, 1) if (dx, dy, dz) != (0, 0, 0)]
    cur = 0
    for cell in zip(*np.where(docc)):
        if labels[cell]:
            continue
        cur += 1
        q = deque([cell]); labels[cell] = cur
        while q:
            x, y, z = q.popleft()
            for dx, dy, dz in neigh:
                nc = (x + dx, y + dy, z + dz)
                if (0 <= nc[0] < res and 0 <= nc[1] < res and 0 <= nc[2] < res
                        and docc[nc] and not labels[nc]):
                    labels[nc] = cur
                    q.append(nc)

    vert_label = labels[idx[:, 0], idx[:, 1], idx[:, 2]]
    counts = np.bincount(vert_label, minlength=cur + 1)
    counts[0] = 0
    body = int(counts.argmax())
    if cur <= 1:
        return 0

    # Body footprint in the X-Y (horizontal) plane, with a small margin.
    body_xy = co[vert_label == body][:, :2]
    bmin = body_xy.min(axis=0); bmax = body_xy.max(axis=0)
    span = np.maximum(bmax - bmin, 1e-9)
    lo = bmin - span * footprint_margin
    hi = bmax + span * footprint_margin

    del_mask = np.zeros(n, dtype=bool)
    for lab in range(1, cur + 1):
        if lab == body or counts[lab] == 0:
            continue
        m = vert_label == lab
        xy = co[m][:, :2]
        inside = ((xy >= lo) & (xy <= hi)).all(axis=1).mean()
        # Mostly within the footprint => it's on top => keep. Otherwise it sits
        # beside the product => remove.
        if inside < keep_frac:
            del_mask |= m

    removed = int(del_mask.sum())
    if removed:
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        bm.verts.ensure_lookup_table()
        bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.where(del_mask)[0]],
                         context="VERTS")
        bm.to_mesh(obj.data)
        bm.free()
    return removed


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

        # Tripo image-to-3D bakes staged props (a stool beside, a second unit)
        # into the mesh; cut the ones that sit BESIDE the product before we
        # measure the footprint. Top clutter (on-surface props) is preserved.
        # Archetype sources (quaternius/kenney) are clean kits — never touched.
        clutter_removed = 0
        if args["source"] == "tripo":
            clutter_removed = remove_side_clutter()
            if clutter_removed:
                print(f"CLUTTER {asset_name}: removed {clutter_removed} side-clutter verts")

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
            "clutterRemovedVerts": clutter_removed,
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
