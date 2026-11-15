'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Model, Stabilizer, StrokeShape, Onion, Playback, Hair } = require('../src/shared');

function wobble(points) {
  // Average distance from the straight line y = 100.
  return points.reduce((s, p) => s + Math.abs(p.y - 100), 0) / points.length;
}

test('stabilizer smooths a shaky line', () => {
  const shaky = [];
  for (let i = 0; i <= 300; i++) {
    const jitter = Math.sin(i * 2.7) * 3 + Math.sin(i * 7.3) * 2 + ((i * 7919) % 13 - 6) * 0.5;
    shaky.push(Model.point(i * 2, 100 + jitter, 0.5));
  }
  const before = wobble(shaky);
  const smooth = Stabilizer.StrokeStabilizer.stabilize(shaky, 0.6);
  const after = wobble(smooth.slice(5, -5));
  assert.ok(smooth.length > 20);
  assert.ok(after < before * 0.3, `wobble ${after.toFixed(3)} vs ${before.toFixed(3)}`);
  // It still ends where the pen lifted.
  const last = smooth[smooth.length - 1];
  assert.ok(Math.abs(last.x - 600) < 0.01);
  // amount 0 draws exactly where you touch.
  const exact = Stabilizer.StrokeStabilizer.stabilize(shaky, 0);
  assert.equal(exact.length, shaky.length);
  assert.equal(exact[10].y, shaky[10].y);
  // Final smoothing keeps both ends.
  const sm = Stabilizer.smooth(shaky, 0.7);
  assert.deepEqual(sm[0], shaky[0]);
  assert.deepEqual(sm[sm.length - 1], shaky[shaky.length - 1]);
  assert.ok(wobble(sm) < before);
});

test('stroke shape widths and alpha match the Swift numbers', () => {
  const pen = { kind: 'pen', color: '#000000FF', size: 10, opacity: 1 };
  const p = Model.point(0, 0, 1);
  assert.equal(StrokeShape.width(p, pen, 0, 1), 10);
  assert.ok(Math.abs(StrokeShape.width(Model.point(0, 0, 0), pen, 0, 1) - 2.8) < 1e-9);
  // Pointy ends.
  assert.ok(Math.abs(StrokeShape.width(p, pen, 0, 30) - 3.5) < 1e-9);
  const pencil = { ...pen, kind: 'pencil' };
  assert.ok(Math.abs(StrokeShape.width(Model.point(0, 0, 1, 0), pencil, 0, 1) - 32) < 1e-9);
  assert.equal(StrokeShape.alpha([p], { ...pen, kind: 'marker', opacity: 0.5 }), 0.4);
  assert.ok(Math.abs(StrokeShape.alpha([], { ...pen, kind: 'airbrush', color: '#00000080' }) - 0.35 * 128 / 255) < 1e-9);
  const line = [Model.point(0, 0, 1), Model.point(30, 0, 1)];
  const outline = StrokeShape.outline(line, { ...pen, kind: 'marker' });
  // densify adds points every 3px: 11 points -> 2*11 sides + 2*7 cap points.
  assert.equal(outline.length, 11 * 2 + 7 * 2);
  assert.equal(StrokeShape.outline([Model.point(5, 5)], pen).length, 16);
  assert.ok(StrokeShape.airbrushDabs(line, { ...pen, size: 20 }).length === 6);
});

test('onion skin ghosts', () => {
  const g = Onion.ghosts(2, 6, { before: 2, after: 1, opacity: 0.5, falloff: 0.6, frosted: true, blur: 3 });
  assert.deepEqual(g.map((x) => x.offset), [-2, -1, 1]);
  assert.equal(g[0].side, 'before');
  assert.ok(Math.abs(g[0].opacity - 0.3) < 1e-9);
  assert.ok(Math.abs(g[0].blur - 4.8) < 1e-9);
  assert.equal(g[2].side, 'after');
  assert.deepEqual(Onion.ghosts(0, 4, { before: 2, after: 1 }).map((x) => x.frameIndex), [1]);
  assert.deepEqual(Onion.ghosts(0, 4, { before: 1, after: 0, wrap: true }).map((x) => x.frameIndex), [3]);
  assert.equal(Onion.ghosts(0, 4, { frosted: false })[0].blur, 0);
  assert.deepEqual(Onion.ghosts(0, 1, {}), []);
});

test('playback timing with holds', () => {
  const frames = [{ hold: 1 }, { hold: 2 }, { hold: 3 }];
  assert.deepEqual(Playback.tickStarts(frames), [0, 1, 3]);
  assert.equal(Playback.totalTicks(frames), 6);
  assert.deepEqual([0, 1, 2, 3, 5, 6, -1].map((t) => Playback.frameIndexAtTick(t, frames)), [0, 1, 1, 2, 2, 0, 2]);
  assert.equal(Playback.tickAtTime(0.25, 12), 3);
  assert.equal(Playback.exportTicks({ frames, fps: 12 }, 1, 2), 24);
});

test('hair sway keeps roots still and moves tips', () => {
  const region = { layer: 'l', polygon: [0, 0, 100, 0, 100, 200, 0, 200], root: [0, 0, 100, 0], stiffness: 0.2, wind: 0, gust: 0, speed: 1, on: true };
  const pts = [Model.point(50, 0), Model.point(50, 190), Model.point(500, 500)];
  const moved = Hair.deform(pts, region, 0.3);
  assert.ok(Math.abs(moved[0].x - 50) < 1e-9);
  assert.ok(Math.abs(moved[1].x - 50) > 1);
  assert.deepEqual(moved[2], pts[2]);
  assert.deepEqual(Hair.deform(pts, { ...region, on: false }, 0.3), pts);
});
