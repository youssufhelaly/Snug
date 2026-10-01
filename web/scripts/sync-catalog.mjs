// Copies the iOS app's bundled catalog into the web demo, keeping only what
// the demo needs.
//
// Deliberately dropped:
// - priceCents: hard-coded prices go stale, and Amazon's Associates rules
//   restrict showing prices that don't come live from their API.
// - imageURL: hot-linking Amazon product photos is restricted too, so the demo
//   uses thumbnails rendered from our own 3D models instead.
// - affiliateTag: the placeholder tag isn't a real Associates ID. The demo
//   reads a real one from VITE_AMAZON_TAG at build time, if you set one.
//
// Usage: npm run sync-catalog
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = join(here, '..', '..', 'Snug/Resources/catalog.json');
const target = join(here, '..', 'src/data/catalog.json');

const items = JSON.parse(readFileSync(source, 'utf8')).map((item) => {
  const [width, depth, height] = item.dimensions;
  return {
    id: item.id,
    asin: item.asin,
    name: item.name,
    brand: item.brand,
    category: item.category,
    width,
    depth,
    height,
    color: item.trueColorRGB,
    material: item.material,
    productURL: `https://www.amazon.com/dp/${item.asin}`,
  };
});

writeFileSync(target, JSON.stringify(items, null, 2) + '\n');
console.log(`Wrote ${items.length} items to src/data/catalog.json`);
