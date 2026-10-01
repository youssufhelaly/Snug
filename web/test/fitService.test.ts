/**
 * Ported from `SnugTests/FitServiceTests.swift`. Same rooms, same boxes, same
 * expected states, so the web port can't drift from the iOS app's verdicts.
 */
import { describe, expect, it } from 'vitest';
import { classify, evaluateFit, type FitGeometry, type FitObstacle } from '../src/fit/fitService';
import { type OrientedFootprint, type RoomFootprint, rectangleRoom, vec2 } from '../src/fit/geometry';

const margin = 0.05;

const box = (x: number, z: number, width: number, depth: number, rotation = 0): OrientedFootprint => ({
  center: vec2(x, z),
  size: vec2(width, depth),
  rotation,
});

const kept = (footprint: OrientedFootprint, confidence: FitObstacle['confidence'] = 'measured'): FitObstacle => ({
  id: Math.random().toString(36).slice(2),
  footprint,
  confidence,
});

const geometry = (room: RoomFootprint, obstacles: FitObstacle[] = []): FitGeometry => ({ room, obstacles });

// FitFixtures.swift
const bedroom = rectangleRoom(3.6, 3.0);
const lShapedStudio: RoomFootprint = {
  corners: [vec2(0, 0), vec2(4, 0), vec2(4, 2), vec2(2, 2), vec2(2, 4), vec2(0, 4)],
};
const uShapedLounge: RoomFootprint = {
  corners: [vec2(0, 0), vec2(6, 0), vec2(6, 4), vec2(4, 4), vec2(4, 2), vec2(2, 2), vec2(2, 4), vec2(0, 4)],
};

describe('four states against a real-shaped room', () => {
  it('obvious fit has room to spare', () => {
    const r = evaluateFit(box(0, 0, 1.0, 0.9), geometry(bedroom), margin);
    expect(r.state).toBe('fitsWithRoom');
    expect(r.clearance).toBeGreaterThan(margin * 2);
  });

  it('obvious no fit', () => {
    const r = evaluateFit(box(0, 0, 4.0, 1.0), geometry(bedroom), margin);
    expect(r.state).toBe('wontFit');
    expect(r.clearance).toBeLessThan(-margin);
  });

  it('clearance exactly at the margin is too close to call', () => {
    expect(evaluateFit(box(0, 0, 3.5, 1.0), geometry(bedroom), margin).state).toBe('tooCloseToCall');
  });

  it('one centimeter inside the margin never shows a green check', () => {
    expect(evaluateFit(box(0, 0, 3.52, 1.0), geometry(bedroom), margin).state).toBe('tooCloseToCall');
  });

  it('just past the margin fits', () => {
    expect(evaluateFit(box(0, 0, 3.48, 1.0), geometry(bedroom), margin).state).toBe('fits');
  });
});

describe('obstacles', () => {
  it('overlapping a kept object will not fit, and names the obstacle', () => {
    const obstacle = kept(box(1.0, 0, 0.8, 0.8));
    const r = evaluateFit(box(1.1, 0, 0.8, 0.8), geometry(bedroom, [obstacle]), margin);
    expect(r.state).toBe('wontFit');
    expect(r.limit).toEqual({ kind: 'obstacle', id: obstacle.id });
  });

  it('clear of a kept object fits', () => {
    const r = evaluateFit(box(-1.0, 0, 0.8, 0.8), geometry(bedroom, [kept(box(1.2, 0, 0.8, 0.8))]), margin);
    expect(r.state).toBe('fitsWithRoom');
  });

  it('an estimated obstacle widens the band 1.5x', () => {
    // A 0.07 m gap "fits" against a measured piece, but an estimated piece
    // normalizes it to 0.07 / 1.5 = 0.047, which is "too close to call".
    const at = (gap: number, c: FitObstacle['confidence']) =>
      evaluateFit(box(-0.4 - gap / 2, 0, 0.8, 0.8), geometry(bedroom, [kept(box(0.4 + gap / 2, 0, 0.8, 0.8), c)]), margin).state;
    expect(at(0.07, 'measured')).toBe('fits');
    expect(at(0.07, 'estimated')).toBe('tooCloseToCall');
  });
});

describe('rotation', () => {
  it('a rotated box fits diagonally', () => {
    expect(evaluateFit(box(0, 0, 1.0, 1.0, Math.PI / 4), geometry(bedroom), margin).state).toBe('fitsWithRoom');
  });

  it('a rotated box that pokes out will not fit', () => {
    expect(evaluateFit(box(0, 0, 3.0, 3.0, Math.PI / 4), geometry(bedroom), margin).state).toBe('wontFit');
  });

  it('a rotated room behaves like its upright twin', () => {
    const a = Math.PI / 6;
    const tilted: RoomFootprint = {
      corners: bedroom.corners.map((p) => vec2(p.x * Math.cos(a) - p.y * Math.sin(a), p.x * Math.sin(a) + p.y * Math.cos(a))),
    };
    expect(evaluateFit(box(0, 0, 1.0, 0.6), geometry(tilted), margin).state).toBe('fitsWithRoom');
  });
});

describe('non-convex rooms', () => {
  it('box in the wide arm of an L-shaped room fits', () => {
    expect(evaluateFit(box(1, 1, 1.2, 1.2), geometry(lShapedStudio), margin).state).toBe('fitsWithRoom');
  });

  it('box in the bitten-out corner of an L-shaped room will not fit', () => {
    expect(evaluateFit(box(3, 3, 1, 1), geometry(lShapedStudio), margin).state).toBe('wontFit');
  });

  it('box spanning the notch of a U-shaped room will not fit', () => {
    const r = evaluateFit(box(3.0, 3.5, 3.0, 0.5), geometry(uShapedLounge), margin);
    expect(r.state).toBe('wontFit');
    expect(r.clearance).toBeLessThan(0);
  });

  it('box inside one arm of a U-shaped room fits', () => {
    expect(evaluateFit(box(1.0, 3.0, 1.2, 1.2), geometry(uShapedLounge), margin).state).toBe('fitsWithRoom');
  });

  it('reports the nearest wall, not a phantom far wall', () => {
    const r = evaluateFit(box(1, 1, 0.6, 0.6), geometry(lShapedStudio), margin);
    expect(r.state).toBe('fitsWithRoom');
    expect(Math.abs(r.clearance - 0.7)).toBeLessThan(0.01);
  });

  it('each arm wall is reachable', () => {
    expect(evaluateFit(box(1.0, 0.31, 0.6, 0.6), geometry(lShapedStudio), margin).state).toBe('tooCloseToCall');
    expect(evaluateFit(box(3.69, 1.0, 0.6, 0.6), geometry(lShapedStudio), margin).state).toBe('tooCloseToCall');
  });
});

describe('true corner-to-corner distance', () => {
  it('diagonal corner gap measures the true distance', () => {
    const g = geometry(rectangleRoom(6, 6), [kept(box(1, 1, 1, 1, Math.PI / 4))]);
    const r = evaluateFit(box(-1, -1, 1, 1, Math.PI / 4), g, margin);
    expect(r.state).toBe('fitsWithRoom');
    expect(r.clearance).toBeGreaterThan(1.0);
  });
});

describe('classifier boundaries', () => {
  it('cuts exactly where the Swift classifier does', () => {
    expect(classify(0.11, margin)).toBe('fitsWithRoom');
    expect(classify(0.1, margin)).toBe('fits');
    expect(classify(0.051, margin)).toBe('fits');
    expect(classify(0.05, margin)).toBe('tooCloseToCall');
    expect(classify(0, margin)).toBe('tooCloseToCall');
    expect(classify(-0.05, margin)).toBe('tooCloseToCall');
    expect(classify(-0.051, margin)).toBe('wontFit');
  });
});
