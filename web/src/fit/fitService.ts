/**
 * The trust layer, ported from `Snug/Core/Services/FitService.swift`.
 *
 * Computes how a candidate piece of furniture fits against the room outline
 * and every other placed piece, and reports one of four uncertainty-honest
 * states. Pure and deterministic: no three.js, no DOM.
 */
import {
  type OrientedFootprint,
  type RoomFootprint,
  footprintClearance,
  footprintCorners,
  distanceToSegment,
  isConvexFootprintInsidePolygon,
  roomEdges,
} from './geometry';

/** The app's global error margin in meters (`FitConfiguration.errorMargin`). */
export const ERROR_MARGIN = 0.05;

export type FitState = 'fitsWithRoom' | 'fits' | 'tooCloseToCall' | 'wontFit';

export type ObstacleConfidence = 'measured' | 'estimated';

export interface FitObstacle {
  id: string;
  footprint: OrientedFootprint;
  confidence: ObstacleConfidence;
}

export interface FitGeometry {
  room: RoomFootprint;
  obstacles: FitObstacle[];
}

export type FitLimit =
  | { kind: 'wall'; index: number }
  | { kind: 'obstacle'; id: string }
  | { kind: 'none' };

export interface FitResult {
  state: FitState;
  /** Signed clearance in meters of the binding constraint. */
  clearance: number;
  /** Smallest signed clearance to any wall. */
  wallClearance: number;
  /** Smallest signed clearance to any obstacle, or null if there are none. */
  obstacleClearance: number | null;
  /** The wall or obstacle that produced `clearance`. */
  limit: FitLimit;
}

const marginMultiplier = (c: ObstacleConfidence): number => (c === 'estimated' ? 1.5 : 1);

/**
 * The single place the four-state boundary lives. Conservative on every
 * boundary: exactly `errorMargin` of clearance is still "too close to call".
 */
export function classify(rawClearance: number, errorMargin: number = ERROR_MARGIN): FitState {
  // JS math is 64-bit, so 1.8 - 1.75 comes out as 0.05000000000000004 and
  // would read as "fits" when it is exactly the margin. Snapping to the
  // micrometer removes that noise before the boundary comparison.
  const clearance = Math.round(rawClearance * 1e6) / 1e6;
  if (clearance > errorMargin * 2) return 'fitsWithRoom';
  if (clearance > errorMargin) return 'fits';
  if (clearance >= -errorMargin) return 'tooCloseToCall';
  return 'wontFit';
}

/**
 * Signed clearance from the item to the room walls, measured to wall
 * SEGMENTS so non-convex rooms work. Positive when fully inside.
 */
function roomClearance(item: OrientedFootprint, room: RoomFootprint): { clearance: number; wallIndex: number } {
  const box = footprintCorners(item);
  const poly = room.corners;
  if (poly.length < 3) return { clearance: -Infinity, wallIndex: 0 };

  const inside = isConvexFootprintInsidePolygon(box, poly);
  let minDistance = Infinity;
  let wallIndex = 0;

  roomEdges(room).forEach((edge, index) => {
    for (const corner of box) {
      const d = distanceToSegment(corner, edge.start, edge.end);
      if (d < minDistance) {
        minDistance = d;
        wallIndex = index;
      }
    }
  });
  for (let j = 0; j < poly.length; j++) {
    for (let k = 0; k < box.length; k++) {
      const d = distanceToSegment(poly[j], box[k], box[(k + 1) % box.length]);
      if (d < minDistance) {
        minDistance = d;
        wallIndex = j;
      }
    }
  }
  return { clearance: inside ? minDistance : -minDistance, wallIndex };
}

/** Evaluate a candidate item against the room and its obstacles. */
export function evaluateFit(
  item: OrientedFootprint,
  geometry: FitGeometry,
  errorMargin: number = ERROR_MARGIN,
): FitResult {
  if (geometry.room.corners.length < 3) {
    return { state: 'wontFit', clearance: -Infinity, wallClearance: -Infinity, obstacleClearance: null, limit: { kind: 'none' } };
  }

  const wall = roomClearance(item, geometry.room);
  let obstacleClearance: number | null = null;
  let bindingNormalized = wall.clearance;
  let clearance = wall.clearance;
  let limit: FitLimit = { kind: 'wall', index: wall.wallIndex };

  for (const obstacle of geometry.obstacles) {
    const raw = footprintClearance(item, obstacle.footprint);
    if (obstacleClearance === null || raw < obstacleClearance) obstacleClearance = raw;
    // Normalizing by the multiplier is exactly equivalent to widening that
    // obstacle's band, because every threshold scales linearly with the margin.
    const normalized = raw / marginMultiplier(obstacle.confidence);
    if (normalized < bindingNormalized) {
      bindingNormalized = normalized;
      clearance = raw;
      limit = { kind: 'obstacle', id: obstacle.id };
    }
  }

  return {
    state: classify(bindingNormalized, errorMargin),
    clearance,
    wallClearance: wall.clearance,
    obstacleClearance,
    limit,
  };
}

/** User-facing copy and color per state, mirroring `FitBadge.swift`. */
export const FIT_COPY: Record<FitState, { headline: string; detail: string; color: string }> = {
  fitsWithRoom: { headline: 'Fits with room to spare', detail: '', color: '#7FA886' },
  fits: { headline: 'Fits', detail: '', color: '#7FA886' },
  tooCloseToCall: { headline: 'Too close to call', detail: 'Grab a tape measure for this wall', color: '#BA7517' },
  wontFit: { headline: "Won't fit", detail: 'Too big for the space here', color: '#B85450' },
};
