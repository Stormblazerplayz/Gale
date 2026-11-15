'use strict';
// The Gale project model (format "gale/1"), read the same forgiving way as the Swift decoders:
// missing or wrong-type fields get their defaults, unknown fields are ignored.
//
// In memory a project is plain JSON in the same shape as project.json
// (colors are "#RRGGBBAA" strings, stroke points are the flat `pts` list, dates are ISO strings).

const OrderKey = require('./orderKey');
const Color = require('./color');

const FORMAT = 'gale/1';
const PT_STRIDE = 6;
const BRUSH_KINDS = ['pen', 'pencil', 'marker', 'brush', 'airbrush', 'eraser'];
const BRUSH_TITLES = { pen: 'Pen', pencil: 'Pencil', marker: 'Marker', brush: 'Ink Brush', airbrush: 'Airbrush', eraser: 'Eraser' };
const MEDIA_KINDS = ['video', 'audio', 'image'];
const TRACK_KINDS = ['video', 'audio'];
const ID_CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789';

// ---------- small readers ----------

function randomBytes(n) {
  const out = new Uint8Array(n);
  const c = typeof globalThis !== 'undefined' && globalThis.crypto;
  if (c && typeof c.getRandomValues === 'function') {
    c.getRandomValues(out);
  } else {
    // Node without Web Crypto on the global object.
    // eslint-disable-next-line global-require
    const nodeCrypto = require('crypto');
    out.set(nodeCrypto.randomBytes(n));
  }
  return out;
}

/** A new random id: 22 lowercase letters and digits. */
function makeId() {
  // 252 is the biggest multiple of 36 below 256, so every character is equally likely.
  let s = '';
  while (s.length < 22) {
    for (const b of randomBytes(32)) {
      if (b < 252 && s.length < 22) s += ID_CHARS[b % 36];
    }
  }
  return s;
}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const num = (v, fb) => (typeof v === 'number' && Number.isFinite(v) ? v : fb);
const int = (v, fb) => (Number.isInteger(v) ? v : fb);
const str = (v, fb) => (typeof v === 'string' ? v : fb);
const bool = (v, fb) => (typeof v === 'boolean' ? v : fb);
const color = (v, fb) => {
  const c = Color.parse(v);
  return c ? Color.toHex(c) : fb;
};
const numList = (v) => (Array.isArray(v) && v.every((x) => typeof x === 'number' && Number.isFinite(x)) ? v.slice() : []);
/** Like Swift: one bad element (not an object) makes the whole list fall back to empty. */
const objList = (v, read) => (Array.isArray(v) && v.every(isObj) ? v.map(read) : []);

/** Rounds like Swift's .rounded(): halves go away from zero. */
function roundHalfAway(v) {
  return v < 0 ? -Math.round(-v) : Math.round(v);
}
const round2 = (v) => (Number.isFinite(v) ? roundHalfAway(v * 100) / 100 : 0);
const round3 = (v) => (Number.isFinite(v) ? roundHalfAway(v * 1000) / 1000 : 0);

/** ISO 8601 without fractions of a second, like Swift writes. */
function formatDate(ms) {
  const d = new Date(Number.isFinite(ms) ? ms : Date.now());
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** Reads ISO 8601 strings (with or without fractions) or numbers (ms, or seconds when small). Returns ms or null. */
function parseDate(v) {
  if (typeof v === 'string') {
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/.test(v.trim())) return null;
    const ms = Date.parse(v.trim());
    return Number.isFinite(ms) ? ms : null;
  }
  if (typeof v === 'number' && Number.isFinite(v)) return v > 1e11 ? v : v * 1000;
  return null;
}

const readDate = (v, fbMs) => {
  const ms = parseDate(v);
  return formatDate(ms == null ? fbMs : ms);
};

// ---------- points ----------

function packPoints(points) {
  const out = new Array(points.length * PT_STRIDE);
  let i = 0;
  for (const p of points) {
    out[i++] = round2(p.x);
    out[i++] = round2(p.y);
    out[i++] = round3(p.pressure);
    out[i++] = round3(p.altitude);
    out[i++] = round3(p.azimuth);
    out[i++] = round3(p.time);
  }
  return out;
}

function unpackPoints(flat) {
  const n = Math.floor((flat ? flat.length : 0) / PT_STRIDE);
  const out = new Array(n);
  for (let i = 0; i < n; i++) {
    const b = i * PT_STRIDE;
    out[i] = { x: flat[b], y: flat[b + 1], pressure: flat[b + 2], altitude: flat[b + 3], azimuth: flat[b + 4], time: flat[b + 5] };
  }
  return out;
}

/** The pts list as it will be saved (rounded). */
function roundPts(pts) {
  const out = new Array(pts.length);
  for (let i = 0; i < pts.length; i++) out[i] = i % PT_STRIDE < 2 ? round2(pts[i]) : round3(pts[i]);
  return out;
}

function point(x, y, pressure = 0.5, altitude = Math.PI / 2, azimuth = 0, time = 0) {
  return { x, y, pressure, altitude, azimuth, time };
}

// ---------- readers (one per type) ----------

function readBrush(v) {
  const c = isObj(v) ? v : {};
  const kind = typeof c.kind === 'string' ? (BRUSH_KINDS.includes(c.kind) ? c.kind : 'pen') : 'pen';
  return { kind, color: color(c.color, Color.BLACK), size: num(c.size, 8), opacity: num(c.opacity, 1) };
}

function readStroke(c) {
  return {
    id: str(c.id, makeId()),
    key: str(c.key, OrderKey.FIRST),
    brush: isObj(c.brush) ? readBrush(c.brush) : readBrush({}),
    pts: (() => {
      const flat = numList(c.pts);
      return flat.slice(0, Math.floor(flat.length / PT_STRIDE) * PT_STRIDE);
    })(),
  };
}

function readFill(c) {
  return { id: str(c.id, makeId()), key: str(c.key, OrderKey.FIRST), color: color(c.color, Color.BLACK), path: numList(c.path) };
}

function readCel(v) {
  const c = isObj(v) ? v : {};
  const cel = { strokes: objList(c.strokes, readStroke), fills: objList(c.fills, readFill) };
  cel.strokes.sort(OrderKey.compare);
  cel.fills.sort(OrderKey.compare);
  return cel;
}

function readLayer(c) {
  return {
    id: str(c.id, makeId()),
    key: str(c.key, OrderKey.FIRST),
    name: str(c.name, 'Layer'),
    visible: bool(c.visible, true),
    locked: bool(c.locked, false),
    opacity: num(c.opacity, 1),
  };
}

function readFrame(c) {
  let cels = {};
  if (isObj(c.cels) && Object.values(c.cels).every(isObj)) {
    for (const [lid, cel] of Object.entries(c.cels)) cels[lid] = readCel(cel);
  } else {
    cels = {};
  }
  return { id: str(c.id, makeId()), key: str(c.key, OrderKey.FIRST), hold: Math.max(1, int(c.hold, 1)), cels };
}

function readMotionBlur(v) {
  const c = isObj(v) ? v : {};
  return { on: bool(c.on, false), amount: num(c.amount, 0.6), samples: int(c.samples, 6) };
}

function readHair(c) {
  return {
    id: str(c.id, makeId()),
    layer: str(c.layer, ''),
    polygon: numList(c.polygon),
    root: Array.isArray(c.root) && c.root.every((x) => typeof x === 'number' && Number.isFinite(x)) ? c.root.slice() : [0, 0, 0, 0],
    stiffness: num(c.stiffness, 0.4),
    wind: num(c.wind, 0),
    gust: num(c.gust, 0.3),
    speed: num(c.speed, 0.8),
    on: bool(c.on, true),
  };
}

function readMedia(c) {
  return {
    id: str(c.id, makeId()),
    file: str(c.file, ''),
    kind: typeof c.kind === 'string' ? (MEDIA_KINDS.includes(c.kind) ? c.kind : 'video') : 'video',
    name: str(c.name, 'Clip'),
    duration: num(c.duration, 0),
    sha256: str(c.sha256, ''),
  };
}

function readTrack(c) {
  return {
    id: str(c.id, makeId()),
    key: str(c.key, OrderKey.FIRST),
    kind: typeof c.kind === 'string' ? (TRACK_KINDS.includes(c.kind) ? c.kind : 'audio') : 'audio',
    name: str(c.name, 'Track'),
    muted: bool(c.muted, false),
    volume: num(c.volume, 1),
  };
}

function readClip(c) {
  return {
    id: str(c.id, makeId()),
    track: str(c.track, ''),
    media: str(c.media, ''),
    start: num(c.start, 0),
    in: num(c.in, 0),
    duration: num(c.duration, 0),
    speed: num(c.speed, 1),
    volume: num(c.volume, 1),
    fadeIn: num(c.fadeIn, 0),
    fadeOut: num(c.fadeOut, 0),
  };
}

function readMovie(v) {
  const c = isObj(v) ? v : {};
  const movie = { overlay: bool(c.overlay, false), tracks: objList(c.tracks, readTrack), clips: objList(c.clips, readClip) };
  movie.tracks.sort(OrderKey.compare);
  return movie;
}

function readCanvas(v) {
  const c = isObj(v) ? v : {};
  return {
    width: Math.max(16, num(c.width, 1920)),
    height: Math.max(16, num(c.height, 1080)),
    background: color(c.background, Color.WHITE),
  };
}

function newLayer(name = 'Layer 1', key = OrderKey.FIRST) {
  return { id: makeId(), key, name, visible: true, locked: false, opacity: 1 };
}

function newFrame(key = OrderKey.FIRST, hold = 1) {
  return { id: makeId(), key, hold: Math.max(1, hold), cels: {} };
}

/** Fixes anything a hand-edited or synced file could get wrong: sort orders, at least one layer and one frame. */
function normalize(p) {
  p.layers.sort(OrderKey.compare);
  p.frames.sort(OrderKey.compare);
  if (p.layers.length === 0) p.layers = [newLayer('Layer 1')];
  if (p.frames.length === 0) p.frames = [newFrame()];
  p.fps = Math.min(60, Math.max(1, p.fps));
  p.movie.tracks.sort(OrderKey.compare);
  return p;
}

/** Reads project.json (already parsed). Never throws: anything odd gets the default. */
function readProject(json) {
  const c = isObj(json) ? json : {};
  const now = Date.now();
  const createdMs = parseDate(c.created);
  const created = formatDate(createdMs == null ? now : createdMs);
  const p = {
    format: str(c.format, FORMAT),
    id: str(c.id, makeId()),
    name: str(c.name, 'Untitled'),
    created,
    modified: readDate(c.modified, createdMs == null ? now : createdMs),
    canvas: isObj(c.canvas) ? readCanvas(c.canvas) : readCanvas({}),
    fps: Math.min(60, Math.max(1, int(c.fps, 12))),
    motionBlur: readMotionBlur(c.motionBlur),
    layers: objList(c.layers, readLayer),
    frames: objList(c.frames, readFrame),
    hair: objList(c.hair, readHair),
    movie: readMovie(c.movie),
    media: objList(c.media, readMedia),
  };
  return normalize(p);
}

/** A brand-new project with one layer and one empty frame. */
function newProject({ name = 'Untitled', width = 1920, height = 1080, fps = 12, background = Color.WHITE, id } = {}) {
  const now = formatDate(Date.now());
  return {
    format: FORMAT,
    id: id || makeId(),
    name,
    created: now,
    modified: now,
    canvas: { width: Math.max(16, width), height: Math.max(16, height), background: Color.normalize(background, Color.WHITE) },
    fps: Math.min(60, Math.max(1, Math.round(fps))),
    motionBlur: { on: false, amount: 0.6, samples: 6 },
    layers: [newLayer('Layer 1')],
    frames: [newFrame()],
    hair: [],
    movie: { overlay: false, tracks: [], clips: [] },
    media: [],
  };
}

/** Drops cels with nothing in them (a missing cel is the same as an empty one). Returns a new project. */
function compact(p) {
  return {
    ...p,
    frames: p.frames.map((f) => {
      const cels = {};
      for (const [lid, cel] of Object.entries(f.cels)) {
        if (cel.strokes.length || cel.fills.length) cels[lid] = cel;
      }
      return { ...f, cels };
    }),
  };
}

/** The project as written to project.json: points rounded, empty cels left out. */
function toJSON(p) {
  const out = compact(p);
  out.format = FORMAT;
  out.frames = out.frames.map((f) => {
    const cels = {};
    for (const [lid, cel] of Object.entries(f.cels)) {
      cels[lid] = { strokes: cel.strokes.map((s) => ({ ...s, pts: roundPts(s.pts) })), fills: cel.fills };
    }
    return { ...f, cels };
  });
  return out;
}

function cel(frame, layerId) {
  return (frame && frame.cels[layerId]) || { strokes: [], fills: [] };
}

function totalTicks(p) {
  return p.frames.reduce((n, f) => n + Math.max(1, f.hold), 0);
}

/** A copy with brand-new ids everywhere (for "Duplicate"). */
function withFreshIds(p, name) {
  const layerMap = {};
  const trackMap = {};
  const mediaMap = {};
  const layers = p.layers.map((l) => {
    layerMap[l.id] = makeId();
    return { ...l, id: layerMap[l.id] };
  });
  const frames = p.frames.map((f) => {
    const cels = {};
    for (const [lid, c] of Object.entries(f.cels)) {
      if (!layerMap[lid]) continue;
      cels[layerMap[lid]] = {
        strokes: c.strokes.map((s) => ({ ...s, id: makeId() })),
        fills: c.fills.map((fl) => ({ ...fl, id: makeId() })),
      };
    }
    return { ...f, id: makeId(), cels };
  });
  const media = p.media.map((m) => {
    mediaMap[m.id] = makeId();
    return { ...m, id: mediaMap[m.id] };
  });
  const tracks = p.movie.tracks.map((t) => {
    trackMap[t.id] = makeId();
    return { ...t, id: trackMap[t.id] };
  });
  const clips = p.movie.clips.map((c) => ({
    ...c,
    id: makeId(),
    track: trackMap[c.track] || c.track,
    media: c.media === 'animation' ? c.media : mediaMap[c.media] || c.media,
  }));
  const now = formatDate(Date.now());
  return {
    ...p,
    id: makeId(),
    name: name == null ? p.name : name,
    created: now,
    modified: now,
    layers,
    frames,
    hair: p.hair.map((h) => ({ ...h, id: makeId(), layer: layerMap[h.layer] || h.layer })),
    movie: { ...p.movie, tracks, clips },
    media,
  };
}

module.exports = {
  FORMAT,
  PT_STRIDE,
  BRUSH_KINDS,
  BRUSH_TITLES,
  makeId,
  readProject,
  readBrush,
  readStroke,
  readFill,
  readLayer,
  readFrame,
  readHair,
  readTrack,
  readClip,
  readMedia,
  readCanvas,
  readMotionBlur,
  normalize,
  newProject,
  newLayer,
  newFrame,
  compact,
  toJSON,
  cel,
  totalTicks,
  withFreshIds,
  packPoints,
  unpackPoints,
  roundPts,
  round2,
  round3,
  point,
  formatDate,
  parseDate,
  isObj,
};
