#!/usr/bin/env node
// Remove the background outside the rounded windows in README screenshots.
// Requires ImageMagick. Run: node scripts/clean-screenshot-corners.mjs
// Optional arguments: PNG paths to process instead of docs/screenshot*.png.
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';

const cornerSize = 64;
const paths = process.argv.slice(2);
if (!paths.length) {
  paths.push(...readdirSync('docs').filter(name => /^screenshot.*\.png$/.test(name))
    .map(name => `docs/${name}`));
}

function read(path) {
  const png = readFileSync(path);
  if (!png.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) {
    throw new Error(`${path}: expected a PNG`);
  }
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  const rgba = execFileSync('magick', [path, '-depth', '8', 'rgba:-'], {
    maxBuffer: width * height * 4 + 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (rgba.length !== width * height * 4) throw new Error(`${path}: unexpected pixel data`);
  return { path, png, width, height, rgba };
}

const light = (rgba, i) => (rgba[i] + rgba[i + 1] + rgba[i + 2]) / 3;

// Recover coverage from the screenshot's white matte. Read only the corner
// squares; leave the window's text, icons, controls and other pixels alone.
function whiteCorner(image, right, bottom) {
  const { width, height, rgba } = image;
  const mask = new Uint8Array(cornerSize * cornerSize).fill(255);
  const index = (x, y) => ((bottom ? height - 1 - y : y) * width
    + (right ? width - 1 - x : x)) * 4;
  for (let y = 0; y < cornerSize; y++) {
    let edge = 0;
    while (edge < cornerSize && light(rgba, index(edge, y)) > 70) edge++;
    if (!edge || edge + 12 >= cornerSize) continue;
    const samples = Array.from({ length: 8 }, (_, j) => light(rgba, index(edge + 4 + j, y)))
      .sort((a, b) => a - b);
    const foreground = samples[4];
    for (let x = 0; x < edge; x++) {
      const value = light(rgba, index(x, y));
      const alpha = value >= 240 ? 0 : Math.max(0, Math.min(1, (255 - value) / (255 - foreground)));
      mask[y * cornerSize + x] = Math.round(alpha * 255);
    }
  }
  return mask;
}

function applyCorner(image, mask, right, bottom, whiteMatte) {
  const { width, height, rgba } = image;
  for (let y = 0; y < cornerSize; y++) {
    for (let x = 0; x < cornerSize; x++) {
      const alpha = mask[y * cornerSize + x];
      if (alpha === 255) continue;
      const i = ((bottom ? height - 1 - y : y) * width + (right ? width - 1 - x : x)) * 4;
      // Unmatte just the antialiased edge, to avoid a white fringe on dark pages.
      if (whiteMatte && alpha > 0) {
        const coverage = alpha / 255;
        for (let channel = 0; channel < 3; channel++) {
          rgba[i + channel] = Math.max(0, Math.min(255,
            Math.round((rgba[i + channel] - 255 * (1 - coverage)) / coverage)));
        }
      }
      rgba[i + 3] = alpha;
    }
  }
}

function chunk(type, data) {
  const content = Buffer.concat([Buffer.from(type), data]);
  let crc = 0xffffffff;
  for (const byte of content) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([length, content, checksum]);
}

function save(image) {
  const { png, width, height, rgba } = image;
  const header = Buffer.from(png.subarray(16, 29));
  header[8] = 8;
  header[9] = 6; // RGBA; preserve dimensions and original color-profile chunks.
  header[12] = 0;
  const metadata = [];
  for (let offset = 8; offset < png.length;) {
    const length = png.readUInt32BE(offset);
    const type = png.toString('ascii', offset + 4, offset + 8);
    if (!['IHDR', 'IDAT', 'IEND', 'PLTE', 'tRNS', 'sBIT', 'hIST'].includes(type)) {
      metadata.push(png.subarray(offset, offset + length + 12));
    }
    offset += length + 12;
  }
  const stride = width * 4;
  const rows = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) rgba.copy(rows, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  writeFileSync(image.path, Buffer.concat([
    png.subarray(0, 8), chunk('IHDR', header), ...metadata,
    chunk('IDAT', deflateSync(rows, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
  ]));
}

const images = paths.map(read);
const reference = images.find(image => light(image.rgba, 0) >= 240 && image.rgba[3] === 255);
const referenceMasks = reference ? [false, true].map(bottom =>
  [false, true].map(right => whiteCorner(reference, right, bottom))) : null;
for (const image of images) {
  if (image.width < cornerSize * 2 || image.height < cornerSize * 2) throw new Error(`${image.path}: image too small`);
  const cornerIndices = [0, (image.width - 1) * 4,
    (image.height - 1) * image.width * 4, (image.width * image.height - 1) * 4];
  if (cornerIndices.every(i => image.rgba[i + 3] === 0)) {
    console.log(`${image.path}: already transparent`);
    continue;
  }
  for (const bottom of [false, true]) {
    for (const right of [false, true]) {
      const i = ((bottom ? image.height - 1 : 0) * image.width + (right ? image.width - 1 : 0)) * 4;
      const whiteMatte = light(image.rgba, i) >= 240;
      // The install sheet has a dark background above it; a cursor can also
      // cover an outermost pixel. Those corners share the window's silhouette.
      const mask = whiteMatte ? whiteCorner(image, right, bottom)
        : referenceMasks?.[Number(bottom)][Number(right)];
      if (mask) applyCorner(image, mask, right, bottom, whiteMatte || bottom);
    }
  }
  save(image);
  console.log(`${image.path}: transparent corners`);
}
