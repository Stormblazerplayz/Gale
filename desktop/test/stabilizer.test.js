'use strict';
// Adaptive smoothing ("Keep corners sharp") and the stabilizer test. Same lines and numbers as the
// iPad app's AdaptiveStabilizerTests.swift, so both apps are checked the same way.
const test = require('node:test');
const assert = require('node:assert/strict');
const { Stabilizer, Calibration } = require('../src/shared');

/** The same repeatable random numbers as the Swift tests (SeededRandom.signed). */
function seeded(seed) {
  let s = BigInt(seed);
  return () => {
    s = (s * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n);
    return (Number(s >> 11n) / 2 ** 53) * 2 - 1;
  };
}

/** A shape drawn through `corners` with a shaky hand, sampled like a touch screen. */
function shakyPolyline(corners, seed, wob = 1.2) {
  const r = seeded(seed);
  const pts = [];
  let t = 0;
  const step = 2.5, speed = 150;
  for (let c = 0; c < corners.length - 1; c++) {
    const a = corners[c], b = corners[c + 1];
    const n = Math.max(2, Math.round(Math.hypot(b[0] - a[0], b[1] - a[1]) / step));
    for (let k = 0; k < n; k++) {
      const f = k / n;
      pts.push({ x: a[0] + (b[0] - a[0]) * f + r() * wob, y: a[1] + (b[1] - a[1]) * f + r() * wob, pressure: 0.5, time: t });
      t += step / speed;
    }
  }
  const e = corners[corners.length - 1];
  pts.push({ x: e[0], y: e[1], pressure: 0.5, time: t });
  return pts;
}

/** How far the line misses its worst corner (the ends don't count). */
function worstCut(out, corners) {
  return Math.max(...corners.slice(1, -1).map((c) => Math.min(...out.map((p) => Math.hypot(p.x - c[0], p.y - c[1])))));
}

/** A path drawn with a hand tremor (slow drift plus jitter). */
function trembling(path, seed, jitter, drift, samples = 300) {
  const r = seeded(seed);
  let dx = 0, dy = 0;
  const out = [];
  for (let i = 0; i <= samples; i++) {
    const t = i / samples;
    dx += (r() * drift - dx) * 0.2;
    dy += (r() * drift - dy) * 0.2;
    const p = path(t);
    out.push({ x: p.x + dx + r() * jitter, y: p.y + dy + r() * jitter, pressure: 0.5, time: i / 120 });
  }
  return out;
}

/** Average turn (degrees) between steps 4 pixels apart: lower is smoother. */
function roughness(pts) {
  const e = Stabilizer.resample(pts, 4);
  let s = 0, c = 0;
  for (let i = 1; i < e.length - 1; i++) {
    const ax = e[i].x - e[i - 1].x, ay = e[i].y - e[i - 1].y;
    const bx = e[i + 1].x - e[i].x, by = e[i + 1].y - e[i].y;
    const la = Math.hypot(ax, ay), lb = Math.hypot(bx, by);
    if (la < 1 || lb < 1) continue;
    s += (Math.acos(Math.max(-1, Math.min(1, (ax * bx + ay * by) / la / lb))) * 180) / Math.PI;
    c++;
  }
  return s / Math.max(1, c);
}

function run(raw, amount, adaptive = true) {
  const s = new Stabilizer.StrokeStabilizer(amount, 1, adaptive);
  const drawn = [...s.begin(raw[0])];
  for (const p of raw.slice(1)) drawn.push(...s.add(p));
  drawn.push(...s.end());
  return { s, drawn };
}

const zigzag = [[100, 300], [160, 220], [220, 300], [280, 220], [340, 300], [400, 220]];
const square = [[100, 100], [300, 100], [300, 300], [100, 300], [100, 120]];
const triangle = [[100, 300], [200, 120], [300, 300], [100, 300]];
const star = [];
for (let i = 0; i <= 10; i++) {
  const a = -Math.PI / 2 + (i * Math.PI) / 5;
  const r = i % 2 === 0 ? 150 : 60;
  star.push([300 + r * Math.cos(a), 300 + r * Math.sin(a)]);
}
const circle = (t) => ({ x: 300 + 120 * Math.cos(t * 2 * Math.PI), y: 300 + 120 * Math.sin(t * 2 * Math.PI) });
const wave = (t) => ({ x: 100 + 400 * t, y: 300 + 60 * Math.sin(t * 3 * Math.PI) });

test('corners stay sharp even with strong smoothing', () => {
  for (const [name, shape] of [['zigzag', zigzag], ['square', square], ['triangle', triangle]]) {
    for (const amount of [0.5, 0.75, 1]) {
      for (const seed of [1, 2, 3, 4, 5]) {
        const cut = worstCut(Stabilizer.finish(shakyPolyline(shape, seed), amount), shape);
        assert.ok(cut < 4.5, `${name} at ${amount}, seed ${seed}: corner cut by ${cut.toFixed(2)}`);
      }
    }
  }
});

test('stars keep their points', () => {
  for (const amount of [0.5, 0.75, 0.85, 1]) {
    let off = 0, on = 0;
    for (const seed of [1, 2, 3, 4, 5]) {
      const raw = shakyPolyline(star, seed);
      off = Math.max(off, worstCut(Stabilizer.finish(raw, amount, 1, false), star));
      on = Math.max(on, worstCut(Stabilizer.finish(raw, amount), star));
    }
    assert.ok(on < 7.5 && on < off, `star at ${amount}: ${on.toFixed(2)} vs off ${off.toFixed(2)}`);
  }
});

test('keep corners sharp beats the old way', () => {
  let off = 0, on = 0;
  for (const seed of [1, 2, 3, 4, 5]) {
    const raw = shakyPolyline(square, seed);
    off = Math.max(off, worstCut(Stabilizer.finish(raw, 1, 1, false), square));
    on = Math.max(on, worstCut(Stabilizer.finish(raw, 1), square));
  }
  assert.ok(off > 8, `the old way should round corners off (${off.toFixed(2)})`);
  assert.ok(on < off / 2.5, `adaptive ${on.toFixed(2)} vs old ${off.toFixed(2)}`);
});

test('the brush snaps to each corner while drawing', () => {
  const { s } = run(shakyPolyline(square, 1), 1);
  assert.equal(s.corners, 3);
  assert.ok(worstCut(s.points, square) < 4);
});

test('shaky curves never get fake corners', () => {
  for (const [name, path] of [['circle', circle], ['wave', wave]]) {
    for (const seed of [1, 2, 3, 4, 5, 6]) {
      for (const amount of [0.6, 0.85, 1]) {
        const { s } = run(trembling(path, seed, 0.8, 1.6), amount);
        assert.equal(s.corners, 0, `${name} seed ${seed} at ${amount} snapped to a corner that isn't there`);
      }
    }
  }
});

test('a pause lets the brush catch up', () => {
  const s = new Stabilizer.StrokeStabilizer(1);
  s.begin({ x: 0, y: 0, pressure: 0.5, time: 0 });
  let t = 0;
  for (let i = 1; i <= 100; i++) s.add({ x: i * 2, y: 0, pressure: 0.5, time: (t += 1 / 120) });
  for (let i = 0; i < 30; i++) s.add({ x: 200, y: 0, pressure: 0.5, time: (t += 1 / 120) });
  for (let i = 1; i <= 60; i++) s.add({ x: 200, y: i * 2, pressure: 0.5, time: (t += 1 / 120) });
  s.end();
  const miss = Math.min(...s.points.map((p) => Math.hypot(p.x - 200, p.y)));
  assert.ok(miss < 1, `missed where the pen stopped by ${miss.toFixed(2)}`);
});

test('off behaves like the old stabilizer, and pieces add up when nothing snaps', () => {
  const off = run(shakyPolyline(zigzag, 3), 1, false);
  assert.equal(off.s.corners, 0);
  assert.deepEqual(off.drawn, off.s.points);
  const light = run(shakyPolyline(zigzag, 2), Stabilizer.DEFAULT_AMOUNT);
  assert.deepEqual(light.drawn, light.s.points);
});

test('default smoothing rounds wobbles at least as well with corners kept sharp', () => {
  let on = 0, off = 0;
  for (const seed of [1, 2, 3, 4, 5, 6]) {
    const raw = trembling(wave, seed, 0.6, 1);
    on += roughness(Stabilizer.finish(raw, Stabilizer.DEFAULT_AMOUNT));
    off += roughness(Stabilizer.finish(raw, Stabilizer.DEFAULT_AMOUNT, 1, false));
  }
  assert.ok(on <= off * 1.02, `adaptive ${(on / 6).toFixed(2)} vs ${(off / 6).toFixed(2)}`);
});

test('long steady lines get extra smoothing, short lines and bends get less', () => {
  const straight = Stabilizer.resample(trembling((t) => ({ x: 100 + 400 * t, y: 300 }), 4, 0.6, 1), 1);
  const fs = Stabilizer.adaptiveFactors(straight, 6, 60, 1, 400, 1);
  assert.ok(fs[Math.floor(straight.length / 2)] > 1.4);
  const short = straight.slice(0, 30);
  assert.ok(Stabilizer.adaptiveFactors(short, 6, 60, 1, 29, 1).every((f) => f <= 1.0001));
  const bend = [];
  for (let i = 0; i <= 100; i++) bend.push({ x: i, y: 0, pressure: 0.5 });
  for (let i = 1; i <= 100; i++) bend.push({ x: 100 + i * Math.cos(Math.PI / 4), y: i * Math.sin(Math.PI / 4), pressure: 0.5 });
  const even = Stabilizer.resample(bend, 1);
  const f = Stabilizer.adaptiveFactors(even, 6, 60, 1, 200, 1);
  let at = 0;
  for (let i = 0; i < even.length; i++) if (Math.hypot(even[i].x - 100, even[i].y) < Math.hypot(even[at].x - 100, even[at].y)) at = i;
  assert.ok(f[at] < 0.9, `the bend got ${f[at].toFixed(2)} of normal smoothing`);
});

/** A guide traced in a 300 point tall box with a hand that drifts and jitters. */
function traced(guide, seed, jitter, drift, scale = 1) {
  const even = Stabilizer.resample(guide.points.map((p) => ({ x: p.x * 300, y: p.y * 300, pressure: 0.5 })), 2.5);
  const r = seeded(seed);
  let dx = 0, dy = 0;
  return even.map((p, i) => {
    dx += (r() * drift - dx) * 0.2;
    dy += (r() * drift - dy) * 0.2;
    return { x: (p.x + dx + r() * jitter) * scale, y: (p.y + dy + r() * jitter) * scale, pressure: 0.5, time: i / 120 };
  });
}

test('stabilizer test: four guides that fit their box', () => {
  assert.deepEqual(Calibration.GUIDES.map((g) => g.id), ['line', 'circle', 'wave', 'zigzag']);
  for (const g of Calibration.GUIDES) {
    assert.ok(g.points.length > 50);
    for (const p of g.points) assert.ok(p.x >= 0 && p.x <= Calibration.ASPECT && p.y >= 0 && p.y <= 1, `${g.id} leaves its box`);
  }
});

test('stabilizer test: steady hands get light smoothing, shaky hands get more', () => {
  const steady = Calibration.measure(Calibration.GUIDES.map((g) => traced(g, 1, 0.05, 0.05)));
  assert.ok(steady.shake < 0.1 && steady.amount <= 0.15 && steady.level === 'Rock steady' && steady.steadiness > 75);
  assert.ok(steady.lines[3] < 0.1, 'zigzag corners are not counted as shake');
  let last = -1, lastShake = -1;
  for (const [j, d] of [[0.1, 0.2], [0.3, 0.6], [0.6, 1.2], [1, 2], [1.6, 3.2]]) {
    const r = Calibration.measure(Calibration.GUIDES.map((g) => traced(g, 3, j, d)));
    assert.ok(r.shake > lastShake && r.amount >= last);
    last = r.amount;
    lastShake = r.shake;
  }
  assert.ok(last > 0.5, 'a very shaky hand gets strong smoothing');
});

test('stabilizer test: zoom does not change the result, and two lines are needed', () => {
  const one = Calibration.measure(Calibration.GUIDES.map((g) => traced(g, 2, 0.4, 0.8)));
  const four = Calibration.measure(Calibration.GUIDES.map((g) => traced(g, 2, 0.4, 0.8, 4)), 4);
  assert.ok(Math.abs(one.shake - four.shake) < 0.05);
  const single = [traced(Calibration.GUIDES[0], 1, 0.3, 0.5)];
  assert.equal(Calibration.measure(single), null);
  const dot = [{ x: 5, y: 5, pressure: 0.5 }, { x: 6, y: 5, pressure: 0.5 }, { x: 6, y: 6, pressure: 0.5 }];
  assert.equal(Calibration.measure([single[0], dot]), null);
});

test('stabilizer test: table and words', () => {
  assert.equal(Calibration.recommendedAmount(0), 0.08);
  assert.equal(Calibration.recommendedAmount(0.17), 0.25);
  assert.equal(Calibration.recommendedAmount(5), 1);
  assert.equal(Calibration.recommendedAmount(NaN), 0.08);
  let prev = 0;
  for (let i = 0; i <= 150; i++) {
    const a = Calibration.recommendedAmount(i / 100);
    assert.ok(a >= prev);
    prev = a;
  }
  assert.equal(Calibration.steadiness(0), 100);
  assert.equal(Calibration.levelName(0.25), 'A little shaky');
  assert.equal(Calibration.levelName(2), 'Very shaky');
  const w = Calibration.quadWeights(10);
  assert.ok(Math.abs(w.reduce((a, b) => a + b, 0) - 1) < 1e-9);
});
