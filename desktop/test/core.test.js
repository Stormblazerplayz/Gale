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
  const smooth = Stabilizer.finish(shaky, 0.6);
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

test('smoothing keeps eyes, short strokes and corners the way you drew them', () => {
  const D = Stabilizer.DEFAULT_AMOUNT;
  assert.ok(D > 0 && D <= 0.3, 'default smoothing is light');
  // A small eye stays round and closes where the pen lifted.
  for (const r of [5, 8, 12]) {
    const n = r * 4;
    const raw = [];
    for (let i = 0; i <= n; i++) {
      const a = (i / n) * 2 * Math.PI;
      raw.push(Model.point(200 + Math.cos(a) * r, 200 + Math.sin(a) * r, 0.5));
    }
    const out = Stabilizer.finish(raw, D);
    const worst = Math.max(...out.map((p) => Math.abs(Math.hypot(p.x - 200, p.y - 200) - r)));
    assert.ok(worst < Math.max(0.5, r * 0.06), `a ${r}px eye came out ${worst.toFixed(2)}px off`);
    assert.ok(Math.abs(out[out.length - 1].x - raw[raw.length - 1].x) < 1e-6);
  }
  // A right-angle corner stays sharp.
  const corner = [];
  for (let x = 100; x < 140; x += 1.5) corner.push(Model.point(x, 100, 0.5));
  for (let y = 100; y <= 140; y += 1.5) corner.push(Model.point(140, y, 0.5));
  const c = Stabilizer.finish(corner, D);
  const miss = Math.min(...c.map((p) => Math.hypot(p.x - 140, p.y - 100)));
  assert.ok(miss < 0.6, `the corner was cut by ${miss.toFixed(2)}px`);
  // A short stroke keeps its length.
  const short = [];
  for (let x = 0; x <= 8; x++) short.push(Model.point(100 + x, 100, 0.5));
  const so = Stabilizer.finish(short, D);
  let len = 0;
  for (let i = 1; i < so.length; i++) len += Math.hypot(so[i].x - so[i - 1].x, so[i].y - so[i - 1].y);
  assert.ok(Math.abs(len - 8) < 0.3, `an 8px stroke came out ${len.toFixed(2)} long`);
  // Hand shake on a straight line is not a corner.
  const shake = [];
  for (let i = 0; i <= 200; i++) shake.push(Model.point(i * 2 + Math.sin(i * 2.7) * 1.2, 100 + Math.sin(i * 7.3) * 1.2, 0.5));
  const even = Stabilizer.resample(shake, 1);
  assert.equal(Stabilizer.corners(even, Stabilizer.CORNER_ARM, Stabilizer.CORNER_ANGLE, 1).length, 0);
  // Off draws exactly, and the label says so.
  const off = Stabilizer.finish(corner, 0);
  assert.equal(off.length, corner.length);
  assert.equal(off[5].x, corner[5].x);
  assert.equal(Stabilizer.label(0), 'Off');
  assert.equal(Stabilizer.label(0.25), '25%');
  // The string starts short, so a short stroke isn't held back even at full strength.
  const st = new Stabilizer.StrokeStabilizer(1);
  st.begin(Model.point(0, 0));
  assert.equal(st.stringLength, 0);
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

test('face mode turns smoothing off for details and keeps the slider amount', () => {
  assert.equal(Stabilizer.drawAmount(0.8, true), 0);
  assert.equal(Stabilizer.drawAmount(0.8, false), 0.8);
  assert.equal(Stabilizer.drawAmount(2, false), 1);
  assert.equal(Stabilizer.label(0.8, true), 'Face');
  assert.equal(Stabilizer.label(0.8), '80%');
  assert.equal(Stabilizer.label(0), 'Off');
  // A wobbly little eye with the slider all the way up still draws exactly where you touched.
  const raw = [];
  for (let i = 0; i <= 30; i++) {
    const a = (i / 30) * 2 * Math.PI;
    const wob = Math.sin(i * 7.3) * 0.8;
    raw.push(Model.point(200 + Math.cos(a) * (6 + wob), 200 + Math.sin(a) * (6 + wob), 0.5));
  }
  const out = Stabilizer.finish(raw, Stabilizer.drawAmount(1, true));
  const near = (list, p) => Math.min(...list.map((q) => Math.hypot(q.x - p.x, q.y - p.y)));
  for (const p of out) assert.ok(near(raw, p) < 1e-4, 'face mode moved a point');
  for (const p of raw) assert.ok(near(out, p) < 0.36, 'face mode dropped a touch');
  // The same slider without face mode does change the line.
  const smoothed = Stabilizer.finish(raw, Stabilizer.drawAmount(1, false));
  assert.ok(Math.max(...smoothed.map((p) => near(raw, p))) > 0.05, 'full smoothing should move the wobbly eye');
});
