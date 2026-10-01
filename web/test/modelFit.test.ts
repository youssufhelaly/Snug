/** Ported from the approximate-fit cases in `SnugTests/CatalogModelLoaderTests.swift`. */
import { describe, expect, it } from 'vitest';
import { approximateFit } from '../src/scene/modelFit';

const v = (x: number, y: number, z: number) => ({ x, y, z });
const dims = (width: number, depth: number, height: number) => ({ width, depth, height });

describe('approximateFit', () => {
  it('keeps an already-aligned mesh straight with an exact footprint', () => {
    const fit = approximateFit(v(1.0, 0.4, 0.25), v(0, 0, 0), dims(2.0, 0.5, 0.8));
    expect(fit.yRotation).toBe(0);
    expect(fit.scale.x).toBeCloseTo(2.0, 5);
    expect(fit.scale.z).toBeCloseTo(2.0, 5);
    expect(fit.scale.y).toBeCloseTo(2.0, 5);
  });

  it('detects a rotated mesh and keeps the footprint exact', () => {
    const fit = approximateFit(v(1.0, 0.471, 0.742), v(0, 0, 0), dims(1.52, 2.06, 0.94));
    expect(fit.yRotation).toBe(Math.PI / 2);
    expect(fit.scale.z * 0.742).toBeCloseTo(1.52, 3);
    expect(fit.scale.x * 1.0).toBeCloseTo(2.06, 3);
  });

  it('keeps proportional height for a clutter-tall mesh and never squashes it', () => {
    const extents = v(1.0, 0.6664, 0.4111);
    const fit = approximateFit(extents, v(0, 0, 0), dims(1.37, 0.5, 0.75));
    const rendered = fit.scale.y * extents.y;
    expect(rendered).toBeGreaterThan(0.75);
    expect(rendered).toBeCloseTo(extents.y * Math.sqrt((1.37 / 1.0) * (0.5 / 0.4111)), 4);
    expect(fit.scale.x * extents.x).toBeCloseTo(1.37, 3);
    expect(fit.scale.z * extents.z).toBeCloseTo(0.5, 3);
  });

  it('snaps a slightly tall mesh to the exact catalog height', () => {
    const extents = v(1.0, 0.53, 0.5);
    const fit = approximateFit(extents, v(0, 0, 0), dims(1.0, 0.5, 0.5));
    expect(fit.scale.y * extents.y).toBeCloseTo(0.5, 5);
  });

  it('re-centers an off-origin mesh under the yaw', () => {
    const fit = approximateFit(v(2.0, 1.0, 1.0), v(0.5, 0, 0), dims(1.0, 2.0, 1.0));
    expect(fit.yRotation).toBe(Math.PI / 2);
    expect(Math.abs(fit.position.x)).toBeLessThan(1e-5);
    expect(Math.abs(fit.position.z)).toBeGreaterThan(1e-3);
  });

  it('survives a degenerate axis', () => {
    const fit = approximateFit(v(0, 1, 1), v(0, 0, 0), dims(1, 1, 1));
    expect(Number.isFinite(fit.scale.x) && Number.isFinite(fit.scale.y) && Number.isFinite(fit.scale.z)).toBe(true);
  });
});
