/**
 * The 3D room view: a dollhouse-style diorama of the room with true-to-scale
 * furniture you can drag around.
 *
 * Mirrors the iOS app's rules:
 * - The box is the source of truth. Each piece has an invisible hit box at the
 *   product's real dimensions; the textured mesh is visual only.
 * - Until a mesh loads (or if it fails), an honest true-scale box in the
 *   product's color stands in. We never show a warped fake.
 * - The footprint outline is tinted by the piece's fit state.
 */
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/examples/jsm/libs/meshopt_decoder.module.js';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
import { RoundedBoxGeometry } from 'three/examples/jsm/geometries/RoundedBoxGeometry.js';
import type { RoomSpec, RoomOpening } from '../data/rooms';
import type { CatalogItem } from '../catalog';
import { modelURL } from '../catalog';
import type { FitState } from '../fit/fitService';
import { FIT_COPY } from '../fit/fitService';
import { isPointInsidePolygon, vec2 } from '../fit/geometry';
import { approximateFit } from './modelFit';

const WALL_THICKNESS = 0.1;
const WALL_STUB_HEIGHT = 0.14;
const PLINTH_DEPTH = 0.14;

const COLORS = {
  floor: 0xc9a876,
  plinth: 0xa97c55,
  wall: 0xede6d9,
  wallCap: 0xfbf6ee,
  glass: 0xe4f0f6,
};

export interface SceneItem {
  uid: string;
  item: CatalogItem;
  x: number;
  z: number;
  /** Yaw in degrees. */
  rotation: number;
  state: FitState;
}

export interface RoomSceneCallbacks {
  onSelect(uid: string | null): void;
  onDrag(uid: string, x: number, z: number): void;
  onDragEnd(uid: string): void;
}

interface WallView {
  full: THREE.Group;
  stub: THREE.Group;
  /** Outward normal on the floor plane. */
  normal: THREE.Vector2;
  mid: THREE.Vector2;
}

interface FurnitureView {
  root: THREE.Group;
  hitBox: THREE.Mesh;
  placeholder: THREE.Mesh;
  outline: THREE.Mesh;
  outlineMaterial: THREE.MeshBasicMaterial;
  fill: THREE.Mesh;
  asin: string;
}

const gltfLoader = new GLTFLoader().setMeshoptDecoder(MeshoptDecoder);
const modelCache = new Map<string, Promise<THREE.Group | null>>();

/** Loads each product mesh once; later placements clone the template. */
function loadModel(item: CatalogItem): Promise<THREE.Group | null> {
  let pending = modelCache.get(item.asin);
  if (!pending) {
    pending = gltfLoader
      .loadAsync(modelURL(item))
      .then((gltf) => {
        gltf.scene.traverse((o) => {
          if ((o as THREE.Mesh).isMesh) {
            o.castShadow = true;
            o.receiveShadow = true;
          }
        });
        return gltf.scene;
      })
      .catch((error) => {
        console.warn(`Model for ${item.asin} failed to load; keeping the true-scale box.`, error);
        return null;
      });
    modelCache.set(item.asin, pending);
  }
  return pending;
}

/** Fits a loaded product mesh into the product's real dimensions. */
function fittedModel(template: THREE.Group, item: CatalogItem): THREE.Group {
  const model = template.clone(true);
  model.updateMatrixWorld(true);
  const bounds = new THREE.Box3().setFromObject(model);
  const size = bounds.getSize(new THREE.Vector3());
  const center = bounds.getCenter(new THREE.Vector3());
  const fit = approximateFit(size, center, { width: item.width, depth: item.depth, height: item.height });

  const wrapper = new THREE.Group();
  wrapper.add(model);
  wrapper.position.set(fit.position.x, fit.position.y + item.height / 2, fit.position.z);
  wrapper.rotation.y = fit.yRotation;
  wrapper.scale.set(fit.scale.x, fit.scale.y, fit.scale.z);
  return wrapper;
}

/** A flat rectangular frame on the floor, used as the footprint outline. */
function footprintFrameGeometry(width: number, depth: number, stroke: number): THREE.ShapeGeometry {
  const hx = width / 2 + stroke;
  const hz = depth / 2 + stroke;
  const shape = new THREE.Shape([
    new THREE.Vector2(-hx, -hz), new THREE.Vector2(hx, -hz), new THREE.Vector2(hx, hz), new THREE.Vector2(-hx, hz),
  ]);
  const ix = width / 2;
  const iz = depth / 2;
  shape.holes.push(new THREE.Path([
    new THREE.Vector2(-ix, -iz), new THREE.Vector2(-ix, iz), new THREE.Vector2(ix, iz), new THREE.Vector2(ix, -iz),
  ]));
  const geometry = new THREE.ShapeGeometry(shape);
  geometry.rotateX(-Math.PI / 2);
  return geometry;
}

export class RoomScene {
  readonly renderer: THREE.WebGLRenderer;
  private readonly scene = new THREE.Scene();
  private readonly camera = new THREE.PerspectiveCamera(32, 1, 0.05, 100);
  private readonly controls: OrbitControls;
  private readonly sun = new THREE.DirectionalLight(0xffffff, 2.2);
  private readonly roomGroup = new THREE.Group();
  private readonly furnitureGroup = new THREE.Group();
  private walls: WallView[] = [];
  private furniture = new Map<string, FurnitureView>();
  private selected: string | null = null;
  private room: RoomSpec | null = null;
  /** Until the visitor moves the camera, keep re-framing the room on resize. */
  private cameraTouched = false;

  private readonly raycaster = new THREE.Raycaster();
  private readonly floorPlane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
  private drag: { uid: string; offset: THREE.Vector3; pointerId: number } | null = null;
  private pointerDownAt: { x: number; y: number } | null = null;

  constructor(private readonly container: HTMLElement, private readonly callbacks: RoomSceneCallbacks) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.renderer.toneMapping = THREE.NeutralToneMapping;
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.setClearColor(0x000000, 0);
    container.appendChild(this.renderer.domElement);

    const pmrem = new THREE.PMREMGenerator(this.renderer);
    this.scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
    this.scene.environmentIntensity = 0.55;

    this.scene.add(new THREE.HemisphereLight(0xfff6ec, 0xc9b8a6, 0.9));
    this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(2048, 2048);
    this.sun.shadow.bias = -0.0004;
    this.sun.shadow.normalBias = 0.02;
    this.sun.shadow.radius = 4;
    this.scene.add(this.sun, this.sun.target);
    this.scene.add(this.roomGroup, this.furnitureGroup);

    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.minPolarAngle = 0.2;
    this.controls.maxPolarAngle = 1.35;
    this.controls.screenSpacePanning = true;
    this.controls.addEventListener('start', () => (this.cameraTouched = true));

    const canvas = this.renderer.domElement;
    canvas.addEventListener('pointerdown', this.onPointerDown);
    canvas.addEventListener('pointermove', this.onPointerMove);
    canvas.addEventListener('pointerup', this.onPointerUp);
    canvas.addEventListener('pointercancel', this.onPointerUp);

    new ResizeObserver(() => this.resize()).observe(container);
    this.resize();
    this.renderer.setAnimationLoop(() => this.tick());
  }

  // MARK: Room

  setRoom(room: RoomSpec): void {
    this.room = room;
    this.cameraTouched = false;
    this.roomGroup.traverse((o) => {
      const mesh = o as THREE.Mesh;
      if (mesh.isMesh) mesh.geometry.dispose();
    });
    this.roomGroup.clear();
    this.walls = [];

    const shape = new THREE.Shape(room.corners.map((c) => new THREE.Vector2(c.x, -c.y)));
    const floorGeometry = new THREE.ShapeGeometry(shape);
    floorGeometry.rotateX(-Math.PI / 2);
    const floor = new THREE.Mesh(floorGeometry, new THREE.MeshStandardMaterial({ color: COLORS.floor, roughness: 0.82 }));
    floor.receiveShadow = true;
    this.roomGroup.add(floor);

    // A plinth under the floor gives the diorama its "model on a table" look.
    const plinthGeometry = new THREE.ExtrudeGeometry(shape, { depth: PLINTH_DEPTH, bevelEnabled: false });
    plinthGeometry.rotateX(-Math.PI / 2);
    plinthGeometry.translate(0, -PLINTH_DEPTH - 0.001, 0);
    this.roomGroup.add(new THREE.Mesh(plinthGeometry, new THREE.MeshStandardMaterial({ color: COLORS.plinth, roughness: 0.9 })));

    const wallMaterial = new THREE.MeshStandardMaterial({ color: COLORS.wall, roughness: 0.95 });
    const capMaterial = new THREE.MeshStandardMaterial({ color: COLORS.wallCap, roughness: 0.9 });
    const glassMaterial = new THREE.MeshPhysicalMaterial({
      color: COLORS.glass, transparent: true, opacity: 0.72, roughness: 0.15, metalness: 0, depthWrite: false,
    });
    const polygon = room.corners;

    polygon.forEach((a, i) => {
      const b = polygon[(i + 1) % polygon.length];
      const along = new THREE.Vector2(b.x - a.x, b.y - a.y);
      const length = along.length();
      if (length < 1e-4) return;
      along.normalize();
      const mid = new THREE.Vector2((a.x + b.x) / 2, (a.y + b.y) / 2);
      // Outward normal: whichever perpendicular points off the floor.
      let normal = new THREE.Vector2(along.y, -along.x);
      if (isPointInsidePolygon(vec2(mid.x + normal.x * 0.01, mid.y + normal.y * 0.01), polygon)) normal = normal.negate();

      const openings = room.openings
        .map((o) => this.openingSpan(o, a, along, normal, length))
        .filter((o): o is { t0: number; t1: number; opening: RoomOpening } => o !== null)
        .sort((p, q) => p.t0 - q.t0);

      // Wall pieces along the wall: full height between openings, and the parts
      // above and below each opening.
      const pieces: { t0: number; t1: number; y0: number; y1: number }[] = [];
      let cursor = -WALL_THICKNESS / 2;
      for (const span of openings) {
        if (span.t0 > cursor) pieces.push({ t0: cursor, t1: span.t0, y0: 0, y1: room.ceilingHeight });
        if (span.opening.sill > 0) pieces.push({ t0: span.t0, t1: span.t1, y0: 0, y1: span.opening.sill });
        const top = span.opening.sill + span.opening.height;
        if (top < room.ceilingHeight) pieces.push({ t0: span.t0, t1: span.t1, y0: top, y1: room.ceilingHeight });
        cursor = Math.max(cursor, span.t1);
      }
      if (cursor < length + WALL_THICKNESS / 2) pieces.push({ t0: cursor, t1: length + WALL_THICKNESS / 2, y0: 0, y1: room.ceilingHeight });

      const yaw = Math.atan2(-along.y, along.x);
      const place = (mesh: THREE.Object3D, t: number, y: number) => {
        mesh.position.set(a.x + along.x * t + normal.x * WALL_THICKNESS / 2, y, a.y + along.y * t + normal.y * WALL_THICKNESS / 2);
        mesh.rotation.y = yaw;
      };

      const full = new THREE.Group();
      for (const p of pieces) {
        const piece = new THREE.Mesh(new THREE.BoxGeometry(p.t1 - p.t0, p.y1 - p.y0, WALL_THICKNESS), wallMaterial);
        place(piece, (p.t0 + p.t1) / 2, (p.y0 + p.y1) / 2);
        piece.receiveShadow = true;
        full.add(piece);
      }
      const cap = new THREE.Mesh(new THREE.BoxGeometry(length + WALL_THICKNESS, 0.02, WALL_THICKNESS + 0.004), capMaterial);
      place(cap, length / 2, room.ceilingHeight + 0.01);
      full.add(cap);
      for (const span of openings) {
        if (span.opening.kind !== 'window') continue;
        const pane = new THREE.Mesh(new THREE.BoxGeometry(span.t1 - span.t0, span.opening.height, 0.01), glassMaterial);
        place(pane, (span.t0 + span.t1) / 2, span.opening.sill + span.opening.height / 2);
        full.add(pane);
      }

      // When a wall faces the camera it drops to a short stub, so you can see in.
      const stub = new THREE.Group();
      const stubPieces = openings.filter((s) => s.opening.kind === 'door');
      let stubCursor = -WALL_THICKNESS / 2;
      const stubSpans: [number, number][] = [];
      for (const s of stubPieces) {
        if (s.t0 > stubCursor) stubSpans.push([stubCursor, s.t0]);
        stubCursor = Math.max(stubCursor, s.t1);
      }
      if (stubCursor < length + WALL_THICKNESS / 2) stubSpans.push([stubCursor, length + WALL_THICKNESS / 2]);
      for (const [t0, t1] of stubSpans) {
        const piece = new THREE.Mesh(new THREE.BoxGeometry(t1 - t0, WALL_STUB_HEIGHT, WALL_THICKNESS), wallMaterial);
        place(piece, (t0 + t1) / 2, WALL_STUB_HEIGHT / 2);
        stub.add(piece);
        const stubCap = new THREE.Mesh(new THREE.BoxGeometry(t1 - t0, 0.012, WALL_THICKNESS + 0.004), capMaterial);
        place(stubCap, (t0 + t1) / 2, WALL_STUB_HEIGHT + 0.006);
        stub.add(stubCap);
      }

      this.roomGroup.add(full, stub);
      this.walls.push({ full, stub, normal, mid });
    });

    this.frameRoom();
  }

  /** Where an opening sits along a wall, or null if it is on a different wall. */
  private openingSpan(o: RoomOpening, a: { x: number; y: number }, along: THREE.Vector2, normal: THREE.Vector2, length: number) {
    const project = (p: { x: number; y: number }) => ({
      t: (p.x - a.x) * along.x + (p.y - a.y) * along.y,
      off: Math.abs((p.x - a.x) * normal.x + (p.y - a.y) * normal.y),
    });
    const s = project(o.start);
    const e = project(o.end);
    if (s.off > 0.03 || e.off > 0.03) return null;
    const t0 = Math.max(0, Math.min(s.t, e.t));
    const t1 = Math.min(length, Math.max(s.t, e.t));
    return t1 - t0 > 0.05 ? { t0, t1, opening: o } : null;
  }

  /** Points the camera at the room from a three-quarter view that fits it on screen. */
  frameRoom(): void {
    if (!this.room) return;
    const xs = this.room.corners.map((c) => c.x);
    const zs = this.room.corners.map((c) => c.y);
    const center = new THREE.Vector3((Math.min(...xs) + Math.max(...xs)) / 2, 0.5, (Math.min(...zs) + Math.max(...zs)) / 2);
    const radius = Math.hypot(Math.max(...xs) - Math.min(...xs), Math.max(...zs) - Math.min(...zs)) / 2 + 0.4;
    // Fit the room's bounding sphere inside both the vertical and the
    // horizontal field of view, so narrow phone screens frame it too.
    const halfV = THREE.MathUtils.degToRad(this.camera.fov) / 2;
    const halfH = Math.atan(Math.tan(halfV) * Math.max(this.camera.aspect, 0.1));
    const distance = (radius / Math.sin(Math.min(halfV, halfH))) * (this.camera.aspect < 1 ? 1 : 0.9);
    const direction = new THREE.Vector3(0.75, 1.05, 1.15).normalize();
    this.camera.position.copy(center).addScaledVector(direction, distance);
    this.controls.target.copy(center);
    this.controls.minDistance = radius * 0.8;
    this.controls.maxDistance = distance * 2.2;
    this.controls.update();

    const shadow = this.sun.shadow.camera;
    const extent = radius + 1;
    shadow.left = -extent;
    shadow.right = extent;
    shadow.top = extent;
    shadow.bottom = -extent;
    shadow.near = 0.5;
    shadow.far = 20;
    shadow.updateProjectionMatrix();
    this.sun.position.set(center.x + 2.5, 7, center.z + 1.5);
    this.sun.target.position.copy(center);
  }

  // MARK: Furniture

  setItems(items: SceneItem[]): void {
    const keep = new Set(items.map((i) => i.uid));
    for (const [uid, view] of this.furniture) {
      if (!keep.has(uid)) {
        this.furnitureGroup.remove(view.root);
        this.furniture.delete(uid);
      }
    }
    for (const entry of items) {
      const view = this.furniture.get(entry.uid) ?? this.createFurniture(entry);
      view.root.position.set(entry.x, 0, entry.z);
      view.root.rotation.y = THREE.MathUtils.degToRad(entry.rotation);
      view.outlineMaterial.color.set(FIT_COPY[entry.state].color);
      const isSelected = entry.uid === this.selected;
      view.outlineMaterial.opacity = isSelected ? 1 : 0.75;
      (view.fill.material as THREE.MeshBasicMaterial).color.set(FIT_COPY[entry.state].color);
      view.fill.visible = isSelected;
    }
  }

  setSelected(uid: string | null): void {
    this.selected = uid;
  }

  private createFurniture(entry: SceneItem): FurnitureView {
    const { item } = entry;
    const root = new THREE.Group();
    root.userData.uid = entry.uid;

    const hitBox = new THREE.Mesh(
      new THREE.BoxGeometry(item.width, item.height, item.depth),
      new THREE.MeshBasicMaterial({ transparent: true, opacity: 0, depthWrite: false, colorWrite: false }),
    );
    hitBox.position.y = item.height / 2;
    hitBox.userData.uid = entry.uid;
    root.add(hitBox);

    const color = new THREE.Color().setRGB(item.color[0], item.color[1], item.color[2], THREE.SRGBColorSpace);
    const placeholder = new THREE.Mesh(
      new RoundedBoxGeometry(item.width, item.height, item.depth, 2, Math.min(0.03, item.height / 4)),
      new THREE.MeshStandardMaterial({ color, roughness: 0.8 }),
    );
    placeholder.position.y = item.height / 2;
    placeholder.castShadow = true;
    root.add(placeholder);

    const outlineMaterial = new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false });
    const outline = new THREE.Mesh(footprintFrameGeometry(item.width, item.depth, 0.025), outlineMaterial);
    outline.position.y = 0.004;
    outline.renderOrder = 2;
    root.add(outline);

    const fillGeometry = new THREE.PlaneGeometry(item.width, item.depth);
    fillGeometry.rotateX(-Math.PI / 2);
    const fill = new THREE.Mesh(fillGeometry, new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.18, depthWrite: false }));
    fill.position.y = 0.003;
    fill.renderOrder = 1;
    root.add(fill);

    const view: FurnitureView = { root, hitBox, placeholder, outline, outlineMaterial, fill, asin: item.asin };
    this.furniture.set(entry.uid, view);
    this.furnitureGroup.add(root);

    loadModel(item).then((template) => {
      if (!template || this.furniture.get(entry.uid) !== view) return;
      root.add(fittedModel(template, item));
      placeholder.visible = false;
    });
    return view;
  }

  // MARK: Pointer interaction

  private pointerToNDC(event: PointerEvent): THREE.Vector2 {
    const rect = this.renderer.domElement.getBoundingClientRect();
    return new THREE.Vector2(((event.clientX - rect.left) / rect.width) * 2 - 1, -((event.clientY - rect.top) / rect.height) * 2 + 1);
  }

  private floorPoint(event: PointerEvent): THREE.Vector3 | null {
    this.raycaster.setFromCamera(this.pointerToNDC(event), this.camera);
    return this.raycaster.ray.intersectPlane(this.floorPlane, new THREE.Vector3());
  }

  private hitTest(event: PointerEvent): string | null {
    this.raycaster.setFromCamera(this.pointerToNDC(event), this.camera);
    const boxes = [...this.furniture.values()].map((v) => v.hitBox);
    const hit = this.raycaster.intersectObjects(boxes, false)[0];
    return hit ? (hit.object.userData.uid as string) : null;
  }

  private onPointerDown = (event: PointerEvent) => {
    this.pointerDownAt = { x: event.clientX, y: event.clientY };
    const uid = this.hitTest(event);
    if (!uid) return;
    const view = this.furniture.get(uid)!;
    const point = this.floorPoint(event);
    if (!point) return;
    this.drag = { uid, offset: view.root.position.clone().sub(point), pointerId: event.pointerId };
    this.controls.enabled = false;
    this.renderer.domElement.setPointerCapture(event.pointerId);
    this.callbacks.onSelect(uid);
  };

  private onPointerMove = (event: PointerEvent) => {
    if (!this.drag) {
      this.renderer.domElement.style.cursor = this.hitTest(event) ? 'grab' : '';
      return;
    }
    if (event.pointerId !== this.drag.pointerId) return;
    const point = this.floorPoint(event);
    if (!point) return;
    const next = point.add(this.drag.offset);
    this.renderer.domElement.style.cursor = 'grabbing';
    this.callbacks.onDrag(this.drag.uid, next.x, next.z);
  };

  private onPointerUp = (event: PointerEvent) => {
    if (this.drag && event.pointerId === this.drag.pointerId) {
      const uid = this.drag.uid;
      this.drag = null;
      this.controls.enabled = true;
      this.renderer.domElement.style.cursor = '';
      this.callbacks.onDragEnd(uid);
    } else if (this.pointerDownAt) {
      const moved = Math.hypot(event.clientX - this.pointerDownAt.x, event.clientY - this.pointerDownAt.y);
      if (moved < 5 && !this.hitTest(event)) this.callbacks.onSelect(null);
    }
    this.pointerDownAt = null;
  };

  // MARK: Rendering

  private resize(): void {
    const { clientWidth: w, clientHeight: h } = this.container;
    if (w === 0 || h === 0) return;
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
    if (!this.cameraTouched) this.frameRoom();
  }

  private updateWallVisibility(): void {
    const cam = new THREE.Vector2(this.camera.position.x, this.camera.position.z);
    for (const wall of this.walls) {
      const facesCamera = cam.clone().sub(wall.mid).dot(wall.normal) > 0;
      wall.full.visible = !facesCamera;
      wall.stub.visible = facesCamera;
    }
  }

  private tick(): void {
    this.controls.update();
    this.updateWallVisibility();
    this.renderer.render(this.scene, this.camera);
  }

  /**
   * Renders the current view into a new canvas, optionally without furniture
   * (the "before" half of a before/after image). Fit outlines are hidden so
   * the image looks like a room, not an editor.
   */
  snapshot(withFurniture: boolean, width = 1200, height = 900): HTMLCanvasElement {
    const outlines = [...this.furniture.values()].flatMap((v) => [v.outline, v.fill]);
    const visibility = outlines.map((o) => o.visible);
    outlines.forEach((o) => (o.visible = false));
    this.furnitureGroup.visible = withFurniture;

    // Render at a fixed size so the image looks the same from any screen.
    const previousRatio = this.renderer.getPixelRatio();
    this.renderer.setPixelRatio(1);
    this.renderer.setSize(width, height, false);
    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
    this.updateWallVisibility();
    this.renderer.render(this.scene, this.camera);

    const out = document.createElement('canvas');
    out.width = width;
    out.height = height;
    out.getContext('2d')!.drawImage(this.renderer.domElement, 0, 0, width, height);

    this.renderer.setPixelRatio(previousRatio);
    this.resize();
    this.furnitureGroup.visible = true;
    outlines.forEach((o, i) => (o.visible = visibility[i]));
    return out;
  }

  /** Where a placed piece's center sits on screen, in client pixels. Used by the browser tests. */
  screenPosition(uid: string): { x: number; y: number } | null {
    const view = this.furniture.get(uid);
    if (!view) return null;
    const p = view.hitBox.getWorldPosition(new THREE.Vector3()).project(this.camera);
    const rect = this.renderer.domElement.getBoundingClientRect();
    return { x: rect.left + ((p.x + 1) / 2) * rect.width, y: rect.top + ((1 - p.y) / 2) * rect.height };
  }

  /** Resolves once every placed piece's mesh has finished loading (or failed). */
  async whenModelsLoaded(): Promise<void> {
    await Promise.all([...modelCache.values()]);
  }
}
