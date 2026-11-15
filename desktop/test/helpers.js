'use strict';
// Test helpers: build real projects the way the editor does (no sample files).
const { Model, Edits } = require('../src/shared');

/** A stroke along a line, with pressure going up and down. */
function lineStroke(x0, y0, x1, y1, brush = {}, n = 12) {
  const pts = [];
  for (let i = 0; i < n; i++) {
    const t = i / (n - 1);
    pts.push(Model.point(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, 0.3 + 0.6 * Math.sin(Math.PI * t), 1.2, 0.4, t * 0.5));
  }
  return { id: Model.makeId(), key: 'a0', brush: Model.readBrush({ kind: 'pen', color: '#112233FF', size: 6, opacity: 1, ...brush }), pts: Model.packPoints(pts) };
}

/** A project with two layers, three frames, strokes, a fill, hair, a track, a clip and media. */
function buildProject() {
  let p = Model.newProject({ name: 'Round trip', width: 800, height: 600, fps: 8 });
  const l1 = p.layers[0].id;
  const added = Edits.addLayer(p, 'Ink');
  p = added.project;
  const l2 = added.layer.id;
  p = Edits.addStroke(p, p.frames[0].id, l1, lineStroke(10, 10, 200, 120));
  p = Edits.addStroke(p, p.frames[0].id, l2, lineStroke(50, 300, 400, 310, { kind: 'pencil', color: '#FF8800CC' }));
  p = Edits.updateCel(p, p.frames[0].id, l1, (cel) => ({
    strokes: cel.strokes,
    fills: [{ id: Model.makeId(), key: 'a0', color: '#33AA55FF', path: [0, 0, 100, 0, 100, 100, 0, 100] }],
  }));
  p = Edits.duplicateFrame(p, 0).project;
  p = Edits.insertFrame(p, Model.newFrame(), 1).project;
  p = Edits.setHold(p, 2, 3);
  p = Edits.addStroke(p, p.frames[1].id, l2, lineStroke(5, 5, 6, 300, { kind: 'airbrush', size: 30 }));
  p = {
    ...p,
    hair: [{ id: Model.makeId(), layer: l2, polygon: [0, 0, 100, 0, 100, 200, 0, 200], root: [0, 0, 100, 0], stiffness: 0.4, wind: 0.2, gust: 0.3, speed: 0.8, on: true }],
    media: [{ id: Model.makeId(), file: 'abc.m4a', kind: 'audio', name: 'Song', duration: 12.5, sha256: 'ab'.repeat(32) }],
  };
  const trackId = Model.makeId();
  p.movie = {
    overlay: true,
    tracks: [{ id: trackId, key: 'a0', kind: 'audio', name: 'Music', muted: false, volume: 1 }],
    clips: [{ id: Model.makeId(), track: trackId, media: p.media[0].id, start: 0, in: 1, duration: 10, speed: 1, volume: 0.8, fadeIn: 0.5, fadeOut: 0 }],
  };
  return Model.readProject(JSON.parse(JSON.stringify(Model.toJSON(p))));
}

/** Same project in a form that compares well: no empty cels, id-sorted lists. */
function canonical(p) {
  const c = JSON.parse(JSON.stringify(Model.toJSON(p)));
  const byId = (a, b) => (a.id < b.id ? -1 : 1);
  c.hair.sort(byId);
  c.media.sort(byId);
  c.movie.clips.sort(byId);
  for (const f of c.frames) {
    const cels = {};
    for (const k of Object.keys(f.cels).sort()) cels[k] = f.cels[k];
    f.cels = cels;
  }
  return c;
}

function shuffle(list, seed = 1) {
  const a = list.slice();
  let s = seed;
  const rnd = () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s / 0x7fffffff;
  };
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

module.exports = { lineStroke, buildProject, canonical, shuffle };
