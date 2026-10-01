#!/usr/bin/env node
// Renders Sources/NetPulse/Resources/AppIcon.iconset, every size macOS asks
// an .icns for, from the canvas drawing in netpulse-icon.js. Each size is
// drawn natively rather than scaled down from 1024, which keeps 16px and
// 32px crisp. build-app.sh packs the folder with iconutil.
//
//     npm install --no-save playwright && npx playwright install chromium
//     node scripts/icon/make-icon.mjs [variant]
//
// Edit netpulse-icon.js, not the PNGs.
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, '../../Sources/NetPulse/Resources/AppIcon.iconset');
const variant = process.argv[2] ?? 'pulse-navy';
const sizes = [
  [16, 'icon_16x16'], [32, 'icon_16x16@2x'], [32, 'icon_32x32'], [64, 'icon_32x32@2x'],
  [128, 'icon_128x128'], [256, 'icon_128x128@2x'], [256, 'icon_256x256'],
  [512, 'icon_256x256@2x'], [512, 'icon_512x512'], [1024, 'icon_512x512@2x'],
];

const browser = await chromium.launch(
  process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const page = await browser.newPage();
await page.setContent('<canvas></canvas>');
await page.addScriptTag({ path: path.join(here, 'netpulse-icon.js') });
fs.mkdirSync(out, { recursive: true });
for (const [px, name] of sizes) {
  const url = await page.evaluate(([v, s]) => {
    const c = document.querySelector('canvas');
    c.width = c.height = s;
    drawNetPulseIcon(c.getContext('2d'), s, v);
    return c.toDataURL('image/png');
  }, [variant, px]);
  fs.writeFileSync(path.join(out, `${name}.png`), Buffer.from(url.split(',')[1], 'base64'));
}
await browser.close();
console.log(`wrote ${out}`);
