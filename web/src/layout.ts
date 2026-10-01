/**
 * The visitor's layout: which room, and what is placed where.
 *
 * Encoded into the URL hash so "Copy link" shares the exact room. Readable on
 * purpose, for example: #room=bedroom&items=amzn-b07dzt2sz3:0.85:-0.45:90
 */
import { type RoomSpec, SAMPLE_ROOMS, customRectangle } from './data/rooms';
import { catalogItem } from './catalog';

export interface PlacedItem {
  /** Unique per placement, so the same product can be placed twice. */
  uid: string;
  itemId: string;
  x: number;
  z: number;
  /** Yaw in degrees. */
  rotation: number;
}

export interface Layout {
  room: RoomSpec;
  items: PlacedItem[];
}

let counter = 0;
export const newUid = () => `p${Date.now().toString(36)}${(counter++).toString(36)}`;

const MIN_SIDE = 1.5;
const MAX_SIDE = 12;
const clampSide = (v: number) => Math.min(MAX_SIDE, Math.max(MIN_SIDE, v));

export function roomFromToken(token: string | null): RoomSpec {
  if (token?.startsWith('custom:')) {
    const [w, d] = token.slice(7).split('x').map(Number);
    if (Number.isFinite(w) && Number.isFinite(d)) return customRectangle(clampSide(w), clampSide(d));
  }
  return SAMPLE_ROOMS.find((r) => r.id === token) ?? SAMPLE_ROOMS[0];
}

export function roomToken(room: RoomSpec): string {
  if (room.id.startsWith('custom-')) {
    const xs = room.corners.map((c) => c.x);
    const zs = room.corners.map((c) => c.y);
    const w = Math.max(...xs) - Math.min(...xs);
    const d = Math.max(...zs) - Math.min(...zs);
    return `custom:${w.toFixed(2)}x${d.toFixed(2)}`;
  }
  return room.id;
}

export function encodeLayout(layout: Layout): string {
  const params = new URLSearchParams();
  params.set('room', roomToken(layout.room));
  if (layout.items.length) {
    params.set(
      'items',
      layout.items.map((p) => `${p.itemId}:${p.x.toFixed(3)}:${p.z.toFixed(3)}:${Math.round(p.rotation)}`).join(','),
    );
  }
  return params.toString();
}

const MAX_ITEMS = 24;

export function decodeLayout(hash: string): Layout {
  const params = new URLSearchParams(hash.replace(/^#/, ''));
  const room = roomFromToken(params.get('room'));
  const items: PlacedItem[] = [];
  for (const entry of (params.get('items') ?? '').split(',').filter(Boolean).slice(0, MAX_ITEMS)) {
    const [itemId, x, z, rotation] = entry.split(':');
    const nums = [x, z, rotation].map(Number);
    if (!catalogItem(itemId) || !nums.every(Number.isFinite)) continue;
    items.push({ uid: newUid(), itemId, x: nums[0], z: nums[1], rotation: nums[2] });
  }
  return { room, items };
}
