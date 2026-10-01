// Renders one product thumbnail per catalog item from our own 3D models, so
// the demo never hot-links Amazon product photos.
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/examples/jsm/libs/meshopt_decoder.module.js';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
import { CATALOG, modelURL } from '../src/catalog';
import { approximateFit } from '../src/scene/modelFit';

const SIZE = 256;
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.setSize(SIZE, SIZE);
renderer.setPixelRatio(1);
renderer.toneMapping = THREE.NeutralToneMapping;
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.setClearColor(0x000000, 0);
document.body.appendChild(renderer.domElement);

const loader = new GLTFLoader().setMeshoptDecoder(MeshoptDecoder);
const results: Record<string, string> = {};

for (const item of CATALOG) {
  const scene = new THREE.Scene();
  scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environmentIntensity = 0.7;
  scene.add(new THREE.HemisphereLight(0xffffff, 0xd9c9b8, 1.2));
  const sun = new THREE.DirectionalLight(0xffffff, 1.6);
  sun.position.set(2, 4, 3);
  scene.add(sun);

  const gltf = await loader.loadAsync(modelURL(item));
  const model = gltf.scene;
  model.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(model);
  const fit = approximateFit(box.getSize(new THREE.Vector3()), box.getCenter(new THREE.Vector3()), item);
  const wrapper = new THREE.Group();
  wrapper.add(model);
  wrapper.position.set(fit.position.x, fit.position.y + item.height / 2, fit.position.z);
  wrapper.rotation.y = fit.yRotation;
  wrapper.scale.set(fit.scale.x, fit.scale.y, fit.scale.z);
  scene.add(wrapper);

  // Frame the true-size bounding box from a three-quarter view.
  const radius = Math.hypot(item.width, item.depth, item.height) / 2;
  const camera = new THREE.PerspectiveCamera(30, 1, 0.01, 50);
  const target = new THREE.Vector3(0, item.height / 2, 0);
  const distance = (radius / Math.sin(THREE.MathUtils.degToRad(15))) * 1.02;
  camera.position.copy(target).add(new THREE.Vector3(0.9, 0.55, 1.3).normalize().multiplyScalar(distance));
  camera.lookAt(target);
  renderer.render(scene, camera);
  results[item.asin] = renderer.domElement.toDataURL('image/png');
}

(window as unknown as { thumbs: Record<string, string> }).thumbs = results;
