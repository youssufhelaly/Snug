/**
 * How an approximate product mesh is fitted into a product's real dimensions.
 * Ported from `CatalogModelLoader.approximateFitTransform` in the iOS app.
 *
 * - The footprint (width × depth) is always exactly the catalog size, because
 *   that is what the fit check promises. Tripo does not keep our width/depth
 *   convention, so we pick whichever of 0° or 90° yaw distorts it least.
 * - Height is exactly the catalog height, unless the mesh is more than 10%
 *   taller in proportion. Then the extra is treated as photo clutter on top
 *   (a lamp on a nightstand) and kept, so the furniture body stays true size.
 *
 * Plain numbers in, plain numbers out, so it is unit-testable without WebGL.
 */

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

/** Product dimensions in the catalog's packing: width, depth, height (meters). */
export interface ProductDimensions {
  width: number;
  depth: number;
  height: number;
}

export interface MeshFit {
  /** Yaw to apply to the mesh, 0 or π/2. */
  yRotation: number;
  /** Local-axis scale to apply before the yaw. */
  scale: Vec3;
  /** Local position that re-centers the mesh on the footprint center. */
  position: Vec3;
}

export const CLUTTER_HEIGHT_TOLERANCE = 1.1;

export function approximateFit(modelExtents: Vec3, modelCenter: Vec3, dims: ProductDimensions): MeshFit {
  const safe = (v: number) => (Math.abs(v) < 1e-5 ? 1 : v);
  const ex = safe(modelExtents.x);
  const ey = safe(modelExtents.y);
  const ez = safe(modelExtents.z);

  // Footprint factors for both ground-plane orientations. At 90° the mesh's
  // local X spans world depth and local Z spans world width.
  const straight = { w: dims.width / ex, d: dims.depth / ez };
  const rotated = { w: dims.width / ez, d: dims.depth / ex };
  const spread = (f: { w: number; d: number }) => Math.max(f.w, f.d) / Math.min(f.w, f.d);
  const useRotation = spread(rotated) < spread(straight);
  const foot = useRotation ? rotated : straight;
  const yRotation = useRotation ? Math.PI / 2 : 0;

  const footUniform = Math.sqrt(foot.w * foot.d);
  const proportionalHeight = ey * footUniform;
  const heightScale = proportionalHeight <= dims.height * CLUTTER_HEIGHT_TOLERANCE ? dims.height / ey : footUniform;

  const scale: Vec3 = useRotation
    ? { x: foot.d, y: heightScale, z: foot.w }
    : { x: foot.w, y: heightScale, z: foot.d };

  // Cancel the mesh's bounds offset in scaled-then-rotated space. A yaw about
  // +Y maps (x, z) to (x cos θ + z sin θ, -x sin θ + z cos θ).
  const sx = modelCenter.x * scale.x;
  const sy = modelCenter.y * scale.y;
  const sz = modelCenter.z * scale.z;
  const c = Math.cos(yRotation);
  const s = Math.sin(yRotation);
  const position: Vec3 = {
    x: -(sx * c + sz * s),
    y: -sy,
    z: -(-sx * s + sz * c),
  };
  // A clutter-tall mesh would sink half its overflow below the floor if it
  // were simply centered, so lift it to keep its bottom on the floor.
  position.y += Math.max(0, (ey * heightScale - dims.height) / 2);
  return { yRotation, scale, position };
}
