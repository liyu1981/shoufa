import sharp from "sharp";
import { mkdir } from "fs/promises";

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" fill="none">
  <defs>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="1" dy="2" stdDeviation="2" flood-color="#000" flood-opacity="0.3"/>
    </filter>
  </defs>
  <rect width="256" height="256" rx="48" fill="#f5f0e6"/>
  <g transform="translate(8, 8) scale(10)" filter="url(#shadow)">
    <rect x="2" y="2" width="8" height="8" rx="2" fill="#ef4444"/>
    <rect x="14" y="14" width="8" height="8" rx="2" fill="#3b82f6"/>
    <path d="M7 14v1a2 2 0 0 0 2 2h1" stroke="#f97316" stroke-width="2" stroke-linecap="round" fill="none"/>
    <path d="M14 7h1a2 2 0 0 1 2 2v1" stroke="#22c55e" stroke-width="2" stroke-linecap="round" fill="none"/>
  </g>
</svg>`;

const sizes = [192, 512];

await mkdir("public/icons", { recursive: true });

for (const size of sizes) {
  await sharp(Buffer.from(svg))
    .resize(size, size)
    .png()
    .toFile(`public/icons/icon-${size}x${size}.png`);
  console.log(`Generated icon-${size}x${size}.png`);
}

console.log("All icons generated!");
