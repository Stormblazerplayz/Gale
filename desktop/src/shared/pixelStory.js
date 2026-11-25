'use strict';
// Playing a pixel story: the chunky font, when each scene plays, and the picture at any moment
// (art made big, speech bubbles, caption bar, transitions). Same as GalePixel's PixelFont,
// StoryTiming and StoryRenderer, so the computer shows exactly what the iPad shows.

const P = require('./pixel');
const { GLYPHS } = require('./pixelFontGlyphs');

// ---------- letters ----------

const segmenter = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : null;

/** Text split into letters the way Swift counts them (grapheme clusters). */
function letters(text) {
  const s = String(text == null ? '' : text);
  if (segmenter) return Array.from(segmenter.segment(s), (x) => x.segment);
  return Array.from(s);
}

/** Swift's trimmingCharacters(in: .whitespacesAndNewlines). */
function trim(text) {
  return String(text == null ? '' : text).replace(/^[\s\u0085]+|[\s\u0085]+$/gu, '');
}

const Font = {
  glyphWidth: 5,
  glyphRows: 9,
  advance: 6,
  lineHeight: 11,
  capHeight: 7,

  /** Rows for one letter. Accents are dropped; anything unknown becomes "?". */
  rows(ch) {
    for (const cp of Array.from(ch)) {
      const g = GLYPHS[cp.codePointAt(0)];
      if (g) return g;
    }
    switch (ch) {
      case '‘': case '’': return GLYPHS[39];
      case '“': case '”': return GLYPHS[34];
      case '…': return GLYPHS[46];
      case '—': case '–': return GLYPHS[45];
      case '\n': case '\t': return GLYPHS[32];
      default: break;
    }
    const plain = ch.normalize('NFKD');
    const first = plain.codePointAt(0);
    if (first != null && GLYPHS[first]) return GLYPHS[first];
    return GLYPHS[63];
  },

  /** Lines of at most `maxChars` letters, breaking at spaces. Returns lines as letter arrays joined to strings. */
  wrap(text, maxChars) {
    const limit = Math.max(1, maxChars);
    const all = letters(text);
    const paragraphs = [[]];
    for (const ch of all) {
      if (ch === '\n') paragraphs.push([]);
      else paragraphs[paragraphs.length - 1].push(ch);
    }
    const lines = [];
    for (const para of paragraphs) {
      const words = [];
      let word = [];
      for (const ch of para) {
        if (ch === ' ') {
          if (word.length) words.push(word);
          word = [];
        } else {
          word.push(ch);
        }
      }
      if (word.length) words.push(word);
      let line = [];
      for (const w0 of words) {
        let w = w0;
        while (w.length > limit) {
          if (line.length) {
            lines.push(line);
            line = [];
          }
          lines.push(w.slice(0, limit));
          w = w.slice(limit);
        }
        if (w.length === 0) continue;
        if (line.length === 0) line = w;
        else if (line.length + 1 + w.length <= limit) line = [...line, ' ', ...w];
        else {
          lines.push(line);
          line = w;
        }
      }
      lines.push(line);
    }
    while (lines.length > 1 && lines[lines.length - 1].length === 0) lines.pop();
    return lines.map((l) => l.join(''));
  },

  size(lines) {
    const longest = lines.reduce((m, l) => Math.max(m, letters(l).length), 0);
    const w = longest === 0 ? 0 : longest * Font.advance - 1;
    const h = lines.length === 0 ? 0 : (lines.length - 1) * Font.lineHeight + Font.capHeight;
    return { width: w, height: h };
  },

  draw(text, img, x, y, scale, color, visible) {
    const s = Math.max(1, scale);
    let cx = x;
    const chars = letters(text);
    for (let i = 0; i < chars.length; i++) {
      if (visible != null && i >= visible) break;
      const rows = Font.rows(chars[i]);
      for (let r = 0; r < rows.length; r++) {
        const mask = rows[r];
        if (!mask) continue;
        for (let c = 0; c < Font.glyphWidth; c++) {
          if (mask & (1 << (4 - c))) P.fillRect(img, cx + c * s, y + r * s, s, s, color);
        }
      }
      cx += Font.advance * s;
    }
  },

  drawLines(lines, img, x, y, width, scale, color, centered, visible) {
    let left = visible;
    for (let i = 0; i < lines.length; i++) {
      const count = letters(lines[i]).length;
      const lineW = count === 0 ? 0 : (count * Font.advance - 1) * scale;
      const lx = centered ? x + Math.trunc((width - lineW) / 2) : x;
      Font.draw(lines[i], img, lx, y + i * Font.lineHeight * scale, scale, color, left);
      if (left != null) {
        const l = left;
        left = Math.max(0, l - count - 1);
        if (l <= count) break;
      }
    }
  },

  typedLength(lines) {
    if (!lines.length) return 0;
    return lines.reduce((n, l) => n + letters(l).length, 0) + lines.length - 1;
  },
};

// ---------- timing ----------

const LETTERS_PER_SECOND = 24;
const TRANSITION_SECONDS = 0.5;
const READ_SECONDS = 1.6;
const TYPE_DELAY = 0.2;
const MIN_SCENE_SECONDS = 0.5;
const MAX_SCENE_SECONDS = 60;

const ticks = (scene) => scene.frames.reduce((n, f) => n + f.hold, 0);
const loopSeconds = (scene) => Math.max(1, ticks(scene)) / scene.fps;
const typeStart = (scene) => (scene.transition === 'cut' ? 0 : TRANSITION_SECONDS) + TYPE_DELAY;

/** Letters the typewriter shows in a scene: the caption, then each bubble. */
function sceneLetters(scene) {
  return [scene.caption, ...scene.bubbles.map((b) => b.text)].reduce((n, t) => n + letters(trim(t)).length, 0);
}

class Timing {
  constructor(story) {
    this.spans = [];
    let t = 0;
    story.scenes.forEach((scene, i) => {
      const ts = typeStart(scene);
      const count = sceneLetters(scene);
      const reading = count === 0 ? 0 : ts + count / LETTERS_PER_SECOND + READ_SECONDS;
      const animation = scene.loops * loopSeconds(scene);
      const d = Math.min(MAX_SCENE_SECONDS, Math.max(MIN_SCENE_SECONDS, animation, reading));
      this.spans.push({ scene: i, start: t, duration: d, typeStart: ts });
      t += d;
    });
    this.total = t;
  }

  /** Which scene plays at `time` and how far into it. */
  locate(time, loop = true) {
    if (!this.spans.length || !(this.total > 0)) return { scene: 0, local: 0 };
    let t = Number.isFinite(time) ? time : 0;
    if (loop) {
      t %= this.total;
      if (t < 0) t += this.total;
    } else {
      t = Math.min(Math.max(0, t), this.total - 1e-9);
    }
    let lo = 0;
    let hi = this.spans.length - 1;
    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      if (this.spans[mid].start <= t) lo = mid;
      else hi = mid - 1;
    }
    const s = this.spans[lo];
    return { scene: s.scene, local: Math.min(s.duration, Math.max(0, t - s.start)) };
  }

  typed(scene, local) {
    const span = this.spans[scene];
    if (!span) return 0;
    const t = local - span.typeStart;
    if (!(t > 0)) return 0;
    return Math.floor(t * LETTERS_PER_SECOND);
  }

  /** Frame of a scene `local` seconds after it starts (the animation loops). */
  static frameIndex(scene, local) {
    const total = ticks(scene);
    if (total <= 0 || scene.frames.length <= 1) return 0;
    let tick = Math.floor(Math.max(0, local) * scene.fps) % total;
    for (let i = 0; i < scene.frames.length; i++) {
      if (tick < scene.frames[i].hold) return i;
      tick -= scene.frames[i].hold;
    }
    return scene.frames.length - 1;
  }
}

// ---------- the picture ----------

const BAR = [26, 28, 44, 255];
const BAR_TEXT = [255, 241, 232, 255];
const BAR_EDGE = [124, 58, 237, 255];
const INK = [20, 20, 28, 255];
const BUBBLE_FILL = [255, 255, 255, 255];
const SIGN_FILL = [255, 236, 39, 255];
const BLACK = [0, 0, 0, 255];

function layoutFor(story, maxSide, evenSize = false) {
  const side = Math.max(story.width, story.height);
  const artScale = Math.max(1, Math.floor(maxSide / side));
  const artWidth = story.width * artScale;
  const artHeight = story.height * artScale;
  const textScale = Math.max(1, Math.floor(artWidth / 170));
  const pad = 3 * textScale;
  const captionChars = Math.max(4, Math.floor((artWidth - 2 * pad) / (Font.advance * textScale)));
  let lines = 0;
  for (const scene of story.scenes) {
    const text = trim(scene.caption);
    const n = text ? Math.min(4, Font.wrap(text, captionChars).length) : 0;
    if (n > lines) lines = n;
  }
  let bar = lines === 0 ? 0 : 2 * pad + ((lines - 1) * Font.lineHeight + Font.capHeight + 2) * textScale;
  let h = artHeight + bar;
  if (evenSize && h % 2 === 1) {
    bar += 1;
    h += 1;
  }
  return {
    artScale,
    textScale,
    artWidth,
    artHeight,
    barHeight: bar,
    width: evenSize && artWidth % 2 === 1 ? artWidth + 1 : artWidth,
    height: h,
    captionChars,
  };
}

function transition(kind, a, b, progress) {
  const p = Math.min(1, Math.max(0, progress));
  switch (kind) {
    case 'fade': return P.crossfade(a, b, Math.floor(p * 8) / 8);
    case 'wipe': {
      const out = P.copyImage(a);
      const edge = Math.trunc(b.width * p);
      const count = Math.min(edge, b.width) * 4;
      if (count > 0) {
        for (let y = 0; y < b.height; y++) {
          const start = y * b.width * 4;
          out.data.set(b.data.subarray(start, start + count), start);
        }
      }
      return out;
    }
    case 'iris': {
      const out = P.copyImage(a);
      const cx = b.width / 2;
      const cy = b.height / 2;
      const r = Math.sqrt(cx * cx + cy * cy) * p;
      const r2 = r * r;
      const cell = Math.max(1, Math.floor(Math.min(b.width, b.height) / 48));
      for (let y = 0; y < b.height; y += cell) {
        for (let x = 0; x < b.width; x += cell) {
          const dx = x + cell / 2 - cx;
          const dy = y + cell / 2 - cy;
          if (!(dx * dx + dy * dy <= r2)) continue;
          for (let yy = y; yy < Math.min(b.height, y + cell); yy++) {
            const start = (yy * b.width + x) * 4;
            const end = start + (Math.min(b.width, x + cell) - x) * 4;
            out.data.set(b.data.subarray(start, end), start);
          }
        }
      }
      return out;
    }
    default: return b;
  }
}

class Renderer {
  /** `maxSide`: biggest the art may be, in output pixels. `evenSize` makes both sides even (for video). */
  constructor(story, maxSide = 720, evenSize = false) {
    this.story = story;
    this.timing = new Timing(story);
    this.layout = layoutFor(story, maxSide, evenSize);
    this.cols = P.colors(story);
  }

  imageAt(time, loop = true) {
    const { scene, local } = this.timing.locate(time, loop);
    return this.image(scene, local);
  }

  image(s, local) {
    const L = this.layout;
    const scene = this.story.scenes[s];
    if (!scene) return P.image(L.width, L.height, BLACK);
    const now = this.sceneImage(s, local);
    const p = local / TRANSITION_SECONDS;
    if (scene.transition === 'cut' || p >= 1) return now;
    const prev = this.timing.spans[s - 1];
    const before = s > 0 && prev ? this.sceneImage(s - 1, prev.duration) : P.image(L.width, L.height, BLACK);
    return transition(scene.transition, before, now, p);
  }

  art(s, f) {
    const scene = this.story.scenes[s];
    const fi = Math.min(Math.max(0, f), scene.frames.length - 1);
    const grid = P.renderFrame(scene.frames[fi].cells, this.story.width, this.story.height, this.cols, P.background(this.story, scene));
    return P.scaled(grid, this.layout.artScale);
  }

  sceneImage(s, local) {
    const L = this.layout;
    const scene = this.story.scenes[s];
    const img = P.image(L.width, L.height, BAR);
    P.drawImage(img, this.art(s, Timing.frameIndex(scene, local)), 0, 0);
    const typed = this.timing.typed(s, local);
    const caption = trim(scene.caption);
    const capLen = letters(caption).length;
    const captionShown = Math.min(typed, capLen);
    let left = typed - capLen;
    for (const bubble of scene.bubbles) {
      const text = trim(bubble.text);
      if (!text) continue;
      if (left <= 0) break;
      this.drawBubble(bubble, text, img, left);
      left -= letters(text).length;
    }
    if (L.barHeight > 0) this.drawCaption(caption, img, captionShown, typed >= sceneLetters(scene), local);
    return img;
  }

  drawCaption(text, img, visible, done, local) {
    const L = this.layout;
    const t = L.textScale;
    const top = L.artHeight;
    P.fillRect(img, 0, top, L.width, t, BAR_EDGE);
    if (!text) return;
    const lines = Font.wrap(text, L.captionChars).slice(0, 4);
    const pad = 3 * t;
    const shown = visible >= letters(text).length ? Font.typedLength(lines) : visible;
    Font.drawLines(lines, img, pad, top + pad + t, L.artWidth - 2 * pad, t, BAR_TEXT, true, shown);
    if (done && Math.trunc(local * 2.5) % 2 === 0) {
      const ax = L.artWidth - pad - 5 * t;
      const ay = L.height - pad - 3 * t;
      P.fillRect(img, ax, ay, 5 * t, t, BAR_TEXT);
      P.fillRect(img, ax + t, ay + t, 3 * t, t, BAR_TEXT);
      P.fillRect(img, ax + 2 * t, ay + 2 * t, t, t, BAR_TEXT);
    }
  }

  /** The cells (text-scale units from the art's top left) a bubble covers, and where its text goes. */
  bubbleShape(bubble, text) {
    const L = this.layout;
    const t = L.textScale;
    const gw = Math.floor(L.artWidth / t);
    const gh = Math.floor(L.artHeight / t);
    const maxChars = Math.max(6, Math.min(18, Math.trunc((Math.trunc((gw * 7) / 10) - 6) / Font.advance)));
    const lines = Font.wrap(text, maxChars);
    const size = Font.size(lines);
    const bw = Math.min(gw, size.width + 6);
    const bh = Math.min(gh, size.height + 6);
    let bx = Math.round(bubble.x * gw) - Math.trunc(bw / 2);
    let by = Math.round(bubble.y * gh) - Math.trunc(bh / 2);
    bx = Math.min(Math.max(1, bx), Math.max(1, gw - bw - 1));
    by = Math.min(Math.max(1, by), Math.max(1, gh - bh - 1));

    const cells = new Set();
    const k = (x, y) => `${x},${y}`;
    for (let y = by; y < by + bh; y++) {
      for (let x = bx; x < bx + bw; x++) {
        const corner = (x === bx || x === bx + bw - 1) && (y === by || y === by + bh - 1);
        if (!corner) cells.add(k(x, y));
      }
    }
    if (bubble.style === 'shout') {
      for (let x = bx + 2; x < bx + bw - 2; x += 4) {
        cells.add(k(x, by - 1));
        cells.add(k(x + 1, by + bh));
      }
      for (let y = by + 2; y < by + bh - 2; y += 4) {
        cells.add(k(bx - 1, y));
        cells.add(k(bx + bw, y + 1));
      }
    }
    const tip = { x: bubble.tailX * gw, y: bubble.tailY * gh };
    const insideBox = tip.x >= bx && tip.x <= bx + bw && tip.y >= by && tip.y <= by + bh;
    if (bubble.style !== 'sign' && !insideBox) {
      const nx = Math.min(Math.max(tip.x, bx + 2.5), bx + bw - 2.5);
      const ny = Math.min(Math.max(tip.y, by + 2.5), by + bh - 2.5);
      const base = { x: nx, y: ny };
      let along = { x: 1, y: 0 };
      if (tip.y >= by + bh) base.y = by + bh - 0.5;
      else if (tip.y <= by) base.y = by + 0.5;
      else if (tip.x >= bx + bw) {
        base.x = bx + bw - 0.5;
        along = { x: 0, y: 1 };
      } else {
        base.x = bx + 0.5;
        along = { x: 0, y: 1 };
      }
      const dx = tip.x - base.x;
      const dy = tip.y - base.y;
      const dist = Math.sqrt(dx * dx + dy * dy);
      const reach = Math.min(dist, 9);
      const end = { x: base.x + (dx / Math.max(0.001, dist)) * reach, y: base.y + (dy / Math.max(0.001, dist)) * reach };
      if (bubble.style === 'thought') {
        const mid = { x: base.x + (end.x - base.x) * 0.45, y: base.y + (end.y - base.y) * 0.45 };
        const mx = Math.floor(mid.x);
        const my = Math.floor(mid.y);
        for (const [ox, oy] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) cells.add(k(mx + ox, my + oy));
        cells.add(k(Math.floor(end.x), Math.floor(end.y)));
      } else {
        const half = bubble.style === 'shout' ? 1.0 : 1.6;
        const b1 = { x: base.x - along.x * half, y: base.y - along.y * half };
        const b2 = { x: base.x + along.x * half, y: base.y + along.y * half };
        const minX = Math.floor(Math.min(b1.x, b2.x, end.x)) - 1;
        const maxX = Math.ceil(Math.max(b1.x, b2.x, end.x)) + 1;
        const minY = Math.floor(Math.min(b1.y, b2.y, end.y)) - 1;
        const maxY = Math.ceil(Math.max(b1.y, b2.y, end.y)) + 1;
        const sign = (p, a, b) => (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y);
        for (let y = minY; y <= maxY; y++) {
          for (let x = minX; x <= maxX; x++) {
            const p = { x: x + 0.5, y: y + 0.5 };
            const d1 = sign(p, b1, b2);
            const d2 = sign(p, b2, end);
            const d3 = sign(p, end, b1);
            const neg = d1 < 0 || d2 < 0 || d3 < 0;
            const pos = d1 > 0 || d2 > 0 || d3 > 0;
            if (!(neg && pos)) cells.add(k(x, y));
          }
        }
      }
    }
    const list = [];
    for (const key of cells) {
      const [x, y] = key.split(',').map(Number);
      if (x >= 0 && y >= 0 && x < gw && y < gh) list.push({ x, y });
    }
    return { cells: list, box: { x: bx, y: by, w: bw, h: bh }, lines, textOrigin: { x: bx + 3, y: by + 3 } };
  }

  drawBubble(bubble, text, img, visible) {
    const t = this.layout.textScale;
    const shape = this.bubbleShape(bubble, text);
    const fill = bubble.style === 'sign' ? SIGN_FILL : BUBBLE_FILL;
    const has = new Set(shape.cells.map((c) => `${c.x},${c.y}`));
    for (const c of shape.cells) {
      const edge = !has.has(`${c.x + 1},${c.y}`) || !has.has(`${c.x - 1},${c.y}`) || !has.has(`${c.x},${c.y + 1}`) || !has.has(`${c.x},${c.y - 1}`);
      P.fillRect(img, c.x * t, c.y * t, t, t, edge ? INK : fill);
    }
    const shown = visible >= letters(text).length ? Font.typedLength(shape.lines) : visible;
    Font.drawLines(shape.lines, img, shape.textOrigin.x * t, shape.textOrigin.y * t, (shape.box.w - 6) * t, t, INK, true, shown);
  }

  /**
   * Pictures and how long each shows (hundredths of a second), sampled `perSecond` times a second
   * with repeats merged. Covers the whole story once.
   */
  frames(perSecond = 25) {
    const it = this.frameSteps(perSecond);
    for (;;) {
      const r = it.next();
      if (r.done) return r.value;
    }
  }

  /** Same as frames(), one sample at a time: yields { done, count } so a window can show progress and stop. */
  *frameSteps(perSecond = 25) {
    const step = 1 / Math.max(1, perSecond);
    const count = Math.max(1, Math.ceil(this.timing.total / step));
    const out = [];
    let lastStart = 0;
    for (let i = 0; i < count; i++) {
      const t = i * step;
      const img = this.imageAt(t, false);
      if (!(out.length && P.sameImage(out[out.length - 1].image, img))) {
        if (out.length) out[out.length - 1].centiseconds = Math.max(2, Math.round((t - lastStart) * 100));
        out.push({ image: img, centiseconds: 0 });
        lastStart = t;
      }
      yield { done: i + 1, count };
    }
    if (out.length) out[out.length - 1].centiseconds = Math.max(2, Math.round((this.timing.total - lastStart) * 100));
    return out;
  }
}

// ---------- sprite sheets ----------

function sheetLayout(frames, cellWidth, cellHeight, columns) {
  const n = Math.max(1, frames);
  const cols = Math.min(n, Math.max(1, columns == null ? Math.ceil(Math.sqrt(n)) : columns));
  const rows = Math.floor((n + cols - 1) / cols);
  return { columns: cols, rows, cellWidth, cellHeight, width: cols * cellWidth, height: rows * cellHeight };
}

/** One scene's frames on one picture for games. With `transparent`, empty cells stay see-through. */
function spriteSheet(story, s, scale = 1, columns = null, transparent = true) {
  const k = Math.max(1, Math.trunc(scale));
  const scene = story.scenes[s];
  if (!scene) {
    const l = sheetLayout(1, story.width * k, story.height * k);
    return { image: P.image(l.width, l.height), layout: l };
  }
  const l = sheetLayout(scene.frames.length, story.width * k, story.height * k, columns);
  const sheet = P.image(l.width, l.height);
  const cols = P.colors(story);
  const bg = transparent ? null : P.background(story, scene);
  scene.frames.forEach((f, i) => {
    const img = P.scaled(P.renderFrame(f.cells, story.width, story.height, cols, bg), k);
    P.drawImage(sheet, img, (i % l.columns) * l.cellWidth, Math.floor(i / l.columns) * l.cellHeight);
  });
  return { image: sheet, layout: l };
}

/** The JSON games read next to the sheet (same text as SpriteSheet.json in Swift). */
function spriteSheetJSON(story, s, l, imageName) {
  const scene = story.scenes[s];
  if (!scene) return '{}';
  const frames = scene.frames.map((f, i) => {
    const x = (i % l.columns) * l.cellWidth;
    const y = Math.floor(i / l.columns) * l.cellHeight;
    const ms = Math.round((f.hold / scene.fps) * 1000);
    return `    {"x": ${x}, "y": ${y}, "w": ${l.cellWidth}, "h": ${l.cellHeight}, "duration": ${ms}}`;
  });
  const name = String(imageName).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  return `{\n  "image": "${name}",\n  "width": ${l.width},\n  "height": ${l.height},\n  "fps": ${scene.fps},\n  "frames": [\n${frames.join(',\n')}\n  ]\n}\n`;
}

module.exports = {
  letters,
  trim,
  Font,
  Timing,
  Renderer,
  layoutFor,
  transition,
  sceneLetters,
  sheetLayout,
  spriteSheet,
  spriteSheetJSON,
  LETTERS_PER_SECOND,
  TRANSITION_SECONDS,
  READ_SECONDS,
  TYPE_DELAY,
  COLORS: { BAR, BAR_TEXT, BAR_EDGE, INK, BUBBLE_FILL, SIGN_FILL },
};
