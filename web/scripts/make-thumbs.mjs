// Saves a WebP thumbnail per product into public/thumbs, rendered from our
// own optimized 3D models by tools/thumbs.html.
// Usage: npm run thumbs   (starts a temporary Vite dev server)
import { createServer } from 'vite';
import { chromium } from 'playwright-core';
import sharp from 'sharp';
import { mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const outDir = join(root, 'public/thumbs');
mkdirSync(outDir, { recursive: true });

const server = await createServer({ root, server: { port: 5199, strictPort: true }, logLevel: 'error' });
await server.listen();
const browser = await chromium.launch({ channel: 'chrome' });
try {
  const page = await browser.newPage();
  page.on('pageerror', (e) => console.error('page error:', e.message));
  await page.goto('http://localhost:5199/tools/thumbs.html');
  await page.waitForFunction(() => window.thumbs !== undefined, null, { timeout: 120000 });
  const thumbs = await page.evaluate(() => window.thumbs);
  for (const [asin, dataURL] of Object.entries(thumbs)) {
    const png = Buffer.from(dataURL.split(',')[1], 'base64');
    await sharp(png).trim({ threshold: 1 }).resize(192, 192, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .extend({ top: 16, bottom: 16, left: 16, right: 16, background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .webp({ quality: 82 }).toFile(join(outDir, `${asin}.webp`));
  }
  console.log(`Wrote ${Object.keys(thumbs).length} thumbnails to public/thumbs`);
} finally {
  await browser.close();
  await server.close();
}
