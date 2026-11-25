'use strict';
// A project as a flat table of objects (spec section 4), and the diff that turns edits into one op per changed field.
//
// objects = { [objectId]: { $type, ...fields } }. Deleting sets `$del: true`.

const Model = require('./model');
const Pixel = require('./pixel');

const FIELDS = {
  project: ['name', 'width', 'height', 'background', 'fps', 'motionBlur', 'overlay', 'created', 'pixel'],
  layer: ['key', 'name', 'visible', 'locked', 'opacity'],
  frame: ['key', 'hold'],
  stroke: ['frame', 'layer', 'key', 'brush', 'pts'],
  fill: ['frame', 'layer', 'key', 'color', 'path'],
  hair: ['layer', 'polygon', 'root', 'stiffness', 'wind', 'gust', 'speed', 'on'],
  track: ['key', 'kind', 'name', 'muted', 'volume'],
  clip: ['track', 'media', 'start', 'in', 'duration', 'speed', 'volume', 'fadeIn', 'fadeOut'],
  media: ['file', 'kind', 'name', 'duration', 'sha256'],
  // Pixel storytime: settings ride on the project's `pixel` field; each scene and frame is its own object,
  // so drawing on one frame only sends that frame.
  pxscene: ['key', 'name', 'fps', 'loops', 'background', 'caption', 'bubbles', 'transition'],
  pxframe: ['scene', 'key', 'hold', 'runs'],
};

/** Packed runs for a frame's cells. Cells are never changed in place, so the packing is kept per array. */
const runsCache = new WeakMap();
function runsFor(cells) {
  let r = runsCache.get(cells);
  if (!r) {
    r = Pixel.encodeRuns(cells);
    runsCache.set(cells, r);
  }
  return r;
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
    return true;
  }
  if (Array.isArray(b)) return false;
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (const k of ka) {
    if (!Object.prototype.hasOwnProperty.call(b, k) || !deepEqual(a[k], b[k])) return false;
  }
  return true;
}

function pick(type, src, extra) {
  const o = { $type: type };
  for (const f of FIELDS[type]) if (src[f] !== undefined) o[f] = src[f];
  return Object.assign(o, extra);
}

/** Flattens a project into objects (values are shared with the project, not copied). */
function toObjects(project) {
  const p = project;
  const out = {};
  out[p.id] = {
    $type: 'project',
    name: p.name,
    width: p.canvas.width,
    height: p.canvas.height,
    background: p.canvas.background,
    fps: p.fps,
    motionBlur: p.motionBlur,
    overlay: p.movie.overlay,
    created: p.created,
  };
  for (const l of p.layers) out[l.id] = pick('layer', l);
  for (const f of p.frames) {
    out[f.id] = pick('frame', f);
    for (const [lid, cel] of Object.entries(f.cels)) {
      for (const s of cel.strokes) {
        out[s.id] = { $type: 'stroke', frame: f.id, layer: lid, key: s.key, brush: s.brush, pts: s.pts };
      }
      for (const fl of cel.fills) {
        out[fl.id] = { $type: 'fill', frame: f.id, layer: lid, key: fl.key, color: fl.color, path: fl.path };
      }
    }
  }
  for (const h of p.hair) out[h.id] = pick('hair', h);
  for (const t of p.movie.tracks) out[t.id] = pick('track', t);
  for (const c of p.movie.clips) out[c.id] = pick('clip', c);
  for (const m of p.media) out[m.id] = pick('media', m);
  if (p.pixel) {
    const st = p.pixel;
    out[p.id].pixel = { width: st.width, height: st.height, palette: st.palette, paletteName: st.paletteName, paper: st.paper };
    for (const sc of st.scenes) {
      out[sc.id] = pick('pxscene', sc);
      for (const f of sc.frames) out[f.id] = { $type: 'pxframe', scene: sc.id, key: f.key, hold: f.hold, runs: runsFor(f.cells) };
    }
  }
  return out;
}

const alive = (o) => o && o.$del !== true;

/**
 * Changes that turn `oldObjects` into `newObjects`: [{ o, k, v }].
 * New objects send every field (including $type), changed fields send one change each,
 * objects that are gone get `$del: true`. A deleted object that comes back gets `$del: false`.
 * Fields the new side doesn't know about are left alone.
 */
function diff(oldObjects, newObjects) {
  const changes = [];
  for (const id of Object.keys(newObjects)) {
    const n = newObjects[id];
    const o = oldObjects[id];
    if (!o || !alive(o)) {
      for (const k of Object.keys(n)) {
        if (k === '$del') continue;
        if (o && deepEqual(o[k], n[k])) continue;
        changes.push({ o: id, k, v: n[k] });
      }
      if (o) changes.push({ o: id, k: '$del', v: false });
      continue;
    }
    for (const k of Object.keys(n)) {
      if (k === '$del') continue;
      if (!deepEqual(o[k], n[k])) changes.push({ o: id, k, v: n[k] });
    }
  }
  for (const id of Object.keys(oldObjects)) {
    if (!(id in newObjects) && alive(oldObjects[id])) changes.push({ o: id, k: '$del', v: true });
  }
  return changes;
}

const byId = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/**
 * Builds a project from objects. Strokes and fills whose frame or layer is gone (or deleted) are ignored.
 * Everything goes through the forgiving reader, so wrong-type values get defaults.
 */
function fromObjects(objects, projectId, opts = {}) {
  const proj = objects[projectId] && objects[projectId].$type === 'project' ? objects[projectId] : {};
  const layers = [];
  const frames = {};
  const frameList = [];
  const hair = [];
  const tracks = [];
  const clips = [];
  const media = [];
  const strokes = [];
  const fills = [];
  const pxScenes = {};
  const pxFrames = [];
  for (const id of Object.keys(objects)) {
    const o = objects[id];
    if (!alive(o)) continue;
    switch (o.$type) {
      case 'layer': layers.push({ ...o, id }); break;
      case 'frame': {
        const f = { ...o, id, cels: {} };
        frames[id] = f;
        frameList.push(f);
        break;
      }
      case 'stroke': strokes.push([id, o]); break;
      case 'fill': fills.push([id, o]); break;
      case 'hair': hair.push({ ...o, id }); break;
      case 'track': tracks.push({ ...o, id }); break;
      case 'clip': clips.push({ ...o, id }); break;
      case 'media': media.push({ ...o, id }); break;
      case 'pxscene': pxScenes[id] = { ...o, id, frames: [] }; break;
      case 'pxframe': pxFrames.push({ ...o, id }); break;
      default: break;
    }
  }
  const layerIds = new Set(layers.map((l) => l.id));
  const celFor = (o) => {
    if (typeof o.frame !== 'string' || typeof o.layer !== 'string') return null;
    const f = frames[o.frame];
    if (!f || !layerIds.has(o.layer)) return null;
    if (!f.cels[o.layer]) f.cels[o.layer] = { strokes: [], fills: [] };
    return f.cels[o.layer];
  };
  for (const [id, o] of strokes) {
    const c = celFor(o);
    if (c) c.strokes.push({ id, key: o.key, brush: o.brush, pts: o.pts });
  }
  for (const [id, o] of fills) {
    const c = celFor(o);
    if (c) c.fills.push({ id, key: o.key, color: o.color, path: o.path });
  }
  for (const f of frameList) {
    delete f.$type;
    delete f.$del;
    delete f.frame;
  }
  const strip = (x) => {
    delete x.$type;
    delete x.$del;
    return x;
  };
  let pixel;
  if (proj.pixel !== null && typeof proj.pixel === 'object' && !Array.isArray(proj.pixel)) {
    for (const f of pxFrames) {
      const sc = typeof f.scene === 'string' ? pxScenes[f.scene] : null;
      if (sc) sc.frames.push(strip({ id: f.id, key: f.key, hold: f.hold, runs: f.runs }));
    }
    pixel = { ...proj.pixel, scenes: Object.values(pxScenes).map(strip) };
  }
  const json = {
    format: Model.FORMAT,
    id: projectId,
    name: proj.name,
    created: proj.created,
    modified: opts.modified != null ? opts.modified : proj.created,
    canvas: { width: proj.width, height: proj.height, background: proj.background },
    fps: proj.fps,
    motionBlur: proj.motionBlur,
    layers: layers.map(strip),
    frames: frameList,
    hair: hair.map(strip).sort(byId),
    movie: { overlay: proj.overlay, tracks: tracks.map(strip), clips: clips.map(strip).sort(byId) },
    media: media.map(strip).sort(byId),
    pixel,
  };
  const p = Model.readProject(json);
  if (p.pixel) {
    // Stand-ins for a story whose scenes or frames haven't arrived yet, so building twice gives the same ids.
    if (Object.keys(pxScenes).length === 0) p.pixel.scenes[0].id = `${projectId}-pxscene`;
    for (const sc of p.pixel.scenes) {
      if (!pxScenes[sc.id] || pxScenes[sc.id].frames.length === 0) sc.frames[0].id = `${sc.id}-pxframe`;
    }
  }
  // A project with no layers or frames yet gets stable stand-ins, so building twice gives the same ids.
  if (layers.length === 0) p.layers[0].id = `${projectId}-layer`;
  if (frameList.length === 0) p.frames[0].id = `${projectId}-frame`;
  return p;
}

/** Whether objects hold a project that was deleted. */
function isDeleted(objects, projectId) {
  const o = objects[projectId];
  return !!(o && o.$del === true);
}

module.exports = { FIELDS, toObjects, fromObjects, diff, deepEqual, isDeleted };
