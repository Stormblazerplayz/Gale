'use strict';
// Pixel storytime: the story model (same as GaleFormat/Pixel.swift), the grid tools
// (same as GalePixel/PixelTools.swift) and turning cells into colors.
//
// In memory a story is plain JSON like project.json's `pixel`, except each frame keeps its
// cells as a Uint8Array (`cells`) instead of the packed `runs` list.

const OrderKey = require('./orderKey');
const Color = require('./color');

const MIN_SIDE = 8;
const MAX_SIDE = 256;
const MAX_COLORS = 64;
const TRANSITIONS = ['cut', 'fade', 'wipe', 'iris'];
const TRANSITION_TITLES = { cut: 'Cut', fade: 'Fade', wipe: 'Wipe', iris: 'Circle' };
const BUBBLE_STYLES = ['speech', 'thought', 'shout', 'sign'];
const BUBBLE_TITLES = { speech: 'Talk', thought: 'Think', shout: 'Shout', sign: 'Sign' };
const TOOLS = ['pencil', 'eraser', 'fill', 'line', 'rect', 'circle', 'picker', 'move'];
const TOOL_TITLES = {
  pencil: 'Pencil', eraser: 'Eraser', fill: 'Fill', line: 'Line', rect: 'Box', circle: 'Circle', picker: 'Color picker', move: 'Move',
};

const PALETTES = [
  { name: 'PICO-8', hex: ['000000', '1D2B53', '7E2553', '008751', 'AB5236', '5F574F', 'C2C3C7', 'FFF1E8', 'FF004D', 'FFA300', 'FFEC27', '00E436', '29ADFF', '83769C', 'FF77A8', 'FFCCAA'] },
  { name: 'Sweetie 16', hex: ['1A1C2C', '5D275D', 'B13E53', 'EF7D57', 'FFCD75', 'A7F070', '38B764', '257179', '29366F', '3B5DC9', '41A6F6', '73EFF7', 'F4F4F4', '94B0C2', '566C86', '333C57'] },
  { name: 'Endesga 32', hex: ['BE4A2F', 'D77643', 'EAD4AA', 'E4A672', 'B86F50', '733E39', '3E2731', 'A22633', 'E43B44', 'F77622', 'FEAE34', 'FEE761', '63C74D', '3E8948', '265C42', '193C3E', '124E89', '0099DB', '2CE8F5', 'FFFFFF', 'C0CBDC', '8B9BB4', '5A6988', '3A4466', '262B44', '181425', 'FF0044', '68386C', 'B55088', 'F6757A', 'E8B796', 'C28569'] },
  { name: 'NES', hex: ['000000', 'FCFCFC', '7C7C7C', 'BCBCBC', 'A80020', 'F83800', 'FCA044', 'F8B800', '00A800', '58D854', '0058F8', '3CBCFC', '6844FC', 'D800CC', 'F878F8', 'AC7C00'] },
  { name: 'Game Boy', hex: ['0F380F', '306230', '8BAC0F', '9BBC0F'] },
  { name: '1-bit', hex: ['000000', 'FFFFFF'] },
].map((p) => ({ name: p.name, colors: p.hex.map((h) => `#${h}FF`) }));

const CLEAR = '#00000000';

function paletteNamed(name) {
  return PALETTES.find((p) => p.name === name) || null;
}

/** A palette as a story keeps it: see-through first, then the colors. */
function storyPalette(palette) {
  return [CLEAR, ...palette.colors];
}

// ---------- small readers (same rules as the Swift decoders) ----------

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const int = (v, fb) => (Number.isInteger(v) ? v : fb);
const num = (v, fb) => (typeof v === 'number' && Number.isFinite(v) ? v : fb);
const str = (v, fb) => (typeof v === 'string' ? v : fb);
const numList = (v) => (Array.isArray(v) && v.every((x) => typeof x === 'number' && Number.isFinite(x)) ? v : []);
const objList = (v, read) => (Array.isArray(v) && v.every(isObj) ? v.map(read) : []);
const side = (v) => Math.min(MAX_SIDE, Math.max(MIN_SIDE, v));
const unit = (v) => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0.5);

let makeIdFn = null;
function makeId() {
  // model.js requires this file, so load it lazily to avoid a require loop.
  // eslint-disable-next-line global-require
  if (!makeIdFn) makeIdFn = require('./model').makeId;
  return makeIdFn();
}

// ---------- run-length packing ----------

/** Cells to `[count, index, count, index...]`. */
function encodeRuns(cells) {
  const out = [];
  if (!cells || cells.length === 0) return out;
  let current = cells[0];
  let count = 0;
  for (let i = 0; i < cells.length; i++) {
    const v = cells[i];
    if (v === current) {
      count += 1;
    } else {
      out.push(count, current);
      current = v;
      count = 1;
    }
  }
  out.push(count, current);
  return out;
}

/** Bad numbers are skipped; indexes are kept in 0...255. At most `limit` cells come out. */
function decodeRuns(runs, limit = MAX_SIDE * MAX_SIDE) {
  const list = numList(runs);
  let total = 0;
  const parts = [];
  for (let i = 0; i + 1 < list.length && total < limit; i += 2) {
    const n = list[i];
    const v = list[i + 1];
    if (!(n >= 1)) continue;
    const count = Math.trunc(Math.min(n, limit - total));
    if (count <= 0) continue;
    parts.push(count, Math.trunc(Math.min(255, Math.max(0, v))));
    total += count;
  }
  const out = new Uint8Array(total);
  let o = 0;
  for (let i = 0; i < parts.length; i += 2) {
    out.fill(parts[i + 1], o, o + parts[i]);
    o += parts[i];
  }
  return out;
}

// ---------- reading ----------

function readBubble(c) {
  return {
    id: str(c.id, makeId()),
    text: str(c.text, ''),
    x: unit(num(c.x, 0.5)),
    y: unit(num(c.y, 0.2)),
    tailX: unit(num(c.tailX, 0.45)),
    tailY: unit(num(c.tailY, 0.5)),
    style: typeof c.style === 'string' ? (BUBBLE_STYLES.includes(c.style) ? c.style : 'speech') : 'speech',
  };
}

function readFrame(c) {
  let cells;
  if (c.cells instanceof Uint8Array) cells = c.cells.slice();
  else cells = decodeRuns(c.runs);
  return { id: str(c.id, makeId()), key: str(c.key, OrderKey.FIRST), hold: Math.max(1, int(c.hold, 1)), cells };
}

function readScene(c) {
  const frames = objList(c.frames, readFrame);
  frames.sort(OrderKey.compare);
  return {
    id: str(c.id, makeId()),
    key: str(c.key, OrderKey.FIRST),
    name: str(c.name, 'Scene'),
    fps: Math.min(30, Math.max(1, int(c.fps, 8))),
    loops: Math.min(20, Math.max(1, int(c.loops, 2))),
    background: Math.max(0, int(c.background, 0)),
    caption: str(c.caption, ''),
    bubbles: objList(c.bubbles, readBubble),
    transition: typeof c.transition === 'string' ? (TRANSITIONS.includes(c.transition) ? c.transition : 'cut') : 'cut',
    frames,
  };
}

/** Reads a story (from project.json's `pixel`, or one already in memory). Never throws. */
function readStory(json) {
  const c = isObj(json) ? json : {};
  const hex = Array.isArray(c.palette) && c.palette.every((x) => typeof x === 'string') ? c.palette : [];
  const story = {
    width: side(int(c.width, 32)),
    height: side(int(c.height, 32)),
    palette: hex.map((h) => Color.normalize(h, '#000000FF')),
    paletteName: str(c.paletteName, ''),
    paper: Color.normalize(c.paper, Color.WHITE),
    scenes: objList(c.scenes, readScene),
  };
  return normalize(story);
}

function blankFrame(width, height, key = OrderKey.FIRST, hold = 1) {
  return { id: makeId(), key, hold: Math.max(1, hold), cells: new Uint8Array(Math.max(1, width * height)) };
}

function newScene(name, width, height, opts = {}) {
  return {
    id: makeId(),
    key: opts.key || OrderKey.FIRST,
    name,
    fps: Math.min(30, Math.max(1, opts.fps == null ? 8 : opts.fps)),
    loops: Math.min(20, Math.max(1, opts.loops == null ? 2 : opts.loops)),
    background: Math.max(0, opts.background || 0),
    caption: opts.caption || '',
    bubbles: opts.bubbles || [],
    transition: TRANSITIONS.includes(opts.transition) ? opts.transition : 'cut',
    frames: opts.frames || [blankFrame(width, height)],
  };
}

function newBubble(text, opts = {}) {
  return readBubble({ ...opts, id: makeId(), text });
}

/** A fresh story: one scene with one see-through frame. Paper is the palette's last color unless given. */
function newStory({ width = 32, height = 32, paletteName = 'PICO-8', paper } = {}) {
  const pal = paletteNamed(paletteName) || PALETTES[0];
  const w = side(Math.round(width));
  const h = side(Math.round(height));
  return normalize({
    width: w,
    height: h,
    palette: storyPalette(pal),
    paletteName: pal.name,
    paper: paper ? Color.normalize(paper, Color.WHITE) : pal.colors[pal.colors.length - 1],
    scenes: [newScene('Scene 1', w, h)],
  });
}

/** Fixes sizes, palette, order, at least one scene and frame (same as PixelStory.normalize). */
function normalize(story) {
  const s = story;
  s.width = side(s.width);
  s.height = side(s.height);
  if (s.palette.length === 0) s.palette = storyPalette(PALETTES[0]);
  s.palette[0] = CLEAR;
  if (s.palette.length === 1) s.palette.push('#000000FF');
  if (s.palette.length > MAX_COLORS) s.palette = s.palette.slice(0, MAX_COLORS);
  const top = s.palette.length - 1;
  const n = s.width * s.height;
  s.scenes.sort(OrderKey.compare);
  if (s.scenes.length === 0) s.scenes = [newScene('Scene 1', s.width, s.height, { frames: [] })];
  for (const scene of s.scenes) {
    scene.frames.sort(OrderKey.compare);
    if (scene.frames.length === 0) scene.frames = [blankFrame(s.width, s.height)];
    if (scene.background >= s.palette.length) scene.background = 0;
    for (const f of scene.frames) {
      let cells = f.cells;
      if (cells.length !== n) {
        const fixed = new Uint8Array(n);
        fixed.set(cells.length > n ? cells.subarray(0, n) : cells);
        cells = fixed;
      }
      for (let i = 0; i < cells.length; i++) {
        if (cells[i] > top) {
          if (cells === f.cells) cells = cells.slice();
          cells[i] = 0;
        }
      }
      f.cells = cells;
    }
  }
  return s;
}

/** The story as written to project.json (cells packed as runs). */
function storyToJSON(story) {
  return {
    width: story.width,
    height: story.height,
    palette: story.palette.slice(),
    paletteName: story.paletteName,
    paper: story.paper,
    scenes: story.scenes.map((sc) => ({
      id: sc.id,
      key: sc.key,
      name: sc.name,
      fps: sc.fps,
      loops: sc.loops,
      background: sc.background,
      caption: sc.caption,
      bubbles: sc.bubbles.map((b) => ({ ...b })),
      transition: sc.transition,
      frames: sc.frames.map((f) => ({ id: f.id, key: f.key, hold: f.hold, runs: encodeRuns(f.cells) })),
    })),
  };
}

/** A deep copy (cells copied too), so edits never touch the original. */
function cloneStory(story) {
  return {
    ...story,
    palette: story.palette.slice(),
    scenes: story.scenes.map((sc) => ({
      ...sc,
      bubbles: sc.bubbles.map((b) => ({ ...b })),
      frames: sc.frames.map((f) => ({ ...f, cells: f.cells.slice() })),
    })),
  };
}

/**
 * A copy to edit: new story, scene, frame and bubble objects, but the cells arrays are shared.
 * That's safe because cells are never changed in place (every tool makes a new array).
 */
function editableCopy(story) {
  return {
    ...story,
    palette: story.palette.slice(),
    scenes: story.scenes.map((sc) => ({ ...sc, bubbles: sc.bubbles.map((b) => ({ ...b })), frames: sc.frames.map((f) => ({ ...f })) })),
  };
}

/** Same story with brand-new ids (for "Copy"). */
function withFreshIds(story) {
  const out = cloneStory(story);
  for (const sc of out.scenes) {
    sc.id = makeId();
    for (const b of sc.bubbles) b.id = makeId();
    for (const f of sc.frames) f.id = makeId();
  }
  return out;
}

/** The canvas a pixel story reports to apps that only know drawings (same as GaleProject.pixelCanvas). */
function pixelCanvas(story) {
  const k = Math.max(1, Math.floor(1024 / Math.max(story.width, story.height)));
  return { width: story.width * k, height: story.height * k, background: story.paper };
}

// ---------- edits that keep keys right ----------

function insertScene(story, scene, after) {
  const i = Math.min(story.scenes.length - 1, after == null ? story.scenes.length - 1 : after);
  const lower = i >= 0 ? story.scenes[i].key : null;
  const upper = i + 1 < story.scenes.length ? story.scenes[i + 1].key : null;
  scene.key = OrderKey.between(lower, upper) || OrderKey.FIRST;
  story.scenes.splice(i + 1, 0, scene);
  return i + 1;
}

function moveScene(story, from, to) {
  const list = story.scenes;
  if (from < 0 || from >= list.length || to < 0 || to >= list.length || from === to) return;
  const [s] = list.splice(from, 1);
  const lower = to > 0 ? list[to - 1].key : null;
  const upper = to < list.length ? list[to].key : null;
  s.key = OrderKey.between(lower, upper) || s.key;
  list.splice(to, 0, s);
}

function insertFrame(story, frame, sceneIndex, after) {
  const scene = story.scenes[sceneIndex];
  if (!scene) return 0;
  const frames = scene.frames;
  const i = Math.min(frames.length - 1, after == null ? frames.length - 1 : after);
  const lower = i >= 0 ? frames[i].key : null;
  const upper = i + 1 < frames.length ? frames[i + 1].key : null;
  frame.key = OrderKey.between(lower, upper) || OrderKey.FIRST;
  frames.splice(i + 1, 0, frame);
  return i + 1;
}

function moveFrame(story, sceneIndex, from, to) {
  const scene = story.scenes[sceneIndex];
  if (!scene) return;
  const list = scene.frames;
  if (from < 0 || from >= list.length || to < 0 || to >= list.length || from === to) return;
  const [f] = list.splice(from, 1);
  const lower = to > 0 ? list[to - 1].key : null;
  const upper = to < list.length ? list[to].key : null;
  f.key = OrderKey.between(lower, upper) || f.key;
  list.splice(to, 0, f);
}

/** New grid size. Art stays at the top left; new cells are see-through. */
function resize(story, newW, newH) {
  const w = side(newW);
  const h = side(newH);
  if (w === story.width && h === story.height) return;
  for (const sc of story.scenes) {
    for (const f of sc.frames) {
      const old = f.cells;
      const cells = new Uint8Array(w * h);
      for (let y = 0; y < Math.min(h, story.height); y++) {
        for (let x = 0; x < Math.min(w, story.width); x++) cells[y * w + x] = old[y * story.width + x];
      }
      f.cells = cells;
    }
  }
  story.width = w;
  story.height = h;
}

/** Index of the closest opaque color (skips index 0). Greens count more, like eyes do. */
function nearest(hex, palette) {
  const c = Color.parse(hex) || { r: 0, g: 0, b: 0, a: 1 };
  let best = 1;
  let bestD = Infinity;
  for (let i = 1; i < Math.max(2, palette.length); i++) {
    if (i >= palette.length) break;
    const p = Color.parse(palette[i]) || { r: 0, g: 0, b: 0, a: 1 };
    const d = 0.30 * (p.r - c.r) * (p.r - c.r) + 0.59 * (p.g - c.g) * (p.g - c.g) + 0.11 * (p.b - c.b) * (p.b - c.b);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

/** Swaps in another palette; each color goes to the nearest color of the new one. */
function switchPalette(story, palette) {
  const target = storyPalette(palette);
  const map = [0];
  for (let i = 1; i < story.palette.length; i++) map.push(nearest(story.palette[i], target));
  for (const sc of story.scenes) {
    sc.background = sc.background < map.length ? map[sc.background] : 0;
    for (const f of sc.frames) f.cells = f.cells.map((v) => (v < map.length ? map[v] : 0));
  }
  story.palette = target;
  story.paletteName = palette.name;
}

// ---------- grid tools (cells in, cells out) ----------

/** A grid view over cells. Everything is clipped to the grid. */
class Grid {
  constructor(width, height, cells) {
    this.width = Math.max(1, width);
    this.height = Math.max(1, height);
    const n = this.width * this.height;
    if (cells && cells.length === n) this.cells = cells.slice();
    else {
      this.cells = new Uint8Array(n);
      if (cells) this.cells.set(cells.length > n ? cells.subarray(0, n) : cells);
    }
  }

  contains(x, y) {
    return x >= 0 && y >= 0 && x < this.width && y < this.height;
  }

  get(x, y) {
    return this.contains(x, y) ? this.cells[y * this.width + x] : 0;
  }

  set(x, y, v) {
    if (this.contains(x, y)) this.cells[y * this.width + x] = v;
  }

  /** Square brush of `size` cells centered on (x, y), mirrored when asked. */
  stamp(x, y, color, size = 1, mirrorX = false, mirrorY = false) {
    const s = Math.max(1, size);
    const start = -Math.trunc((s - 1) / 2);
    for (let dy = 0; dy < s; dy++) {
      for (let dx = 0; dx < s; dx++) {
        const qx = x + start + dx;
        const qy = y + start + dy;
        this.set(qx, qy, color);
        if (mirrorX) this.set(this.width - 1 - qx, qy, color);
        if (mirrorY) this.set(qx, this.height - 1 - qy, color);
        if (mirrorX && mirrorY) this.set(this.width - 1 - qx, this.height - 1 - qy, color);
      }
    }
  }

  drawLine(a, b, color, size = 1, mirrorX = false, mirrorY = false) {
    for (const p of line(a, b)) this.stamp(p.x, p.y, color, size, mirrorX, mirrorY);
  }

  drawRect(a, b, color, filled = false) {
    const x0 = Math.min(a.x, b.x);
    const x1 = Math.max(a.x, b.x);
    const y0 = Math.min(a.y, b.y);
    const y1 = Math.max(a.y, b.y);
    for (let y = y0; y <= y1; y++) {
      for (let x = x0; x <= x1; x++) {
        if (filled || x === x0 || x === x1 || y === y0 || y === y1) this.set(x, y, color);
      }
    }
  }

  drawEllipse(a, b, color, filled = false) {
    for (const p of ellipse(a, b, filled)) this.set(p.x, p.y, color);
  }

  /** Paint bucket through edges (not corners). Returns how many cells changed. */
  floodFill(sx, sy, color) {
    if (!this.contains(sx, sy)) return 0;
    const w = this.width;
    const h = this.height;
    const c = this.cells;
    const target = c[sy * w + sx];
    if (target === color) return 0;
    const stack = [[sx, sy]];
    let changed = 0;
    while (stack.length) {
      const [px, py] = stack.pop();
      let x = px;
      while (x >= 0 && c[py * w + x] === target) x -= 1;
      x += 1;
      let upOpen = false;
      let downOpen = false;
      while (x < w && c[py * w + x] === target) {
        c[py * w + x] = color;
        changed += 1;
        if (py > 0) {
          const up = c[(py - 1) * w + x] === target;
          if (up && !upOpen) stack.push([x, py - 1]);
          upOpen = up;
        }
        if (py < h - 1) {
          const down = c[(py + 1) * w + x] === target;
          if (down && !downOpen) stack.push([x, py + 1]);
          downOpen = down;
        }
        x += 1;
      }
    }
    return changed;
  }

  replace(from, to) {
    if (from === to) return;
    for (let i = 0; i < this.cells.length; i++) if (this.cells[i] === from) this.cells[i] = to;
  }

  shifted(dx, dy, wrap = true) {
    const out = new Grid(this.width, this.height);
    const w = this.width;
    const h = this.height;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let nx = x + dx;
        let ny = y + dy;
        if (wrap) {
          nx = ((nx % w) + w) % w;
          ny = ((ny % h) + h) % h;
        } else if (nx < 0 || ny < 0 || nx >= w || ny >= h) {
          continue;
        }
        out.cells[ny * w + nx] = this.cells[y * w + x];
      }
    }
    return out;
  }

  flippedHorizontally() {
    const out = new Grid(this.width, this.height);
    for (let y = 0; y < this.height; y++) {
      for (let x = 0; x < this.width; x++) out.cells[y * this.width + x] = this.cells[y * this.width + (this.width - 1 - x)];
    }
    return out;
  }

  flippedVertically() {
    const out = new Grid(this.width, this.height);
    for (let y = 0; y < this.height; y++) {
      for (let x = 0; x < this.width; x++) out.cells[y * this.width + x] = this.cells[(this.height - 1 - y) * this.width + x];
    }
    return out;
  }

  get inkCount() {
    let n = 0;
    for (const v of this.cells) if (v !== 0) n += 1;
    return n;
  }
}

/** Every cell on a straight line (Bresenham). */
function line(a, b) {
  const out = [];
  let x0 = a.x;
  let y0 = a.y;
  const dx = Math.abs(b.x - a.x);
  const dy = -Math.abs(b.y - a.y);
  const sx = a.x < b.x ? 1 : -1;
  const sy = a.y < b.y ? 1 : -1;
  let err = dx + dy;
  for (;;) {
    out.push({ x: x0, y: y0 });
    if (x0 === b.x && y0 === b.y) break;
    const e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x0 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y0 += sy;
    }
  }
  return out;
}

/** Cells of an ellipse that fits the box between two corners, sorted by row then column. */
function ellipse(a, b, filled = false) {
  const x0 = Math.min(a.x, b.x);
  const x1 = Math.max(a.x, b.x);
  const y0 = Math.min(a.y, b.y);
  const y1 = Math.max(a.y, b.y);
  const cx = (x0 + x1) / 2;
  const cy = (y0 + y1) / 2;
  const rx = (x1 - x0) / 2 + 0.5;
  const ry = (y1 - y0) / 2 + 0.5;
  const inside = new Set();
  const key = (x, y) => `${x},${y}`;
  for (let y = y0; y <= y1; y++) {
    for (let x = x0; x <= x1; x++) {
      const nx = (x - cx) / rx;
      const ny = (y - cy) / ry;
      if (nx * nx + ny * ny <= 1.0001) inside.add(key(x, y));
    }
  }
  const out = [];
  for (let y = y0; y <= y1; y++) {
    for (let x = x0; x <= x1; x++) {
      if (!inside.has(key(x, y))) continue;
      if (filled || !inside.has(key(x + 1, y)) || !inside.has(key(x - 1, y)) || !inside.has(key(x, y + 1)) || !inside.has(key(x, y - 1))) {
        out.push({ x, y });
      }
    }
  }
  return out;
}

// ---------- 8-bit colors and pictures ----------

/** "#RRGGBBAA" to [r, g, b, a] bytes. */
function bytes(hex) {
  const c = Color.parse(hex) || { r: 0, g: 0, b: 0, a: 1 };
  return [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255), Math.round(c.a * 255)];
}

/** `c` drawn over `below` (straight alpha), same rounding as Pixel32.over. */
function over(c, below) {
  if (c[3] === 255 || below[3] === 0) return c;
  if (c[3] === 0) return below;
  const sa = c[3] / 255;
  const da = below[3] / 255;
  const oa = sa + da * (1 - sa);
  const mix = (s, d) => Math.min(255, Math.max(0, Math.round((s * sa + d * da * (1 - sa)) / oa)));
  return [mix(c[0], below[0]), mix(c[1], below[1]), mix(c[2], below[2]), Math.min(255, Math.round(oa * 255))];
}

/** Straight mix (t = 0 gives a, 1 gives b). */
function mixed(a, b, t) {
  const k = Math.min(1, Math.max(0, t));
  const m = (x, y) => Math.round(x + (y - x) * k);
  return [m(a[0], b[0]), m(a[1], b[1]), m(a[2], b[2]), m(a[3], b[3])];
}

/** A plain RGBA picture: { width, height, data: Uint8Array } (straight alpha, rows from the top). */
function image(width, height, fill) {
  const w = Math.max(1, width);
  const h = Math.max(1, height);
  const data = new Uint8Array(w * h * 4);
  if (fill && (fill[0] || fill[1] || fill[2] || fill[3])) {
    for (let i = 0; i < data.length; i += 4) {
      data[i] = fill[0];
      data[i + 1] = fill[1];
      data[i + 2] = fill[2];
      data[i + 3] = fill[3];
    }
  }
  return { width: w, height: h, data };
}

function getPx(img, x, y) {
  const i = (y * img.width + x) * 4;
  return [img.data[i], img.data[i + 1], img.data[i + 2], img.data[i + 3]];
}

function setPx(img, x, y, c) {
  const i = (y * img.width + x) * 4;
  img.data[i] = c[0];
  img.data[i + 1] = c[1];
  img.data[i + 2] = c[2];
  img.data[i + 3] = c[3];
}

function fillRect(img, x, y, w, h, c, blend = false) {
  const x0 = Math.max(0, x);
  const y0 = Math.max(0, y);
  const x1 = Math.min(img.width, x + w);
  const y1 = Math.min(img.height, y + h);
  if (x0 >= x1 || y0 >= y1) return;
  const d = img.data;
  for (let yy = y0; yy < y1; yy++) {
    let i = (yy * img.width + x0) * 4;
    for (let xx = x0; xx < x1; xx++) {
      let o = c;
      if (blend) o = over(c, [d[i], d[i + 1], d[i + 2], d[i + 3]]);
      d[i] = o[0];
      d[i + 1] = o[1];
      d[i + 2] = o[2];
      d[i + 3] = o[3];
      i += 4;
    }
  }
}

/** Copies `src` with its top left at (x, y); see-through pixels leave what's below. */
function drawImage(dst, src, x, y) {
  for (let sy = 0; sy < src.height; sy++) {
    const dy = y + sy;
    if (dy < 0 || dy >= dst.height) continue;
    for (let sx = 0; sx < src.width; sx++) {
      const dx = x + sx;
      if (dx < 0 || dx >= dst.width) continue;
      const si = (sy * src.width + sx) * 4;
      const a = src.data[si + 3];
      if (a === 0) continue;
      const c = [src.data[si], src.data[si + 1], src.data[si + 2], a];
      setPx(dst, dx, dy, a === 255 ? c : over(c, getPx(dst, dx, dy)));
    }
  }
}

/** Bigger by a whole number, every pixel a sharp square. */
function scaled(img, k) {
  const s = Math.max(1, Math.trunc(k));
  if (s === 1) return img;
  const out = image(img.width * s, img.height * s);
  const rowBytes = out.width * 4;
  const row = new Uint8Array(rowBytes);
  for (let y = 0; y < img.height; y++) {
    for (let x = 0; x < img.width; x++) {
      const i = (y * img.width + x) * 4;
      for (let j = 0; j < s; j++) {
        const o = (x * s + j) * 4;
        row[o] = img.data[i];
        row[o + 1] = img.data[i + 1];
        row[o + 2] = img.data[i + 2];
        row[o + 3] = img.data[i + 3];
      }
    }
    for (let j = 0; j < s; j++) out.data.set(row, (y * s + j) * rowBytes);
  }
  return out;
}

function crossfade(a, b, t) {
  if (b.width !== a.width || b.height !== a.height) return t < 0.5 ? a : b;
  const k = Math.min(1, Math.max(0, t));
  const out = image(a.width, a.height);
  for (let i = 0; i < a.data.length; i++) out.data[i] = Math.round(a.data[i] + (b.data[i] - a.data[i]) * k);
  return out;
}

function sameImage(a, b) {
  if (a.width !== b.width || a.height !== b.height) return false;
  const x = a.data;
  const y = b.data;
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
  return true;
}

function copyImage(img) {
  return { width: img.width, height: img.height, data: img.data.slice() };
}

// ---------- cells to colors ----------

/** The story palette as bytes (index 0 see-through). */
function colors(story) {
  return story.palette.map((h, i) => (i === 0 ? [0, 0, 0, 0] : bytes(h)));
}

/** The color behind a scene: its background index, or the story's paper. */
function background(story, scene) {
  const c = colors(story);
  if (scene.background > 0 && scene.background < c.length) return c[scene.background];
  return bytes(story.paper);
}

/** One frame at grid size, over `bg` (or see-through when bg is null). */
function renderFrame(cells, width, height, cols, bg) {
  const img = image(width, height, bg || [0, 0, 0, 0]);
  const n = Math.min(cells.length, width * height);
  for (let i = 0; i < n; i++) {
    const v = cells[i];
    if (v === 0 || v >= cols.length) continue;
    const c = cols[v];
    const o = i * 4;
    if (c[3] === 255 || img.data[o + 3] === 0) {
      img.data[o] = c[0];
      img.data[o + 1] = c[1];
      img.data[o + 2] = c[2];
      img.data[o + 3] = c[3];
    } else {
      setPx(img, i % width, Math.floor(i / width), over(c, getPx(img, i % width, Math.floor(i / width))));
    }
  }
  return img;
}

/** Ghost frames for onion skin, farthest first: [{ index, tint, alpha }]. */
function onionGhosts(onion, current, count, loop = false) {
  if (!onion.on || count <= 1) return [];
  const out = [];
  const add = (offset, tint, distance, total) => {
    let i = current + offset;
    if (loop) i = ((i % count) + count) % count;
    if (i < 0 || i >= count || i === current) return;
    const falloff = 1 - (distance - 1) / Math.max(1, total);
    out.push({ index: i, tint, alpha: onion.opacity * falloff });
  };
  for (let d = onion.before; d >= 1; d--) add(-d, [255, 60, 90, 255], d, onion.before);
  for (let d = onion.after; d >= 1; d--) add(d, [40, 140, 255, 255], d, onion.after);
  return out;
}

/** A scene frame at grid size with onion ghosts under it (for the editor). */
function editorFrame(story, s, f, onion) {
  const scene = story.scenes[s];
  if (!scene) return image(story.width, story.height);
  const cols = colors(story);
  const img = image(story.width, story.height, background(story, scene));
  const n = story.width * story.height;
  for (const g of onionGhosts(onion, f, scene.frames.length)) {
    const cells = scene.frames[g.index].cells;
    const a = Math.min(255, Math.max(0, Math.round(g.alpha * 255)));
    for (let i = 0; i < Math.min(cells.length, n); i++) {
      const v = cells[i];
      if (v === 0 || v >= cols.length) continue;
      const c = mixed(cols[v], g.tint, 0.55);
      const x = i % story.width;
      const y = Math.floor(i / story.width);
      setPx(img, x, y, over([c[0], c[1], c[2], a], getPx(img, x, y)));
    }
  }
  if (!scene.frames[f]) return img;
  drawImage(img, renderFrame(scene.frames[f].cells, story.width, story.height, cols, null), 0, 0);
  return img;
}

module.exports = {
  MIN_SIDE,
  MAX_SIDE,
  MAX_COLORS,
  TRANSITIONS,
  TRANSITION_TITLES,
  BUBBLE_STYLES,
  BUBBLE_TITLES,
  TOOLS,
  TOOL_TITLES,
  PALETTES,
  CLEAR,
  paletteNamed,
  storyPalette,
  encodeRuns,
  decodeRuns,
  readStory,
  readScene,
  readFrame,
  readBubble,
  newStory,
  newScene,
  newBubble,
  blankFrame,
  normalize,
  storyToJSON,
  cloneStory,
  editableCopy,
  withFreshIds,
  makeId,
  pixelCanvas,
  insertScene,
  moveScene,
  insertFrame,
  moveFrame,
  resize,
  nearest,
  switchPalette,
  Grid,
  line,
  ellipse,
  bytes,
  over,
  mixed,
  image,
  getPx,
  setPx,
  fillRect,
  drawImage,
  scaled,
  crossfade,
  sameImage,
  copyImage,
  colors,
  background,
  renderFrame,
  onionGhosts,
  editorFrame,
};
