/**
 * Pure 2D floor-plane geometry for the fit system.
 *
 * A line-for-line TypeScript port of `Snug/Core/Models/FitGeometry.swift`, so
 * the web demo gives the same verdicts as the iOS app. Nothing here knows about
 * three.js or the DOM.
 *
 * Convention (same as the app): every point lives on the floor plane. A
 * `Vec2`'s `x` is world X and its `y` is world **Z**. Units are meters.
 */

export interface Vec2 {
  x: number;
  y: number;
}

export const vec2 = (x: number, y: number): Vec2 => ({ x, y });

const sub = (a: Vec2, b: Vec2): Vec2 => ({ x: a.x - b.x, y: a.y - b.y });
const dot = (a: Vec2, b: Vec2): number => a.x * b.x + a.y * b.y;
const dist = (a: Vec2, b: Vec2): number => Math.hypot(a.x - b.x, a.y - b.y);

/**
 * An axis-aligned-in-local-space rectangle placed and rotated on the floor:
 * the footprint of a furniture item viewed from above.
 */
export interface OrientedFootprint {
  /** Center on the floor plane (x = world X, y = world Z). */
  center: Vec2;
  /** Full local extents: `x` is width, `y` is depth. */
  size: Vec2;
  /** Yaw about +Y in radians, matching the app's RealityKit convention. */
  rotation: number;
}

/**
 * The four world-space corners, from the local (-x, -z) corner. A +Y yaw maps
 * local depth (+Z) to (sin θ, cos θ) and local width (+X) to (cos θ, -sin θ).
 */
export function footprintCorners(f: OrientedFootprint): Vec2[] {
  const hx = f.size.x / 2;
  const hy = f.size.y / 2;
  const c = Math.cos(f.rotation);
  const s = Math.sin(f.rotation);
  const local: Vec2[] = [vec2(-hx, -hy), vec2(hx, -hy), vec2(hx, hy), vec2(-hx, hy)];
  return local.map((p) => vec2(f.center.x + p.x * c + p.y * s, f.center.y - p.x * s + p.y * c));
}

/** The two edge normals of the rectangle (separating-axis candidates). */
export function separatingAxes(f: OrientedFootprint): Vec2[] {
  const c = Math.cos(f.rotation);
  const s = Math.sin(f.rotation);
  return [vec2(c, -s), vec2(s, c)];
}

/** Ordered polygon corners; the last corner connects back to the first. */
export interface RoomFootprint {
  corners: Vec2[];
}

export interface Segment {
  start: Vec2;
  end: Vec2;
}

export function roomEdges(room: RoomFootprint): Segment[] {
  const n = room.corners.length;
  if (n < 2) return [];
  return room.corners.map((start, i) => ({ start, end: room.corners[(i + 1) % n] }));
}

export function rectangleRoom(width: number, depth: number, center: Vec2 = vec2(0, 0)): RoomFootprint {
  const hx = width / 2;
  const hz = depth / 2;
  return {
    corners: [
      vec2(center.x - hx, center.y - hz),
      vec2(center.x + hx, center.y - hz),
      vec2(center.x + hx, center.y + hz),
      vec2(center.x - hx, center.y + hz),
    ],
  };
}

/** Shortest distance from a point to a finite segment. */
export function distanceToSegment(point: Vec2, a: Vec2, b: Vec2): number {
  const ab = sub(b, a);
  const lengthSquared = dot(ab, ab);
  if (lengthSquared <= 0) return dist(point, a);
  const t = Math.max(0, Math.min(1, dot(sub(point, a), ab) / lengthSquared));
  return dist(point, vec2(a.x + t * ab.x, a.y + t * ab.y));
}

/** Signed area sign of triangle (a, b, c): >0 CCW, <0 CW, 0 collinear. */
function orientation(a: Vec2, b: Vec2, c: Vec2): number {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

function onSegment(a: Vec2, b: Vec2, p: Vec2): boolean {
  return (
    Math.min(a.x, b.x) <= p.x && p.x <= Math.max(a.x, b.x) &&
    Math.min(a.y, b.y) <= p.y && p.y <= Math.max(a.y, b.y)
  );
}

function isOnBoundary(point: Vec2, polygon: Vec2[]): boolean {
  for (let i = 0; i < polygon.length; i++) {
    const a = polygon[i];
    const b = polygon[(i + 1) % polygon.length];
    if (orientation(a, b, point) === 0 && onSegment(a, b, point)) return true;
  }
  return false;
}

function rayCastInside(point: Vec2, polygon: Vec2[]): boolean {
  let inside = false;
  let j = polygon.length - 1;
  for (let i = 0; i < polygon.length; i++) {
    const a = polygon[i];
    const b = polygon[j];
    const intersects =
      a.y > point.y !== b.y > point.y &&
      point.x < ((b.x - a.x) * (point.y - a.y)) / (b.y - a.y) + a.x;
    if (intersects) inside = !inside;
    j = i;
  }
  return inside;
}

/** Point-in-polygon where a point exactly on an edge counts as INSIDE. */
export function isPointInsidePolygon(point: Vec2, polygon: Vec2[]): boolean {
  if (polygon.length < 3) return false;
  if (isOnBoundary(point, polygon)) return true;
  return rayCastInside(point, polygon);
}

/** Strict interior test: a point exactly on an edge is NOT inside. */
export function isPointStrictlyInside(point: Vec2, polygon: Vec2[]): boolean {
  if (polygon.length < 3) return false;
  if (isOnBoundary(point, polygon)) return false;
  return rayCastInside(point, polygon);
}

/** Strict crossing: touching at an endpoint or collinear contact does not count. */
function segmentsProperlyCross(p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2): boolean {
  const d1 = orientation(p3, p4, p1);
  const d2 = orientation(p3, p4, p2);
  const d3 = orientation(p1, p2, p3);
  const d4 = orientation(p1, p2, p4);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/**
 * Whether a convex footprint lies entirely inside a simple, possibly
 * non-convex polygon. Checks every box corner inside, no polygon vertex
 * strictly inside the box, and no box edge properly crossing a polygon edge.
 * A piece flush against a wall still reads as inside.
 */
export function isConvexFootprintInsidePolygon(box: Vec2[], polygon: Vec2[]): boolean {
  if (polygon.length < 3 || box.length < 3) return false;
  if (!box.every((p) => isPointInsidePolygon(p, polygon))) return false;
  if (polygon.some((p) => isPointStrictlyInside(p, box))) return false;
  for (let k = 0; k < box.length; k++) {
    const a = box[k];
    const b = box[(k + 1) % box.length];
    for (let j = 0; j < polygon.length; j++) {
      if (segmentsProperlyCross(a, b, polygon[j], polygon[(j + 1) % polygon.length])) return false;
    }
  }
  return true;
}

function projectionInterval(points: Vec2[], axis: Vec2): { min: number; max: number } {
  let lo = Infinity;
  let hi = -Infinity;
  for (const p of points) {
    const d = dot(p, axis);
    lo = Math.min(lo, d);
    hi = Math.max(hi, d);
  }
  return { min: lo, max: hi };
}

/** Minimum distance between two convex polygons known to be disjoint. */
export function minimumDistance(a: Vec2[], b: Vec2[]): number {
  let best = Infinity;
  for (const p of a) {
    for (let i = 0; i < b.length; i++) best = Math.min(best, distanceToSegment(p, b[i], b[(i + 1) % b.length]));
  }
  for (const p of b) {
    for (let i = 0; i < a.length; i++) best = Math.min(best, distanceToSegment(p, a[i], a[(i + 1) % a.length]));
  }
  return best;
}

/**
 * Signed clearance between two oriented rectangles: positive is the true gap,
 * negative is the penetration depth when they overlap (separating axis test).
 */
export function footprintClearance(a: OrientedFootprint, b: OrientedFootprint): number {
  const cornersA = footprintCorners(a);
  const cornersB = footprintCorners(b);
  const axes = [...separatingAxes(a), ...separatingAxes(b)];

  let separated = false;
  let minOverlap = Infinity;
  for (const axis of axes) {
    const pa = projectionInterval(cornersA, axis);
    const pb = projectionInterval(cornersB, axis);
    const gap = Math.max(pa.min - pb.max, pb.min - pa.max);
    if (gap > 0) separated = true;
    minOverlap = Math.min(minOverlap, Math.min(pa.max, pb.max) - Math.max(pa.min, pb.min));
  }
  return separated ? minimumDistance(cornersA, cornersB) : -minOverlap;
}

/** Shoelace area (absolute value) of a floor polygon. */
export function polygonArea(polygon: Vec2[]): number {
  if (polygon.length < 3) return 0;
  let sum = 0;
  for (let i = 0; i < polygon.length; i++) {
    const a = polygon[i];
    const b = polygon[(i + 1) % polygon.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return Math.abs(sum) / 2;
}
