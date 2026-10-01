/**
 * Snug web demo: wires the room scene, the fit service, and the catalog UI.
 *
 * Every placement is re-checked against the room walls and every other placed
 * piece after each move, using the same four-state fit logic as the iOS app.
 */
import './styles.css';
import { CATALOG, CATEGORY_LABELS, type CatalogItem, catalogItem, categories, outboundURL, thumbURL } from './catalog';
import { AMAZON_TAG, GITHUB_URL, TESTFLIGHT_URL } from './config';
import { type RoomSpec, SAMPLE_ROOMS, customRectangle } from './data/rooms';
import { ERROR_MARGIN, FIT_COPY, type FitObstacle, type FitResult, type FitState, evaluateFit } from './fit/fitService';
import { type OrientedFootprint, isPointInsidePolygon, vec2 } from './fit/geometry';
import { type Layout, type PlacedItem, decodeLayout, encodeLayout, newUid } from './layout';
import { RoomScene } from './scene/roomScene';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

// MARK: State

const STARTER_LAYOUT =
  'room=bedroom&items=amzn-b07dzt2sz3:0.700:0.200:90,amzn-b0cjmbz6gj:1.530:1.250:270,amzn-b0gmw7fq83:-0.150:-1.220:0,amzn-b0gtz6jfq9:-1.150:0.850:110';

let layout: Layout = decodeLayout(location.hash || STARTER_LAYOUT);
let selected: string | null = null;
let fits = new Map<string, FitResult>();
let category = 'all';
let query = '';

// MARK: Fit

const toRadians = (deg: number) => (deg * Math.PI) / 180;

function footprintOf(p: Pick<PlacedItem, 'itemId' | 'x' | 'z' | 'rotation'>): OrientedFootprint {
  const item = catalogItem(p.itemId)!;
  return { center: vec2(p.x, p.z), size: vec2(item.width, item.depth), rotation: toRadians(p.rotation) };
}

/** Every OTHER placed piece is an obstacle. Real product specs, so `measured`. */
function obstaclesExcept(uid: string | null): FitObstacle[] {
  return layout.items
    .filter((p) => p.uid !== uid)
    .map((p) => ({ id: p.uid, footprint: footprintOf(p), confidence: 'measured' as const }));
}

function recomputeFits(): void {
  const room = { corners: layout.room.corners };
  fits = new Map(layout.items.map((p) => [p.uid, evaluateFit(footprintOf(p), { room, obstacles: obstaclesExcept(p.uid) })]));
}

/**
 * The floor in front of each door, as a square as deep as the door is wide.
 * Only auto-placement avoids these, so new pieces never land in a doorway.
 * Fit verdicts ignore them, matching the iOS app, which has no door zones yet.
 */
function doorZones(): FitObstacle[] {
  return layout.room.openings
    .filter((o) => o.kind === 'door')
    .map((o, i) => {
      const dx = o.end.x - o.start.x;
      const dz = o.end.y - o.start.y;
      const width = Math.hypot(dx, dz);
      const mid = vec2((o.start.x + o.end.x) / 2, (o.start.y + o.end.y) / 2);
      let inward = vec2(-dz / width, dx / width);
      if (!isPointInsidePolygon(vec2(mid.x + inward.x * 0.05, mid.y + inward.y * 0.05), layout.room.corners)) {
        inward = vec2(-inward.x, -inward.y);
      }
      return {
        id: `door-${i}`,
        footprint: { center: vec2(mid.x + (inward.x * width) / 2, mid.y + (inward.y * width) / 2), size: vec2(width, width), rotation: Math.atan2(-dz, dx) },
        confidence: 'measured' as const,
      };
    });
}

/** Finds the spot with the most clearance for a new piece, keeping doorways clear. */
function bestSpot(item: CatalogItem): { x: number; z: number; rotation: number } {
  const xs = layout.room.corners.map((c) => c.x);
  const zs = layout.room.corners.map((c) => c.y);
  const room = { corners: layout.room.corners };
  const obstacles = [...obstaclesExcept(null), ...doorZones()];
  let best = { x: (Math.min(...xs) + Math.max(...xs)) / 2, z: (Math.min(...zs) + Math.max(...zs)) / 2, rotation: 0, clearance: -Infinity };
  const step = 0.1;
  for (const rotation of [0, 90]) {
    for (let x = Math.min(...xs); x <= Math.max(...xs); x += step) {
      for (let z = Math.min(...zs); z <= Math.max(...zs); z += step) {
        const fp: OrientedFootprint = { center: vec2(x, z), size: vec2(item.width, item.depth), rotation: toRadians(rotation) };
        const { clearance } = evaluateFit(fp, { room, obstacles });
        if (clearance > best.clearance + 1e-6) best = { x, z, rotation, clearance };
      }
    }
  }
  return { x: Math.round(best.x * 100) / 100, z: Math.round(best.z * 100) / 100, rotation: best.rotation };
}

// MARK: Copy helpers

const cm = (meters: number) => Math.round(Math.abs(meters) * 100);
const dimsLabel = (i: CatalogItem) => `W ${cm(i.width)} × D ${cm(i.depth)} × H ${cm(i.height)} cm`;
const singular = (cat: string) => (CATEGORY_LABELS[cat] ?? cat).replace(/ves$/, 'f').replace(/s$/, '').toLowerCase();

function limitDescription(result: FitResult): string {
  if (result.limit.kind === 'obstacle') {
    const { id } = result.limit;
    const other = layout.items.find((p) => p.uid === id);
    const name = other ? `the ${singular(catalogItem(other.itemId)!.category)}` : 'another piece';
    return result.clearance >= 0 ? `${cm(result.clearance)} cm from ${name}` : `Overlaps ${name} by ${cm(result.clearance)} cm`;
  }
  if (result.limit.kind === 'wall') {
    return result.clearance >= 0 ? `${cm(result.clearance)} cm to the nearest wall` : `Sticks ${cm(result.clearance)} cm past a wall`;
  }
  return '';
}

const ICONS: Record<FitState, string> = {
  fitsWithRoom: '<svg class="icon" width="18" height="18" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="currentColor"/><path d="M6 10.5l2.6 2.6L14 7.6" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  fits: '<svg class="icon" width="18" height="18" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8.2" stroke="currentColor" stroke-width="1.8" fill="none"/><path d="M6 10.5l2.6 2.6L14 7.6" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  tooCloseToCall: '<svg class="icon" width="18" height="18" viewBox="0 0 20 20" aria-hidden="true"><rect x="1.5" y="6" width="17" height="8" rx="1.5" fill="currentColor"/><path d="M5 6v3M8 6v4M11 6v3M14 6v4" stroke="#fff" stroke-width="1.4"/></svg>',
  wontFit: '<svg class="icon" width="18" height="18" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="currentColor"/><path d="M7 7l6 6M13 7l-6 6" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>',
};

const escapeHTML = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

// MARK: Scene

const scene = new RoomScene($('viewport'), {
  onSelect(uid) {
    selected = uid;
    render();
  },
  onDrag(uid, x, z) {
    const p = layout.items.find((i) => i.uid === uid);
    if (!p) return;
    p.x = x;
    p.z = z;
    render({ persist: false });
  },
  onDragEnd() {
    render();
  },
});

// MARK: Rendering

function render({ persist = true }: { persist?: boolean } = {}): void {
  recomputeFits();
  scene.setSelected(selected);
  scene.setItems(
    layout.items.map((p) => ({ uid: p.uid, item: catalogItem(p.itemId)!, x: p.x, z: p.z, rotation: p.rotation, state: fits.get(p.uid)!.state })),
  );
  renderSummary();
  renderInspector();
  if (persist) history.replaceState(null, '', `#${encodeLayout(layout)}`);
}

function renderSummary(): void {
  const el = $('summary');
  if (!layout.items.length) {
    el.innerHTML = 'Add a piece to check the fit';
    return;
  }
  const counts = new Map<FitState, number>();
  for (const r of fits.values()) counts.set(r.state, (counts.get(r.state) ?? 0) + 1);
  const order: FitState[] = ['fitsWithRoom', 'fits', 'tooCloseToCall', 'wontFit'];
  const fitCount = (counts.get('fitsWithRoom') ?? 0) + (counts.get('fits') ?? 0);
  const parts = [`${layout.items.length} piece${layout.items.length === 1 ? '' : 's'}`];
  if (fitCount) parts.push(`<span class="dot" style="background:${FIT_COPY.fits.color}"></span>${fitCount} fit`);
  for (const state of order.slice(2)) {
    const n = counts.get(state);
    if (n) parts.push(`<span class="dot" style="background:${FIT_COPY[state].color}"></span>${n} ${FIT_COPY[state].headline.toLowerCase()}`);
  }
  el.innerHTML = parts.join(' · ');
}

function renderInspector(): void {
  const el = $('inspector');
  const placed = layout.items.find((p) => p.uid === selected);
  if (!placed) {
    el.hidden = true;
    return;
  }
  const item = catalogItem(placed.itemId)!;
  const result = fits.get(placed.uid)!;
  const copy = FIT_COPY[result.state];
  const detail = [copy.detail, limitDescription(result)].filter(Boolean).join(' · ');
  el.hidden = false;
  el.innerHTML = `
    <img src="${thumbURL(item)}" alt="" onerror="this.style.visibility='hidden'" />
    <h3>${escapeHTML(item.name)}</h3>
    <p class="meta">${escapeHTML(item.brand)} · ${dimsLabel(item)}</p>
    <div class="fit-badge" style="color:${copy.color}">
      ${ICONS[result.state]}
      <div><strong>${copy.headline}</strong><br /><span>${escapeHTML(detail)}</span></div>
    </div>
    <div class="row">
      <button class="btn ghost small" data-action="rotate" data-deg="-15" aria-label="Rotate left 15 degrees">↺ 15°</button>
      <button class="btn ghost small" data-action="rotate" data-deg="15" aria-label="Rotate right 15 degrees">↻ 15°</button>
      <button class="btn ghost small" data-action="rotate" data-deg="90">Turn 90°</button>
      <button class="btn ghost small" data-action="remove">Remove</button>
      <span class="spacer"></span>
      <a class="btn small" href="${outboundURL(item)}" target="_blank" rel="noopener sponsored">View on Amazon ↗</a>
    </div>`;
}

$('inspector').addEventListener('click', (event) => {
  const button = (event.target as HTMLElement).closest('button');
  const placed = layout.items.find((p) => p.uid === selected);
  if (!button || !placed) return;
  if (button.dataset.action === 'rotate') rotateSelected(Number(button.dataset.deg));
  if (button.dataset.action === 'remove') removeSelected();
});

function rotateSelected(deg: number): void {
  const placed = layout.items.find((p) => p.uid === selected);
  if (!placed) return;
  placed.rotation = (((placed.rotation + deg) % 360) + 360) % 360;
  render();
}

function removeSelected(): void {
  layout.items = layout.items.filter((p) => p.uid !== selected);
  selected = null;
  render();
}

function addItem(item: CatalogItem): void {
  const spot = bestSpot(item);
  const placed: PlacedItem = { uid: newUid(), itemId: item.id, ...spot };
  layout.items.push(placed);
  selected = placed.uid;
  render();
}

// MARK: Catalog panel

function renderCategories(): void {
  const el = $('categories');
  const tabs = [['all', 'All'], ...categories().map((c) => [c, CATEGORY_LABELS[c] ?? c])];
  el.innerHTML = tabs
    .map(([key, label]) => `<button type="button" role="tab" data-category="${key}" aria-selected="${key === category}">${label}</button>`)
    .join('');
}

$('categories').addEventListener('click', (event) => {
  const button = (event.target as HTMLElement).closest('button');
  if (!button) return;
  category = button.dataset.category!;
  renderCategories();
  renderCatalog();
});

$<HTMLInputElement>('search').addEventListener('input', (event) => {
  query = (event.target as HTMLInputElement).value.trim().toLowerCase();
  renderCatalog();
});

function renderCatalog(): void {
  const terms = query.split(/\s+/).filter(Boolean);
  const items = CATALOG.filter((i) => category === 'all' || i.category === category).filter((i) => {
    const haystack = `${i.name} ${i.brand} ${i.category} ${CATEGORY_LABELS[i.category] ?? ''} ${i.material}`.toLowerCase();
    return terms.every((t) => haystack.includes(t));
  });
  const el = $('catalog');
  if (!items.length) {
    el.innerHTML = `<li class="empty">No products match “${escapeHTML(query)}”.</li>`;
    return;
  }
  el.innerHTML = items
    .map(
      (i) => `
      <li class="card">
        <img src="${thumbURL(i)}" alt="" loading="lazy" onerror="this.style.visibility='hidden'" />
        <div>
          <h3>${escapeHTML(i.name)}</h3>
          <p>${escapeHTML(i.brand)} · ${dimsLabel(i)}</p>
        </div>
        <button class="btn" type="button" data-add="${i.id}" aria-label="Add ${escapeHTML(i.name)} to the room">Add</button>
      </li>`,
    )
    .join('');
}

$('catalog').addEventListener('click', (event) => {
  const button = (event.target as HTMLElement).closest<HTMLButtonElement>('button[data-add]');
  const item = button && catalogItem(button.dataset.add!);
  if (item) addItem(item);
});

// MARK: Room picker

const CUSTOM = 'custom';

function renderRoomPicker(): void {
  const select = $<HTMLSelectElement>('room-select');
  const isCustom = layout.room.id.startsWith('custom-');
  select.innerHTML =
    SAMPLE_ROOMS.map((r) => `<option value="${r.id}" ${r.id === layout.room.id ? 'selected' : ''}>${r.name}</option>`).join('') +
    `<option value="${CUSTOM}" ${isCustom ? 'selected' : ''}>Enter your room size…</option>`;
  $('custom-size').hidden = !isCustom;
  $('room-name').textContent = layout.room.name;
  $('room-note').textContent = isCustom
    ? 'Typed-in size. The iPhone app measures your real room.'
    : 'Sample room. The iPhone app measures your real one.';
  if (isCustom) fillCustomInputs();
}

function setRoom(room: RoomSpec): void {
  layout.room = room;
  // Pieces left floating outside the new floor get moved to the best spot.
  for (const p of layout.items) {
    if (!isPointInsidePolygon(vec2(p.x, p.z), room.corners)) {
      const others = layout.items;
      layout.items = others.filter((o) => o !== p);
      Object.assign(p, bestSpot(catalogItem(p.itemId)!));
      layout.items = others;
    }
  }
  scene.setRoom(room);
  renderRoomPicker();
  render();
}

function fillCustomInputs(): void {
  const xs = layout.room.corners.map((c) => c.x);
  const zs = layout.room.corners.map((c) => c.y);
  $<HTMLInputElement>('custom-w').value = (Math.max(...xs) - Math.min(...xs)).toFixed(2);
  $<HTMLInputElement>('custom-d').value = (Math.max(...zs) - Math.min(...zs)).toFixed(2);
}

$<HTMLSelectElement>('room-select').addEventListener('change', (event) => {
  const value = (event.target as HTMLSelectElement).value;
  if (value === CUSTOM) {
    $('custom-size').hidden = false;
    fillCustomInputs();
    $<HTMLInputElement>('custom-w').focus();
    return;
  }
  setRoom(SAMPLE_ROOMS.find((r) => r.id === value)!);
});

$('custom-size').addEventListener('submit', (event) => {
  event.preventDefault();
  const clamp = (v: number) => Math.min(12, Math.max(1.5, v));
  const w = Number($<HTMLInputElement>('custom-w').value);
  const d = Number($<HTMLInputElement>('custom-d').value);
  if (!Number.isFinite(w) || !Number.isFinite(d)) return;
  setRoom(customRectangle(clamp(w), clamp(d)));
});

// MARK: Sharing

function toast(message: string): void {
  const el = $('toast');
  el.textContent = message;
  el.hidden = false;
  clearTimeout((toast as unknown as { timer?: number }).timer);
  (toast as unknown as { timer?: number }).timer = window.setTimeout(() => (el.hidden = true), 2200);
}

$('share-link').addEventListener('click', async () => {
  history.replaceState(null, '', `#${encodeLayout(layout)}`);
  try {
    await navigator.clipboard.writeText(location.href);
    toast('Link copied. It opens this exact room.');
  } catch {
    prompt('Copy this link:', location.href);
  }
});

$('share-image').addEventListener('click', async () => {
  const button = $<HTMLButtonElement>('share-image');
  button.disabled = true;
  button.textContent = 'Rendering…';
  try {
    const previous = selected;
    selected = null;
    render({ persist: false });
    await scene.whenModelsLoaded();
    const before = scene.snapshot(false);
    const after = scene.snapshot(true);
    selected = previous;
    render({ persist: false });
    const blob = await composeBeforeAfter(before, after);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'snug-before-after.png';
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
    toast('Saved your before / after image.');
  } finally {
    button.disabled = false;
    button.textContent = 'Before / after image';
  }
});

function composeBeforeAfter(before: HTMLCanvasElement, after: HTMLCanvasElement): Promise<Blob> {
  const pad = 56;
  const header = 120;
  const footer = 120;
  const w = before.width;
  const h = before.height;
  const canvas = document.createElement('canvas');
  canvas.width = w * 2 + pad * 3;
  canvas.height = h + header + footer;
  const ctx = canvas.getContext('2d')!;

  const gradient = ctx.createLinearGradient(0, 0, 0, canvas.height);
  gradient.addColorStop(0, '#F3A07F');
  gradient.addColorStop(1, '#D8653B');
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  const font = 'ui-rounded, "SF Pro Rounded", system-ui, sans-serif';
  ctx.fillStyle = '#FFFFFF';
  ctx.font = `700 52px ${font}`;
  ctx.fillText('Before', pad + 4, header - 34);
  ctx.fillText('After', pad * 2 + w + 4, header - 34);
  ctx.drawImage(before, pad, header);
  ctx.drawImage(after, pad * 2 + w, header);

  const fitCount = [...fits.values()].filter((r) => r.state === 'fits' || r.state === 'fitsWithRoom').length;
  ctx.font = `700 44px ${font}`;
  ctx.fillText('Snug', pad + 4, canvas.height - 50);
  ctx.font = `500 30px ${font}`;
  ctx.fillStyle = 'rgba(255,255,255,0.9)';
  ctx.fillText(
    `${layout.room.name} · ${layout.items.length} real products · ${fitCount} of ${layout.items.length} fit (±${ERROR_MARGIN * 100} cm)`,
    pad + 140,
    canvas.height - 52,
  );
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b!), 'image/png'));
}

// MARK: Keyboard

window.addEventListener('keydown', (event) => {
  if ((event.target as HTMLElement).closest('input, select, textarea')) return;
  const placed = layout.items.find((p) => p.uid === selected);
  if (event.key === 'Escape') {
    selected = null;
    render();
    return;
  }
  if (!placed) return;
  const step = event.shiftKey ? 0.1 : 0.01;
  const moves: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
  if (moves[event.key]) {
    event.preventDefault();
    placed.x += moves[event.key][0];
    placed.z += moves[event.key][1];
    render();
  } else if (event.key === 'r' || event.key === 'R') {
    rotateSelected(event.shiftKey ? -15 : 15);
  } else if (event.key === 'Delete' || event.key === 'Backspace') {
    event.preventDefault();
    removeSelected();
  }
});

// MARK: Boot

$('disclosure').textContent = AMAZON_TAG
  ? 'Links go to Amazon. Snug may earn a commission, at no extra cost to you.'
  : 'Links go to the product on Amazon.';
$<HTMLAnchorElement>('github-link').href = GITHUB_URL;
if (TESTFLIGHT_URL) {
  const link = $<HTMLAnchorElement>('testflight-link');
  link.href = TESTFLIGHT_URL;
  link.hidden = false;
}

scene.setRoom(layout.room);
renderRoomPicker();
renderCategories();
renderCatalog();
render();

// Expose a tiny hook for the thumbnail and screenshot scripts.
(window as unknown as { snug: unknown }).snug = {
  whenModelsLoaded: () => scene.whenModelsLoaded(),
  items: () => layout.items.map((p) => ({ ...p, state: fits.get(p.uid)?.state })),
  screenPosition: (uid: string) => scene.screenPosition(uid),
};
