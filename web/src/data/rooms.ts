/**
 * Sample rooms for the web demo.
 *
 * These are the same shapes the iOS app's fit tests use (`FitFixtures.swift`).
 * They are NOT real scans, and the UI says so: the iOS app is what measures
 * your actual room.
 */
import { type Vec2, vec2 } from '../fit/geometry';

export type OpeningKind = 'door' | 'window';

export interface RoomOpening {
  kind: OpeningKind;
  start: Vec2;
  end: Vec2;
  /** Height of the opening's bottom edge above the floor, in meters. */
  sill: number;
  /** Height of the opening itself, in meters. */
  height: number;
}

export interface RoomSpec {
  id: string;
  name: string;
  corners: Vec2[];
  ceilingHeight: number;
  openings: RoomOpening[];
}

export const BEDROOM: RoomSpec = {
  id: 'bedroom',
  name: 'Bedroom · 3.6 × 3.0 m',
  corners: [vec2(-1.8, -1.5), vec2(1.8, -1.5), vec2(1.8, 1.5), vec2(-1.8, 1.5)],
  ceilingHeight: 2.5,
  openings: [
    { kind: 'window', start: vec2(-0.6, 1.5), end: vec2(0.6, 1.5), sill: 0.9, height: 1.2 },
    { kind: 'door', start: vec2(-1.8, -1.3), end: vec2(-1.8, -0.45), sill: 0, height: 2.05 },
  ],
};

export const L_STUDIO: RoomSpec = {
  id: 'studio',
  name: 'L-shaped studio · 4 × 4 m',
  corners: [vec2(-2, -2), vec2(2, -2), vec2(2, 0), vec2(0, 0), vec2(0, 2), vec2(-2, 2)],
  ceilingHeight: 2.4,
  openings: [
    { kind: 'window', start: vec2(-1.6, -2), end: vec2(-0.4, -2), sill: 0.9, height: 1.2 },
    { kind: 'window', start: vec2(0.6, -2), end: vec2(1.6, -2), sill: 0.9, height: 1.2 },
    { kind: 'door', start: vec2(-2, 0.9), end: vec2(-2, 1.75), sill: 0, height: 2.05 },
  ],
};

export const SAMPLE_ROOMS: RoomSpec[] = [BEDROOM, L_STUDIO];

/** A plain rectangular room of the visitor's own dimensions, centered at the origin. */
export function customRectangle(width: number, depth: number): RoomSpec {
  const hx = width / 2;
  const hz = depth / 2;
  return {
    id: `custom-${width}x${depth}`,
    name: `Your room · ${width.toFixed(2)} × ${depth.toFixed(2)} m`,
    corners: [vec2(-hx, -hz), vec2(hx, -hz), vec2(hx, hz), vec2(-hx, hz)],
    ceilingHeight: 2.5,
    openings: [],
  };
}
