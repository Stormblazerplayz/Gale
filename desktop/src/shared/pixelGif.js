'use strict';
// A small animated GIF writer made for pixel art (same as GalePixel/GIFEncoder.swift):
// colors are kept exactly whenever a frame has 256 or fewer; otherwise a 252-color cube is used.

class GifWriter {
  /** `loops`: 0 = forever. */
  constructor(width, height, loops = 0) {
    this.width = Math.min(65535, Math.max(1, width));
    this.height = Math.min(65535, Math.max(1, height));
    this.parts = [];
    this.size = 0;
    this.finished = false;
    const head = [];
    for (const ch of 'GIF89a') head.push(ch.charCodeAt(0));
    head.push(this.width & 0xff, (this.width >> 8) & 0xff, this.height & 0xff, (this.height >> 8) & 0xff);
    head.push(0x00, 0x00, 0x00);
    head.push(0x21, 0xff, 0x0b);
    for (const ch of 'NETSCAPE2.0') head.push(ch.charCodeAt(0));
    const l = Math.max(0, Math.min(65535, loops));
    head.push(0x03, 0x01, l & 0xff, (l >> 8) & 0xff, 0x00);
    this.push(Uint8Array.from(head));
  }

  push(bytes) {
    this.parts.push(bytes);
    this.size += bytes.length;
  }

  /** Adds a frame ({ width, height, data } RGBA, the GIF's size). Alpha under 128 becomes see-through. */
  add(img, centiseconds) {
    if (this.finished) throw new Error('The GIF is already finished');
    if (img.width !== this.width || img.height !== this.height) throw new Error("Every frame must be the GIF's size");
    const { palette, indexes, transparent } = indexed(img);
    let size = 1;
    while ((1 << size) < palette.length) size += 1;
    size = Math.max(1, size);
    const cs = Math.max(0, Math.min(65535, Math.round(centiseconds)));
    const head = [0x21, 0xf9, 0x04, (1 << 2) | (transparent != null ? 1 : 0), cs & 0xff, (cs >> 8) & 0xff, transparent == null ? 0 : transparent, 0x00];
    head.push(0x2c, 0, 0, 0, 0, this.width & 0xff, (this.width >> 8) & 0xff, this.height & 0xff, (this.height >> 8) & 0xff);
    head.push(0x80 | (size - 1));
    for (let i = 0; i < (1 << size); i++) {
      if (i < palette.length) head.push(palette[i][0], palette[i][1], palette[i][2]);
      else head.push(0, 0, 0);
    }
    const minCode = Math.max(2, size);
    head.push(minCode);
    this.push(Uint8Array.from(head));
    const compressed = lzw(indexes, minCode);
    const blocks = new Uint8Array(compressed.length + Math.ceil(compressed.length / 255) + 1);
    let o = 0;
    for (let i = 0; i < compressed.length; i += 255) {
      const n = Math.min(255, compressed.length - i);
      blocks[o++] = n;
      blocks.set(compressed.subarray(i, i + n), o);
      o += n;
    }
    blocks[o++] = 0;
    this.push(blocks.subarray(0, o));
  }

  /** Writes the end marker and returns the whole file. */
  finish() {
    if (!this.finished) {
      this.push(Uint8Array.of(0x3b));
      this.finished = true;
    }
    const out = new Uint8Array(this.size);
    let o = 0;
    for (const p of this.parts) {
      out.set(p, o);
      o += p.length;
    }
    return out;
  }
}

/** The frame's colors (at most 256) and each pixel's index into them. */
function indexed(img) {
  const n = img.width * img.height;
  const b = img.data;
  const indexes = new Uint8Array(n);
  const lookup = new Map();
  let palette = [];
  let transparent = null;
  let overflow = false;
  for (let i = 0; i < n; i++) {
    const o = i * 4;
    const key = b[o + 3] < 128 ? -1 : (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
    const have = lookup.get(key);
    if (have !== undefined) {
      indexes[i] = have;
      continue;
    }
    if (palette.length === 256) {
      overflow = true;
      break;
    }
    const idx = palette.length;
    lookup.set(key, idx);
    if (key === -1) {
      transparent = idx;
      palette.push([0, 0, 0]);
    } else {
      palette.push([b[o], b[o + 1], b[o + 2]]);
    }
    indexes[i] = idx;
  }
  if (!overflow) return { palette, indexes, transparent };

  palette = [];
  for (let r = 0; r < 6; r++) {
    for (let g = 0; g < 7; g++) {
      for (let bl = 0; bl < 6; bl++) palette.push([r * 51, Math.floor((g * 255 + 3) / 6), bl * 51]);
    }
  }
  const clearIndex = palette.length;
  palette.push([0, 0, 0]);
  let usedClear = false;
  for (let i = 0; i < n; i++) {
    const o = i * 4;
    if (b[o + 3] < 128) {
      indexes[i] = clearIndex;
      usedClear = true;
      continue;
    }
    const r = Math.floor((b[o] * 5 + 127) / 255);
    const g = Math.floor((b[o + 1] * 6 + 127) / 255);
    const bl = Math.floor((b[o + 2] * 5 + 127) / 255);
    indexes[i] = r * 42 + g * 6 + bl;
  }
  return { palette, indexes, transparent: usedClear ? clearIndex : null };
}

/** GIF's variable-length LZW, packed least significant bit first. */
function lzw(indexes, minCodeSize) {
  const clear = 1 << minCodeSize;
  const end = clear + 1;
  let out = new Uint8Array(Math.max(64, indexes.length));
  let len = 0;
  const put = (v) => {
    if (len === out.length) {
      const bigger = new Uint8Array(out.length * 2);
      bigger.set(out);
      out = bigger;
    }
    out[len++] = v;
  };
  let bitBuffer = 0;
  let bitCount = 0;
  let codeSize = minCodeSize + 1;
  const emit = (code) => {
    bitBuffer |= code << bitCount;
    bitCount += codeSize;
    while (bitCount >= 8) {
      put(bitBuffer & 0xff);
      bitBuffer >>>= 8;
      bitCount -= 8;
    }
  };
  const table = new Map();
  let next = end + 1;
  emit(clear);
  if (indexes.length === 0) {
    emit(end);
    if (bitCount > 0) put(bitBuffer & 0xff);
    return out.subarray(0, len);
  }
  let prefix = indexes[0];
  for (let i = 1; i < indexes.length; i++) {
    const k = indexes[i];
    const key = (prefix << 8) | k;
    const code = table.get(key);
    if (code !== undefined) {
      prefix = code;
      continue;
    }
    emit(prefix);
    if (next < 4096) {
      table.set(key, next);
      if (next === (1 << codeSize) && codeSize < 12) codeSize += 1;
      next += 1;
    } else {
      emit(clear);
      table.clear();
      codeSize = minCodeSize + 1;
      next = end + 1;
    }
    prefix = k;
  }
  emit(prefix);
  emit(end);
  if (bitCount > 0) put(bitBuffer & 0xff);
  return out.subarray(0, len);
}

/** Reads a GIF back into RGBA frames (used by the tests to check what was written). */
function decode(bytes) {
  const b = bytes;
  let p = 6;
  const width = b[p] | (b[p + 1] << 8);
  const height = b[p + 2] | (b[p + 3] << 8);
  const flags = b[p + 4];
  p += 7;
  let globalTable = null;
  if (flags & 0x80) {
    const n = 2 << (flags & 7);
    globalTable = b.subarray(p, p + n * 3);
    p += n * 3;
  }
  const frames = [];
  let loops = null;
  let delay = 0;
  let transparent = null;
  const canvas = new Uint8Array(width * height * 4);
  while (p < b.length) {
    const t = b[p++];
    if (t === 0x3b) break;
    if (t === 0x21) {
      const label = b[p++];
      if (label === 0xf9) {
        const pf = b[p + 1];
        delay = b[p + 2] | (b[p + 3] << 8);
        transparent = pf & 1 ? b[p + 4] : null;
      } else if (label === 0xff && String.fromCharCode(...b.subarray(p + 1, p + 12)) === 'NETSCAPE2.0') {
        loops = b[p + 14] | (b[p + 15] << 8);
      }
      while (b[p] !== 0) p += b[p] + 1;
      p += 1;
      continue;
    }
    if (t !== 0x2c) throw new Error(`Bad block ${t}`);
    const x0 = b[p] | (b[p + 1] << 8);
    const y0 = b[p + 2] | (b[p + 3] << 8);
    const w = b[p + 4] | (b[p + 5] << 8);
    const h = b[p + 6] | (b[p + 7] << 8);
    const f = b[p + 8];
    p += 9;
    let table = globalTable;
    if (f & 0x80) {
      const n = 2 << (f & 7);
      table = b.subarray(p, p + n * 3);
      p += n * 3;
    }
    const minCode = b[p++];
    const data = [];
    while (b[p] !== 0) {
      for (let i = 1; i <= b[p]; i++) data.push(b[p + i]);
      p += b[p] + 1;
    }
    p += 1;
    const idx = unlzw(data, minCode, w * h);
    for (let i = 0; i < w * h; i++) {
      const v = idx[i];
      if (v === transparent) continue;
      const o = ((y0 + Math.floor(i / w)) * width + x0 + (i % w)) * 4;
      canvas[o] = table[v * 3];
      canvas[o + 1] = table[v * 3 + 1];
      canvas[o + 2] = table[v * 3 + 2];
      canvas[o + 3] = 255;
    }
    frames.push({ data: canvas.slice(), centiseconds: delay });
  }
  return { width, height, loops, frames };
}

function unlzw(data, minCode, count) {
  const clear = 1 << minCode;
  const end = clear + 1;
  let size = minCode + 1;
  let dict = [];
  const reset = () => {
    dict = [];
    for (let i = 0; i < clear; i++) dict.push([i]);
    dict.push(null, null);
    size = minCode + 1;
  };
  reset();
  const out = [];
  let bit = 0;
  let prev = null;
  while (out.length < count) {
    let code = 0;
    for (let i = 0; i < size; i++) {
      const byte = data[(bit + i) >> 3];
      if (byte === undefined) return out;
      code |= ((byte >> ((bit + i) & 7)) & 1) << i;
    }
    bit += size;
    if (code === clear) {
      reset();
      prev = null;
      continue;
    }
    if (code === end) break;
    let entry;
    if (code < dict.length && dict[code]) entry = dict[code];
    else if (prev) entry = [...prev, prev[0]];
    else throw new Error('Bad LZW code');
    out.push(...entry);
    if (prev) dict.push([...prev, entry[0]]);
    prev = entry;
    if (dict.length === (1 << size) && size < 12) size += 1;
  }
  return out;
}

module.exports = { GifWriter, indexed, lzw, decode };
