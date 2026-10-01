// End-to-end check of the built demo in real Chrome: loads the starter room,
// drags a piece into a wall, and confirms the fit verdict changes honestly.
// Usage: npm run build && npx vite preview --port 4173 & node scripts/e2e.mjs
import { chromium } from 'playwright-core';

const url = process.argv[2] ?? 'http://localhost:4173/';
const shots = process.argv[3] ?? '/tmp';
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));

await page.goto(url, { waitUntil: 'networkidle' });
await page.waitForFunction(() => window.snug);
await page.evaluate(() => window.snug.whenModelsLoaded());
await page.waitForTimeout(500);

const items = await page.evaluate(() => window.snug.items());
console.log('starter states:', items.map((i) => `${i.itemId}=${i.state}`).join(', '));

// Drag the dresser straight back into the wall behind it.
const dresser = items.find((i) => i.itemId === 'amzn-b0gmw7fq83');
const from = await page.evaluate((uid) => window.snug.screenPosition(uid), dresser.uid);
await page.mouse.move(from.x, from.y);
await page.mouse.down();
for (let k = 1; k <= 10; k++) await page.mouse.move(from.x + k * 2, from.y - k * 6);
await page.mouse.up();
await page.waitForTimeout(300);
const afterDrag = (await page.evaluate(() => window.snug.items())).find((i) => i.uid === dresser.uid);
console.log(`dresser after drag: z ${dresser.z.toFixed(2)} -> ${afterDrag.z.toFixed(2)}, state ${afterDrag.state}`);
const badge = await page.locator('.fit-badge').innerText();
console.log('inspector badge:', badge.replace(/\s+/g, ' '));
await page.screenshot({ path: `${shots}/snug-drag.png` });

// Add a wardrobe and check it auto-places somewhere it fits.
await page.fill('#search', 'wardrobe');
await page.locator('#catalog button[data-add]').first().click();
await page.evaluate(() => window.snug.whenModelsLoaded());
await page.waitForTimeout(400);
const added = (await page.evaluate(() => window.snug.items())).at(-1);
console.log(`added ${added.itemId} at (${added.x}, ${added.z}) rot ${added.rotation}: ${added.state}`);

// The URL must reproduce the layout.
const hash = await page.evaluate(() => location.hash);
const page2 = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
await page2.goto(url + hash, { waitUntil: 'networkidle' });
await page2.waitForFunction(() => window.snug);
await page2.evaluate(() => window.snug.whenModelsLoaded());
await page2.waitForTimeout(500);
const restored = await page2.evaluate(() => window.snug.items().length);
console.log(`shared link restored ${restored} of ${items.length + 1} pieces`);
await page2.screenshot({ path: `${shots}/snug-mobile.png` });

// Before/after image export.
const [download] = await Promise.all([page.waitForEvent('download'), page.click('#share-image')]);
await download.saveAs(`${shots}/snug-before-after.png`);
console.log('before/after saved:', download.suggestedFilename());

console.log(errors.length ? `ERRORS:\n${errors.join('\n')}` : 'no page errors');
await browser.close();
