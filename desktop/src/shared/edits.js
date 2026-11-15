'use strict';
// Edits that keep order keys right (same rules as Swift's GaleProject edits).
// Every function returns a new project and leaves the old one alone (unchanged parts are shared).

const OrderKey = require('./orderKey');
const Model = require('./model');

const emptyCel = () => ({ strokes: [], fills: [] });

function replaceAt(list, i, item) {
  const out = list.slice();
  out[i] = item;
  return out;
}

/** Adds a layer above `index` (default: on top). */
function addLayer(p, name, index) {
  const i = Math.min(p.layers.length - 1, index == null ? p.layers.length - 1 : index);
  const lower = i >= 0 ? p.layers[i].key : null;
  const upper = i + 1 < p.layers.length ? p.layers[i + 1].key : null;
  const layer = Model.newLayer(name, OrderKey.between(lower, upper) || OrderKey.FIRST);
  const layers = p.layers.slice();
  layers.splice(i + 1, 0, layer);
  return { project: { ...p, layers }, layer };
}

function deleteLayer(p, layerId) {
  if (p.layers.length <= 1) return p;
  return {
    ...p,
    layers: p.layers.filter((l) => l.id !== layerId),
    frames: p.frames.map((f) => {
      if (!f.cels[layerId]) return f;
      const cels = { ...f.cels };
      delete cels[layerId];
      return { ...f, cels };
    }),
  };
}

function updateLayer(p, layerId, patch) {
  const i = p.layers.findIndex((l) => l.id === layerId);
  if (i < 0) return p;
  return { ...p, layers: replaceAt(p.layers, i, { ...p.layers[i], ...patch }) };
}

function moveItem(list, from, to) {
  if (from < 0 || from >= list.length || to < 0 || to >= list.length || from === to) return null;
  const out = list.slice();
  const [item] = out.splice(from, 1);
  const lower = to > 0 ? out[to - 1].key : null;
  const upper = to < out.length ? out[to].key : null;
  out.splice(to, 0, { ...item, key: OrderKey.between(lower, upper) || item.key });
  return out;
}

function moveLayer(p, from, to) {
  const layers = moveItem(p.layers, from, to);
  return layers ? { ...p, layers } : p;
}

function moveFrame(p, from, to) {
  const frames = moveItem(p.frames, from, to);
  return frames ? { ...p, frames } : p;
}

/** Inserts a frame after `index` (null = at the end). Returns the new project and where it went. */
function insertFrame(p, frame, index) {
  const i = Math.min(p.frames.length - 1, index == null ? p.frames.length - 1 : index);
  const lower = i >= 0 ? p.frames[i].key : null;
  const upper = i + 1 < p.frames.length ? p.frames[i + 1].key : null;
  const f = { ...frame, key: OrderKey.between(lower, upper) || OrderKey.FIRST };
  const frames = p.frames.slice();
  frames.splice(i + 1, 0, f);
  return { project: { ...p, frames }, index: i + 1 };
}

/** A copy of frame `index` right after it, with fresh ids for everything in it. */
function duplicateFrame(p, index) {
  const src = p.frames[index];
  if (!src) return { project: p, index };
  const cels = {};
  for (const [lid, c] of Object.entries(src.cels)) {
    cels[lid] = {
      strokes: c.strokes.map((s) => ({ ...s, id: Model.makeId() })),
      fills: c.fills.map((f) => ({ ...f, id: Model.makeId() })),
    };
  }
  return insertFrame(p, { id: Model.makeId(), key: OrderKey.FIRST, hold: src.hold, cels }, index);
}

/** Deletes a frame. The last frame can't go, so it gets cleared instead. */
function deleteFrame(p, index) {
  if (index < 0 || index >= p.frames.length) return p;
  if (p.frames.length <= 1) return { ...p, frames: [{ ...p.frames[0], cels: {} }] };
  return { ...p, frames: p.frames.filter((_, i) => i !== index) };
}

function setHold(p, index, hold) {
  const f = p.frames[index];
  if (!f) return p;
  const h = Math.max(1, Math.min(99, Math.round(hold)));
  return { ...p, frames: replaceAt(p.frames, index, { ...f, hold: h }) };
}

/** Changes one cel (frame id + layer id) with `change(cel) -> cel`. */
function updateCel(p, frameId, layerId, change) {
  const i = p.frames.findIndex((f) => f.id === frameId);
  if (i < 0) return p;
  const f = p.frames[i];
  const cel = change(f.cels[layerId] || emptyCel());
  return { ...p, frames: replaceAt(p.frames, i, { ...f, cels: { ...f.cels, [layerId]: cel } }) };
}

/** Adds a stroke on top of a cel and gives it the right key. */
function addStroke(p, frameId, layerId, stroke) {
  return updateCel(p, frameId, layerId, (cel) => {
    const last = cel.strokes.length ? cel.strokes[cel.strokes.length - 1].key : null;
    const s = { ...stroke, key: OrderKey.between(last, null) || OrderKey.FIRST };
    return { strokes: [...cel.strokes, s], fills: cel.fills };
  });
}

/** Removes everything from one cel. */
function clearCel(p, frameId, layerId) {
  return updateCel(p, frameId, layerId, () => emptyCel());
}

function setProject(p, patch) {
  return { ...p, ...patch };
}

module.exports = {
  addLayer, deleteLayer, updateLayer, moveLayer, moveFrame, insertFrame, duplicateFrame, deleteFrame, setHold,
  updateCel, addStroke, clearCel, setProject,
};
