'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Model, Color } = require('../src/shared');

test('color hex reading and writing', () => {
  assert.deepEqual(Color.parse('#FF8800FF'), { r: 1, g: 136 / 255, b: 0, a: 1 });
  assert.equal(Color.normalize('#f80'), '#FF8800FF');
  assert.equal(Color.normalize('ff8800'), '#FF8800FF');
  assert.equal(Color.normalize('#11223344'), '#11223344');
  assert.equal(Color.normalize('nope', '#000000FF'), '#000000FF');
  assert.equal(Color.parse('#12345'), null);
  assert.equal(Color.toHex({ r: 1, g: 0.5, b: 0, a: 0.5 }), '#FF800080');
  assert.equal(Color.toHex({ r: 2, g: -1, b: 0, a: 1 }), '#FF0000FF');
  assert.equal(Color.toCss('#FF000080', 0.5), 'rgba(255,0,0,0.251)');
});

test('model fills in defaults like the Swift decoders', () => {
  const p = Model.readProject({});
  assert.equal(p.format, 'gale/1');
  assert.equal(p.name, 'Untitled');
  assert.equal(p.fps, 12);
  assert.deepEqual(p.canvas, { width: 1920, height: 1080, background: '#FFFFFFFF' });
  assert.deepEqual(p.motionBlur, { on: false, amount: 0.6, samples: 6 });
  assert.equal(p.layers.length, 1);
  assert.equal(p.layers[0].name, 'Layer 1');
  assert.equal(p.frames.length, 1);
  assert.equal(p.frames[0].hold, 1);
  assert.deepEqual(p.hair, []);
  assert.deepEqual(p.movie, { overlay: false, tracks: [], clips: [] });
  assert.equal(p.modified, p.created);
});

test('model is forgiving about odd values', () => {
  const p = Model.readProject({
    id: 'p1', name: 7, fps: 500, created: 1763229600000,
    canvas: { width: 3, height: 'x', background: 'blue' },
    layers: [{ id: 'l2', key: 'a1' }, { id: 'l1', key: 'a0', visible: 'yes', opacity: 0.5 }],
    frames: [{ id: 'f1', hold: 0, cels: { l1: { strokes: [{ id: 's1', brush: { kind: 'laser', size: 'big' }, pts: [1, 2, 0.5, 1.5, 0, 0, 9] }] } } }],
    hair: [{ id: 'h1' }],
    movie: { tracks: [{ id: 't1', kind: 'midi' }], clips: [{ id: 'c1', in: 2 }] },
    media: [{ id: 'm1', kind: 'gif' }],
    extra: { ignored: true },
  });
  assert.equal(p.name, 'Untitled');
  assert.equal(p.fps, 60);
  assert.equal(p.created, '2025-11-15T18:00:00Z');
  assert.deepEqual(p.canvas, { width: 16, height: 1080, background: '#FFFFFFFF' });
  assert.deepEqual(p.layers.map((l) => l.id), ['l1', 'l2']);
  assert.equal(p.layers[0].visible, true);
  assert.equal(p.layers[0].opacity, 0.5);
  assert.equal(p.layers[1].name, 'Layer');
  assert.equal(p.frames[0].hold, 1);
  const s = p.frames[0].cels.l1.strokes[0];
  assert.equal(s.brush.kind, 'pen');
  assert.equal(s.brush.size, 8);
  assert.equal(s.brush.color, '#000000FF');
  assert.equal(s.key, 'a0');
  assert.deepEqual(s.pts, [1, 2, 0.5, 1.5, 0, 0]);
  assert.deepEqual(p.hair[0].root, [0, 0, 0, 0]);
  assert.equal(p.hair[0].speed, 0.8);
  assert.equal(p.movie.tracks[0].kind, 'audio');
  assert.equal(p.movie.clips[0].in, 2);
  assert.equal(p.movie.clips[0].speed, 1);
  assert.equal(p.media[0].kind, 'video');
  assert.equal(Model.readProject({ fps: 0 }).fps, 1);
  assert.equal(Model.readProject({ fps: 12.5 }).fps, 12);
  // One bad element makes the whole list fall back, like Swift.
  assert.equal(Model.readProject({ layers: [{ id: 'a' }, 5] }).layers[0].name, 'Layer 1');
});

test('points pack with the file rounding', () => {
  const pts = Model.packPoints([Model.point(1.23456, -2.345, 0.12345, 1.5707963, 0.0004, 0.0125)]);
  assert.deepEqual(pts, [1.23, -2.35, 0.123, 1.571, 0, 0.013]);
  assert.deepEqual(Model.unpackPoints(pts)[0], { x: 1.23, y: -2.35, pressure: 0.123, altitude: 1.571, azimuth: 0, time: 0.013 });
});

test('dates read in every allowed form', () => {
  assert.equal(Model.formatDate(Model.parseDate('2026-11-15T18:00:00Z')), '2026-11-15T18:00:00Z');
  assert.equal(Model.formatDate(Model.parseDate('2026-11-15T18:00:00.250Z')), '2026-11-15T18:00:00Z');
  assert.equal(Model.formatDate(Model.parseDate(1763229600000)), '2025-11-15T18:00:00Z');
  assert.equal(Model.formatDate(Model.parseDate(1763229600)), '2025-11-15T18:00:00Z');
  assert.equal(Model.parseDate('yesterday'), null);
});

test('ids are 22 lowercase letters and digits', () => {
  const ids = new Set();
  for (let i = 0; i < 200; i++) {
    const id = Model.makeId();
    assert.match(id, /^[a-z0-9]{22}$/);
    ids.add(id);
  }
  assert.equal(ids.size, 200);
});
