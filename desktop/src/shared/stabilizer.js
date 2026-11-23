'use strict';
// Makes shaky lines smooth while you draw (port of Swift's Stabilizer.swift, same constants).
//
// Two steps, both tuned so faces, eyes and corners keep the shape you drew:
// 1. A "pulled string" (StrokeStabilizer) for strong smoothing only: the brush sits at the end of an
//    invisible string and only moves when your pen pulls it tight. The string starts at zero and grows
//    with the line, so short strokes draw exactly where you touch.
// 2. A finishing step (shape) that evens out wobbles by distance along the line, keeps both ends and
//    every real corner exactly where they are, and blends short lines less.
// `amount` 0 is off. 1 is the strongest smoothing.

const G = require('./geometry');

/** Light by default, so small details keep their shape. */
const DEFAULT_AMOUNT = 0.25;
/** A bend sharper than this (degrees) is a corner you meant, so it's kept sharp. */
const CORNER_ANGLE = 60;
/** How far each way (screen points) a bend is measured to decide if it's a corner. */
const CORNER_ARM = 6;
/** Below this amount the live string is off and only the finishing step smooths. */
const STRING_STARTS = 0.35;

const clamp01 = (a) => Math.min(1, Math.max(0, Number.isFinite(a) ? a : 0));

/** How a smoothing amount reads in the app: "Off" or a percentage. */
function label(amount) {
  const a = clamp01(amount);
  return a < 0.005 ? 'Off' : `${Math.round(a * 100)}%`;
}

class StrokeStabilizer {
  constructor(amount, scale = 1) {
    this.amount = clamp01(amount);
    this.scale = Math.max(0.01, scale);
    this.lazy = G.v(0, 0);
    this.out = G.v(0, 0);
    this.outPressure = 0.5;
    this.cursor = null;
    this.lastTouch = G.v(0, 0);
    this.lastEmitted = null;
    this.started = false;
    this.traveled = 0;
  }

  /** How hard the string pulls back (0 for light smoothing). */
  get pull() {
    return Math.max(0, (this.amount - STRING_STARTS) / (1 - STRING_STARTS));
  }

  /** Longest the string gets, in canvas pixels (about 16 screen points at full strength). */
  get maxStringLength() {
    return Math.pow(this.pull, 1.3) * 16 * this.scale;
  }

  /** Length of the string right now. It grows with the line, so short strokes keep their shape. */
  get stringLength() {
    return Math.min(this.maxStringLength, this.traveled * 0.1);
  }

  /** How quickly the brush glides (1 = instantly). */
  get glide() {
    return 1 - 0.6 * this.pull;
  }

  begin(p) {
    this.started = true;
    this.traveled = 0;
    this.lazy = G.v(p.x, p.y);
    this.out = this.lazy;
    this.lastTouch = this.lazy;
    this.outPressure = p.pressure;
    this.cursor = p;
    this.lastEmitted = this.out;
    return [{ ...p }];
  }

  add(p) {
    if (!this.started) return this.begin(p);
    this.cursor = p;
    const target = G.v(p.x, p.y);
    this.traveled += G.dist(this.lastTouch, target);
    this.lastTouch = target;
    if (this.pull <= 0) {
      this.out = target;
      this.lazy = target;
      this.outPressure = p.pressure;
      return this.emit(target, p, p.pressure);
    }
    const d = G.dist(this.lazy, target);
    const r = this.stringLength;
    if (d > r) {
      this.lazy = G.add(this.lazy, G.mul(G.sub(target, this.lazy), (d - r) / d));
    }
    const a = this.glide;
    this.out = G.add(this.out, G.mul(G.sub(this.lazy, this.out), a));
    this.outPressure += (p.pressure - this.outPressure) * Math.min(1, a + 0.2);
    return this.emit(this.out, p, this.outPressure);
  }

  /** Finishes the line where you lifted, gliding in smoothly, so the end is never cut short. */
  end() {
    if (!this.started || !this.cursor) {
      this.started = false;
      return [];
    }
    this.started = false;
    const c = this.cursor;
    const target = G.v(c.x, c.y);
    const gap = G.dist(this.out, target);
    if (gap < 0.05 * this.scale) return [];
    const result = [];
    const steps = Math.max(1, Math.ceil(gap / (1.5 * this.scale)));
    const start = this.out;
    for (let i = 1; i <= steps; i++) {
      // Ease out so the end doesn't look like a straight tail.
      const t = i / steps;
      const e = 1 - (1 - t) * (1 - t);
      const pos = G.lerp(start, target, e);
      result.push({ ...c, x: pos.x, y: pos.y, pressure: this.outPressure + (c.pressure - this.outPressure) * t });
    }
    this.out = target;
    this.lastEmitted = target;
    return result;
  }

  emit(pos, p, pressure) {
    if (this.lastEmitted && G.dist(this.lastEmitted, pos) < 0.35 * Math.min(1, this.scale)) return [];
    this.lastEmitted = pos;
    return [{ ...p, x: pos.x, y: pos.y, pressure }];
  }

  /** Runs a whole list of points through a fresh stabilizer (for tests, imports and replays). */
  static stabilize(points, amount, scale = 1) {
    if (!points.length) return [];
    const s = new StrokeStabilizer(amount, scale);
    let out = s.begin(points[0]);
    for (let i = 1; i < points.length; i++) out = out.concat(s.add(points[i]));
    return out.concat(s.end());
  }
}

/** How far (canvas pixels) the finishing step reaches. About 20 screen points at full strength. */
function radius(amount, scale = 1) {
  return clamp01(amount) * 20 * Math.max(0.01, scale);
}

/** Points spread evenly along the line, `spacing` apart. Keeps the first and last point. */
function resample(pts, spacing) {
  if (pts.length <= 1) return pts.map((p) => ({ ...p }));
  const step = Math.max(0.05, spacing);
  const lerpNum = (a, b, t) => (typeof a === 'number' && typeof b === 'number' ? a + (b - a) * t : a);
  const out = [{ ...pts[0] }];
  let carried = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i + 1];
    const seg = G.dist(a, b);
    if (seg <= 0) continue;
    let at = step - carried;
    while (at <= seg) {
      const t = at / seg;
      const q = { ...a };
      for (const k of ['x', 'y', 'pressure', 'altitude', 'azimuth', 'time']) q[k] = lerpNum(a[k], b[k], t);
      out.push(q);
      at += step;
    }
    carried = seg - (at - step);
  }
  const last = pts[pts.length - 1];
  const end = out[out.length - 1];
  if (G.dist(end, last) > step * 0.35) out.push({ ...last });
  else if (out.length > 1) out[out.length - 1] = { ...last };
  else if (G.dist(pts[0], last) > 0) out.push({ ...last });
  return out;
}

/** Corners you meant to draw in an evenly spread line: the sharpest point of every bend over `angle`. */
function corners(even, arm, angle, spacing) {
  const n = even.length;
  const k = Math.max(1, Math.round(arm / spacing));
  if (n <= 2 * k + 1) return [];
  // A light blur (a third of the arm) just for measuring, so hand shake doesn't count as corners.
  const blurReach = Math.max(1, Math.floor(k / 3));
  const pos = [];
  for (let i = 0; i < n; i++) {
    const lo = Math.max(0, i - blurReach), hi = Math.min(n - 1, i + blurReach);
    let sx = 0, sy = 0;
    for (let j = lo; j <= hi; j++) { sx += even[j].x; sy += even[j].y; }
    pos.push(G.v(sx / (hi - lo + 1), sy / (hi - lo + 1)));
  }
  const bend = new Array(n).fill(0);
  for (let i = k; i < n - k; i++) {
    const d1 = G.sub(pos[i], pos[i - k]);
    const d2 = G.sub(pos[i + k], pos[i]);
    if (G.len(d1) <= arm * 0.3 || G.len(d2) <= arm * 0.3) continue;
    const c = Math.max(-1, Math.min(1, G.dot(G.norm(d1), G.norm(d2))));
    bend[i] = (Math.acos(c) * 180) / Math.PI;
  }
  const found = [];
  let i = k;
  while (i < n - k) {
    if (bend[i] < angle) { i++; continue; }
    let best = i;
    let j = i;
    while (j < n - k && bend[j] >= angle * 0.6) {
      if (bend[j] > bend[best]) best = j;
      j++;
    }
    const last = found[found.length - 1];
    if (last !== undefined && best - last < k) {
      if (bend[best] > bend[last]) found[found.length - 1] = best;
    } else {
      found.push(best);
    }
    i = j + 1;
  }
  return found;
}

/** Evens out wobbles by distance along the line; keeps both ends and corners, blends short lines less. */
function round(points, r, cornerArm = null, cornerAngle = CORNER_ANGLE) {
  if (points.length <= 2 || r <= 0.25) return points;
  const spacing = Math.max(0.5, Math.min(4, r / 5));
  const even = resample(points, spacing);
  const n = even.length;
  if (n <= 3) return even;
  let length = 0;
  for (let i = 1; i < n; i++) length += G.dist(even[i - 1], even[i]);
  const rr = Math.min(r, length / 8);
  const reach = Math.round(rr / spacing);
  if (reach < 1) return even;
  const anchors = [0];
  if (cornerArm && cornerArm > 0) anchors.push(...corners(even, cornerArm, cornerAngle, spacing));
  anchors.push(n - 1);
  const sigma = reach / 2;
  const weights = [];
  for (let k = 0; k <= reach; k++) weights.push(Math.exp(-(k * k) / (2 * sigma * sigma)));
  const out = even.map((p) => ({ ...p }));
  for (let a = 0; a < anchors.length - 1; a++) {
    const lo = anchors[a], hi = anchors[a + 1];
    for (let i = lo + 1; i < hi; i++) {
      const w0 = Math.min(reach, i - lo, hi - i);
      let sx = 0, sy = 0, sp = 0, sw = 0;
      for (let k = -w0; k <= w0; k++) {
        const w = weights[Math.abs(k)];
        const q = even[i + k];
        sx += q.x * w;
        sy += q.y * w;
        sp += q.pressure * w;
        sw += w;
      }
      out[i].x = sx / sw;
      out[i].y = sy / sw;
      out[i].pressure = sp / sw;
    }
  }
  return out;
}

/** The finishing step the editor uses while drawing and when you lift. `scale` = canvas pixels per screen point. */
function shape(points, amount, scale = 1) {
  const a = clamp01(amount);
  if (a <= 0.005) return points;
  const s = Math.max(0.01, scale);
  return round(points, radius(a, s), CORNER_ARM * s, CORNER_ANGLE);
}

/** The whole pipeline on a list of points: the live string, then the finishing step. */
function finish(raw, amount, scale = 1) {
  return shape(StrokeStabilizer.stabilize(raw, amount, scale), amount, scale);
}

/** An older, simpler finishing pass (kept for imports and replays). */
function smooth(points, amount) {
  const a = clamp01(amount);
  if (points.length <= 3 || a <= 0.01) return points;
  const r = Math.max(1, Math.round(a * 4));
  const passes = a > 0.5 ? 2 : 1;
  let pts = points;
  for (let pass = 0; pass < passes; pass++) {
    const next = pts.map((p) => ({ ...p }));
    for (let i = 1; i < pts.length - 1; i++) {
      const w0 = Math.min(r, i, pts.length - 1 - i);
      let sx = 0, sy = 0, sp = 0, sw = 0;
      for (let k = -w0; k <= w0; k++) {
        const w = w0 + 1 - Math.abs(k);
        const q = pts[i + k];
        sx += q.x * w;
        sy += q.y * w;
        sp += q.pressure * w;
        sw += w;
      }
      next[i].x = sx / sw;
      next[i].y = sy / sw;
      next[i].pressure = sp / sw;
    }
    pts = next;
  }
  return pts;
}

module.exports = {
  StrokeStabilizer, smooth, shape, finish, round, corners, resample, radius, label,
  DEFAULT_AMOUNT, CORNER_ANGLE, CORNER_ARM, STRING_STARTS,
};
