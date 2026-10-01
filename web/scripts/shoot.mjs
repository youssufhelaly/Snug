// Takes screenshots of the running demo with the locally installed Chrome.
// Usage: node scripts/shoot.mjs <url> <out.png> [width] [height] [--click-first]
import { chromium } from 'playwright-core';

const [url, out, width = '1440', height = '900', ...flags] = process.argv.slice(2);
const browser = await chromium.launch({ channel: 'chrome', args: ['--use-angle=metal', '--enable-gpu'] });
const page = await browser.newPage({ viewport: { width: Number(width), height: Number(height) }, deviceScaleFactor: 1 });
const logs = [];
page.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
page.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));
await page.goto(url, { waitUntil: 'networkidle' });
await page.waitForFunction(() => window.snug !== undefined, null, { timeout: 15000 });
await page.evaluate(() => window.snug.whenModelsLoaded());
await page.waitForTimeout(800);
if (flags.includes('--click-first')) {
  // Select the first placed piece by clicking the center of its hit box on screen.
  await page.evaluate(() => document.querySelector('#catalog button[data-add]')?.scrollIntoView());
}
await page.screenshot({ path: out });
console.log(logs.filter((l) => !l.startsWith('debug')).join('\n') || 'no console output');
await browser.close();
