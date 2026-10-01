// Shrinks the Tripo product meshes for the web demo.
//
// The raw Tripo GLBs are 10-40 MB each (~1.4M triangles, 2K-4K textures).
// That is fine as a generation artifact but far too heavy for a web page, so
// this script welds and simplifies each mesh to roughly TARGET_TRIANGLES,
// resizes textures to TEXTURE_SIZE as WebP, and meshopt-compresses geometry.
//
// Only the visual mesh is approximated here. Fit checks never read the mesh:
// they use the catalog's real product dimensions, exactly like the iOS app.
//
// Usage: npm run optimize-models   (reads ../tools/catalog/out-tripo-staged)
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, prune, weld, simplify, textureCompress, meshopt } from '@gltf-transform/functions';
import { MeshoptEncoder, MeshoptSimplifier } from 'meshoptimizer';
import sharp from 'sharp';
import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const SOURCE_DIRS = [
  join(repo, 'tools/catalog/out-tripo-staged'),
  join(repo, 'tools/catalog/out-tripo'),
];
const OUT_DIR = join(here, '..', 'public/models');
const TARGET_TRIANGLES = 60_000;
const TEXTURE_SIZE = 1024;

const catalog = JSON.parse(readFileSync(join(repo, 'Snug/Resources/catalog.json'), 'utf8'));
const asins = catalog.map((item) => item.asin).filter(Boolean);

await MeshoptEncoder.ready;
await MeshoptSimplifier.ready;
const io = new NodeIO()
  .registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({ 'meshopt.encoder': MeshoptEncoder });
mkdirSync(OUT_DIR, { recursive: true });

function triangleCount(doc) {
  let count = 0;
  for (const mesh of doc.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      const indices = prim.getIndices();
      const position = prim.getAttribute('POSITION');
      count += (indices ? indices.getCount() : position.getCount()) / 3;
    }
  }
  return count;
}

for (const asin of asins) {
  const source = SOURCE_DIRS.map((d) => join(d, `${asin}.glb`)).find(existsSync);
  const out = join(OUT_DIR, `${asin}.glb`);
  if (!source) { console.warn(`skip ${asin}: no source GLB`); continue; }
  if (existsSync(out)) { console.log(`keep ${asin} (already optimized)`); continue; }

  const doc = await io.read(source);
  const before = triangleCount(doc);
  const ratio = Math.min(1, TARGET_TRIANGLES / before);
  await doc.transform(
    dedup(),
    weld(),
    simplify({ simplifier: MeshoptSimplifier, ratio, error: 0.002 }),
    prune(),
    textureCompress({ encoder: sharp, targetFormat: 'webp', resize: [TEXTURE_SIZE, TEXTURE_SIZE] }),
    meshopt({ encoder: MeshoptEncoder, level: 'medium' }),
  );
  await io.write(out, doc);
  const mb = (bytes) => (bytes / 1048576).toFixed(1);
  console.log(`${asin}: ${Math.round(before).toLocaleString()} -> ${Math.round(triangleCount(doc)).toLocaleString()} tris, ` +
    `${mb(statSync(source).size)} MB -> ${mb(statSync(out).size)} MB`);
}
