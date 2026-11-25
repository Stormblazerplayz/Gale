'use strict';
// The stabilizer test (port of Swift's StabilizerCalibration.swift, same numbers).
//
// You trace a few guide shapes. Gale measures how much your hand shakes: it fits a smooth curve to every
// little stretch of each line and sees how far your touches wander from it. Real corners (the zigzag's
// points) are left out, so only shake counts. Then it picks the smoothing that suits your hand.

const G = require('./geometry');
const Stabilizer = require('./stabilizer');

/** Guides live in a box this wide and 1 tall. */
const ASPECT = 1.6;

/** Points along a guide, in box units (x 0...ASPECT, y 0...1, y down). */
function guidePoints(id) {
  const pts = [];
  switch (id) {
    case 'line':
      for (let i = 0; i <= 60; i++) {
        const t = i / 60;
        pts.push(G.v(0.2 + 1.2 * t, 0.75 - 0.5 * t));
      }
      break;
    case 'circle':
      for (let i = 0; i <= 120; i++) {
        const a = -Math.PI / 2 + (i / 120) * Math.PI * 2;
        pts.push(G.v(0.8 + 0.34 * Math.cos(a), 0.5 + 0.34 * Math.sin(a)));
      }
      break;
    case 'wave':
      for (let i = 0; i <= 120; i++) {
        const t = i / 120;
        pts.push(G.v(0.15 + 1.3 * t, 0.5 - 0.22 * Math.sin(t * Math.PI * 3)));
      }
      break;
    case 'zigzag': {
      const c = [[0.2, 0.7], [0.5, 0.3], [0.8, 0.7], [1.1, 0.3], [1.4, 0.7]];
      for (let s = 0; s < c.length - 1; s++) {
        for (let i = 0; i < 20; i++) {
          const t = i / 20;
          pts.push(G.v(c[s][0] + (c[s + 1][0] - c[s][0]) * t, c[s][1] + (c[s + 1][1] - c[s][1]) * t));
        }
      }
      pts.push(G.v(1.4, 0.7));
      break;
    }
    default:
      break;
  }
  return pts;
}

/** The shapes you trace, in order. */
const GUIDES = [
  { id: 'line', title: 'A straight line', tip: 'Follow the dot from start to end in one stroke.' },
  { id: 'circle', title: 'A circle', tip: 'Go all the way round at your normal speed.' },
  { id: 'wave', title: 'A wave', tip: 'Smooth and steady, like you’re drawing hair.' },
  { id: 'zigzag', title: 'A zigzag', tip: 'Sharp corners. This one shows off corner snapping.' },
].map((g) => ({ ...g, points: guidePoints(g.id) }));

/** Lines shorter than this (screen points) are too short to measure. */
const MIN_LENGTH = 40;
/** Each little stretch that gets a smooth curve fitted reaches this many screen points each way. */
const FIT_REACH = 10;
/** Points this close (screen points) to a real corner are left out. */
const CORNER_SKIP = 10;
/** At least this many lines must be measured for a result. */
const MIN_LINES = 2;

/** Shake (screen points) to smoothing: steadier hands get less, so details stay crisp. */
const TABLE = [
  [0, 0.08], [0.08, 0.14], [0.17, 0.25], [0.3, 0.4], [0.42, 0.55], [0.6, 0.78], [0.9, 0.92], [1.3, 1],
];

/** The smoothing that suits a hand that shakes `shake` screen points (RMS). */
function recommendedAmount(shake) {
  const s = Math.max(0, Number.isFinite(shake) ? shake : 0);
  if (s >= TABLE[TABLE.length - 1][0]) return TABLE[TABLE.length - 1][1];
  for (let i = 1; i < TABLE.length; i++) {
    const [x1, y1] = TABLE[i];
    if (s <= x1) {
      const [x0, y0] = TABLE[i - 1];
      const t = (s - x0) / (x1 - x0);
      return Math.round((y0 + (y1 - y0) * t) * 100) / 100;
    }
  }
  return 1;
}

/** 0 (very shaky) to 100 (rock steady). */
function steadiness(shake) {
  return Math.max(0, Math.min(100, Math.round(100 * Math.exp(-Math.max(0, shake) / 0.45))));
}

/** A few words for how steady a hand is. */
function levelName(shake) {
  if (shake < 0.1) return 'Rock steady';
  if (shake < 0.2) return 'Steady';
  if (shake < 0.35) return 'A little shaky';
  if (shake < 0.55) return 'Shaky';
  return 'Very shaky';
}

/**
 * Savitzky-Golay weights for a quadratic fit over 2m+1 points (the fitted value at the middle).
 * A curve that bends smoothly (like a circle) fits exactly, so only shake is left over.
 */
function quadWeights(m) {
  const d = (2 * m + 3) * (2 * m + 1) * (2 * m - 1);
  const w = [];
  for (let k = -m; k <= m; k++) w.push((3 * (3 * m * m + 3 * m - 1) - 15 * k * k) / d);
  return w;
}

/**
 * How much one line shakes: squared distances of each touch from a smooth curve fitted around it.
 * `scale` = canvas pixels per screen point. Returns { sum, count } in screen points, or null if too short.
 */
function lineShake(points, scale = 1) {
  const s = Math.max(0.01, scale);
  if (!points || points.length < 3) return null;
  const even = Stabilizer.resample(points, s);
  const n = even.length;
  if ((n - 1) < MIN_LENGTH) return null;
  const m = FIT_REACH;
  if (n < 2 * m + 3) return null;
  const w = quadWeights(m);
  const skip = new Array(n).fill(false);
  for (const c of Stabilizer.corners(even, Stabilizer.CORNER_ARM * s, Stabilizer.CORNER_ANGLE, s)) {
    for (let j = Math.max(0, c - CORNER_SKIP - m); j <= Math.min(n - 1, c + CORNER_SKIP + m); j++) skip[j] = true;
  }
  let sum = 0, count = 0;
  for (let i = m; i < n - m; i++) {
    if (skip[i]) continue;
    let fx = 0, fy = 0;
    for (let k = -m; k <= m; k++) {
      fx += w[k + m] * even[i + k].x;
      fy += w[k + m] * even[i + k].y;
    }
    const d = G.dist(even[i], G.v(fx, fy)) / s;
    sum += d * d;
    count++;
  }
  return count > 0 ? { sum, count } : null;
}

/**
 * Measures a stabilizer test: `lines` are the raw touches of each traced guide (canvas pixels).
 * Returns null until enough was drawn, otherwise
 * { shake (RMS, screen points), amount (recommended smoothing), steadiness (0-100), level, lines }.
 */
function measure(lines, scale = 1) {
  let sum = 0, count = 0, used = 0;
  const each = [];
  for (const pts of lines || []) {
    const r = lineShake(pts, scale);
    each.push(r ? Math.sqrt(r.sum / r.count) : null);
    if (!r) continue;
    sum += r.sum;
    count += r.count;
    used++;
  }
  if (used < MIN_LINES || count === 0) return null;
  const shake = Math.sqrt(sum / count);
  return {
    shake,
    amount: recommendedAmount(shake),
    steadiness: steadiness(shake),
    level: levelName(shake),
    lines: each,
  };
}

module.exports = {
  ASPECT, GUIDES, MIN_LENGTH, MIN_LINES, guidePoints, recommendedAmount, steadiness, levelName,
  quadWeights, lineShake, measure,
};
