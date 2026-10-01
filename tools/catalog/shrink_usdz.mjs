// Shrinks the bundled Tripo product models so the app stays installable.
//
// Tripo's meshes arrive at ~1.4M triangles (40-85 MB per USDZ), which put the
// app bundle near 700 MB, far past the App Store's 200 MB cellular download
// limit. Fit checks never read the mesh (they use the catalog's real
// dimensions), so the visual mesh can be simplified hard without changing any
// fit verdict.
//
// For each USDZ this script:
//   1. unpacks it and decodes the binary layer to text with macOS `usdcat`,
//   2. simplifies the mesh to ~TARGET_TRIANGLES with meshoptimizer, weighting
//      UVs so texture seams stay intact,
//   3. recomputes smooth normals from the simplified surface,
//   4. resizes textures to TEXTURE_SIZE with macOS `sips`,
//   5. re-encodes, repackages with `usdzip --arkitAsset`, and validates with
//      `usdchecker --arkit`.
//
// Only the mesh arrays are rewritten. Transforms, materials and texture paths
// are left exactly as they were, so every model keeps the orientation and look
// the app already expects. Needs only macOS's built-in USD tools.
//
// Usage:
//   npm install
//   node shrink_usdz.mjs                 # writes to out-shrunk/ for review
//   node shrink_usdz.mjs --apply         # replaces the files in the app bundle
//   node shrink_usdz.mjs --only tripo_B0GXKG8QHW
import { MeshoptSimplifier } from 'meshoptimizer';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const TARGET_TRIANGLES = 60_000;
const TEXTURE_SIZE = 1024;
// Simplification error budget as a fraction of the mesh's extent. The target
// triangle count is the real limit; this only stops it from wrecking a shape.
const TARGET_ERROR = 0.02;
const UV_WEIGHT = 0.5;

const here = dirname(fileURLToPath(import.meta.url));
const modelsDir = join(here, '..', '..', 'Snug', 'Resources', 'Models');
const args = process.argv.slice(2);
const apply = args.includes('--apply');
const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null;
const outDir = apply ? modelsDir : join(here, 'out-shrunk');

const run = (cmd, cmdArgs, opts = {}) => execFileSync(cmd, cmdArgs, { stdio: ['ignore', 'pipe', 'pipe'], ...opts }).toString();
const mb = (bytes) => (bytes / 1048576).toFixed(1);

/** Every number in an array literal line, as a Float64Array. */
function parseNumbers(line) {
  // Anchor on "= [": the type name itself contains brackets (`int[] ...`).
  const body = line.slice(line.indexOf('= [') + 3, line.lastIndexOf(']'));
  const parts = body.replace(/[()]/g, ' ').split(/[\s,]+/);
  const out = new Float64Array(parts.length);
  let n = 0;
  for (const p of parts) if (p) out[n++] = Number(p);
  return out.subarray(0, n);
}

const fmt = (v) => {
  if (Object.is(v, -0) || Math.abs(v) < 1e-9) return '0';
  return Number(v.toPrecision(7)).toString();
};
const tuples = (arr, size) => {
  const parts = new Array(arr.length / size);
  for (let i = 0; i < parts.length; i++) {
    const t = [];
    for (let k = 0; k < size; k++) t.push(fmt(arr[i * size + k]));
    parts[i] = `(${t.join(', ')})`;
  }
  return parts.join(', ');
};
const ints = (arr) => Array.from(arr).join(', ');

/** Finds the single line declaring `name`, e.g. `point3f[] points = [...]`. */
function findLine(lines, name) {
  const re = new RegExp(`^\\s*\\S+\\[\\] ${name.replace(/[:]/g, '\\:')} = \\[`);
  const hits = lines.flatMap((l, i) => (re.test(l) ? [i] : []));
  return hits.length === 1 ? hits[0] : hits.length === 0 ? -1 : NaN;
}

/**
 * Area-weighted smooth normals for the simplified mesh, shared across UV
 * seams (vertices at the same position get the same normal, so seams don't
 * show as shading lines). Each vertex's original normal only picks the side:
 * the fine-scale normals of a 1.4M-triangle mesh no longer match the coarser
 * surface and make shiny materials look crinkled.
 */
function computeSmoothNormals(points, indices, out, originalNormals, kept) {
  const key = (i) => `${points[i * 3].toFixed(5)},${points[i * 3 + 1].toFixed(5)},${points[i * 3 + 2].toFixed(5)}`;
  const groupOf = new Int32Array(points.length / 3);
  const groups = new Map();
  for (let i = 0; i < groupOf.length; i++) {
    const k = key(i);
    if (!groups.has(k)) groups.set(k, groups.size);
    groupOf[i] = groups.get(k);
  }
  const acc = new Float64Array(groups.size * 3);
  for (let t = 0; t < indices.length; t += 3) {
    const [a, b, c] = [indices[t], indices[t + 1], indices[t + 2]];
    const ux = points[b * 3] - points[a * 3], uy = points[b * 3 + 1] - points[a * 3 + 1], uz = points[b * 3 + 2] - points[a * 3 + 2];
    const vx = points[c * 3] - points[a * 3], vy = points[c * 3 + 1] - points[a * 3 + 1], vz = points[c * 3 + 2] - points[a * 3 + 2];
    // Cross product: its length is twice the triangle area, so this is area-weighted.
    const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    for (const v of [a, b, c]) {
      const g = groupOf[v];
      acc[g * 3] += nx;
      acc[g * 3 + 1] += ny;
      acc[g * 3 + 2] += nz;
    }
  }
  for (let i = 0; i < groupOf.length; i++) {
    const g = groupOf[i];
    let nx = acc[g * 3], ny = acc[g * 3 + 1], nz = acc[g * 3 + 2];
    // Keep the winding the original mesh used: flip if it disagrees with the
    // original normal at this vertex.
    const old = kept[i];
    const dot = nx * originalNormals[old * 3] + ny * originalNormals[old * 3 + 1] + nz * originalNormals[old * 3 + 2];
    if (dot < 0) { nx = -nx; ny = -ny; nz = -nz; }
    const len = Math.hypot(nx, ny, nz) || 1;
    out[i * 3] = nx / len;
    out[i * 3 + 1] = ny / len;
    out[i * 3 + 2] = nz / len;
  }
}

function shrinkLayer(usda) {
  const lines = usda.split('\n');
  const meshCount = lines.filter((l) => /^\s*def Mesh /.test(l)).length;
  if (meshCount !== 1) throw new Error(`expected exactly one Mesh, found ${meshCount}`);

  const at = Object.fromEntries(
    ['points', 'faceVertexIndices', 'faceVertexCounts', 'normals', 'primvars:st', 'primvars:st:indices', 'extent'].map((n) => [n, findLine(lines, n)]),
  );
  for (const name of ['points', 'faceVertexIndices', 'faceVertexCounts', 'primvars:st']) {
    if (!(at[name] >= 0)) throw new Error(`missing or duplicate ${name}`);
  }

  const points = parseNumbers(lines[at.points]);
  const fvi = Uint32Array.from(parseNumbers(lines[at.faceVertexIndices]));
  const counts = parseNumbers(lines[at.faceVertexCounts]);
  if (!counts.every((c) => c === 3)) throw new Error('mesh is not all triangles');
  const vertexCount = points.length / 3;

  // UVs: this pipeline writes them faceVarying but indexed by the same indices
  // as the points, which is per-vertex in practice. Anything else is skipped.
  const st = parseNumbers(lines[at['primvars:st']]);
  if (at['primvars:st:indices'] >= 0) {
    const stIndices = parseNumbers(lines[at['primvars:st:indices']]);
    if (stIndices.length !== fvi.length || stIndices.some((v, i) => v !== fvi[i]) || st.length / 2 !== vertexCount) {
      throw new Error('UV indexing differs from point indexing; not supported');
    }
  } else if (st.length / 2 !== vertexCount) {
    throw new Error('UVs are not per-vertex; not supported');
  }

  // Original smooth normals, averaged onto each vertex.
  const normals = new Float64Array(vertexCount * 3);
  if (at.normals >= 0) {
    const fvNormals = parseNumbers(lines[at.normals]);
    const perCorner = fvNormals.length === fvi.length * 3;
    for (let c = 0; c < fvi.length; c++) {
      const v = fvi[c];
      const src = perCorner ? c : v;
      normals[v * 3] += fvNormals[src * 3];
      normals[v * 3 + 1] += fvNormals[src * 3 + 1];
      normals[v * 3 + 2] += fvNormals[src * 3 + 2];
    }
  }

  const targetIndexCount = Math.min(fvi.length, TARGET_TRIANGLES * 3);
  const [simplified] = MeshoptSimplifier.simplifyWithAttributes(
    fvi,
    Float32Array.from(points),
    3,
    Float32Array.from(st),
    2,
    [UV_WEIGHT, UV_WEIGHT],
    null,
    targetIndexCount,
    TARGET_ERROR,
    [],
  );

  // Compact: keep only referenced vertices, in first-use order.
  const remap = new Int32Array(vertexCount).fill(-1);
  const kept = [];
  const indices = new Uint32Array(simplified.length);
  for (let i = 0; i < simplified.length; i++) {
    const old = simplified[i];
    if (remap[old] < 0) {
      remap[old] = kept.length;
      kept.push(old);
    }
    indices[i] = remap[old];
  }
  const newPoints = new Float64Array(kept.length * 3);
  const newNormals = new Float64Array(kept.length * 3);
  const newST = new Float64Array(kept.length * 2);
  const lo = [Infinity, Infinity, Infinity];
  const hi = [-Infinity, -Infinity, -Infinity];
  kept.forEach((old, i) => {
    for (let k = 0; k < 3; k++) {
      const p = points[old * 3 + k];
      newPoints[i * 3 + k] = p;
      lo[k] = Math.min(lo[k], p);
      hi[k] = Math.max(hi[k], p);
    }
    newST[i * 2] = st[old * 2];
    newST[i * 2 + 1] = st[old * 2 + 1];
  });

  computeSmoothNormals(newPoints, indices, newNormals, normals, kept);

  const indent = (i) => lines[i].match(/^\s*/)[0];
  const setInterpolation = (lineIndex) => {
    // The `( interpolation = ... )` metadata sits on the lines right after.
    for (let j = lineIndex + 1; j < Math.min(lines.length, lineIndex + 4); j++) {
      if (/interpolation = /.test(lines[j])) {
        lines[j] = lines[j].replace(/interpolation = "\w+"/, 'interpolation = "vertex"');
        return;
      }
    }
  };
  lines[at.points] = `${indent(at.points)}point3f[] points = [${tuples(newPoints, 3)}]`;
  lines[at.faceVertexIndices] = `${indent(at.faceVertexIndices)}int[] faceVertexIndices = [${ints(indices)}]`;
  lines[at.faceVertexCounts] = `${indent(at.faceVertexCounts)}int[] faceVertexCounts = [${new Array(indices.length / 3).fill(3).join(', ')}]`;
  lines[at['primvars:st']] = lines[at['primvars:st']].replace(/= \[.*\]/, `= [${tuples(newST, 2)}]`);
  setInterpolation(at['primvars:st']);
  if (at.normals >= 0) {
    lines[at.normals] = lines[at.normals].replace(/= \[.*\]/, `= [${tuples(newNormals, 3)}]`);
    setInterpolation(at.normals);
  }
  if (at.extent >= 0) {
    lines[at.extent] = `${indent(at.extent)}float3[] extent = [(${lo.map(fmt).join(', ')}), (${hi.map(fmt).join(', ')})]`;
  }
  if (at['primvars:st:indices'] >= 0) lines[at['primvars:st:indices']] = '';

  return { usda: lines.join('\n'), before: fvi.length / 3, after: indices.length / 3, vertices: kept.length };
}

await MeshoptSimplifier.ready;
mkdirSync(outDir, { recursive: true });
const files = readdirSync(modelsDir)
  .filter((f) => f.startsWith('tripo_') && f.endsWith('.usdz'))
  .filter((f) => !only || basename(f, '.usdz') === only);

let totalBefore = 0;
let totalAfter = 0;
for (const file of files) {
  const source = join(modelsDir, file);
  const name = basename(file, '.usdz');
  const work = mkdtempSync(join(tmpdir(), `shrink-${name}-`));
  const before = statSync(source).size;
  try {
    run('unzip', ['-q', source, '-d', work]);
    const rootLayer = readdirSync(work).find((f) => f.endsWith('.usdc') || f.endsWith('.usda'));
    if (!rootLayer) throw new Error('no root layer in archive');
    const textLayer = join(work, `${name}.edit.usda`);
    run('usdcat', [join(work, rootLayer), '-o', textLayer]);

    const result = shrinkLayer(readFileSync(textLayer, 'utf8'));
    if (result.after >= result.before) {
      console.log(`${name}: already ${result.before.toLocaleString()} triangles, skipped`);
      continue;
    }
    writeFileSync(textLayer, result.usda);

    const textureDir = join(work, 'textures');
    try {
      for (const t of readdirSync(textureDir)) run('sips', ['-Z', String(TEXTURE_SIZE), join(textureDir, t)]);
    } catch {
      // No textures folder: nothing to resize.
    }

    // Re-encode under the original root layer name so the archive looks the same.
    const rebuilt = join(work, `${name}.usdc`);
    rmSync(join(work, rootLayer), { force: true });
    run('usdcat', [textLayer, '-o', rebuilt]);
    rmSync(textLayer);
    const packaged = join(work, `${name}.usdz`);
    run('usdzip', ['--arkitAsset', rebuilt, packaged], { cwd: work });
    const check = run('usdchecker', ['--arkit', packaged]);
    if (/fail/i.test(check)) throw new Error(`usdchecker --arkit failed:\n${check}`);

    const target = join(outDir, file);
    copyFileSync(packaged, target);
    const after = statSync(target).size;
    totalBefore += before;
    totalAfter += after;
    console.log(
      `${name}: ${result.before.toLocaleString()} -> ${result.after.toLocaleString()} triangles, ` +
        `${mb(before)} MB -> ${mb(after)} MB`,
    );
  } catch (error) {
    console.error(`${name}: FAILED, left unchanged. ${error.message ?? error}`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
console.log(`Total: ${mb(totalBefore)} MB -> ${mb(totalAfter)} MB${apply ? ' (applied to the app bundle)' : ` (review in ${outDir})`}`);
