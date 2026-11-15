'use strict';
// Makes shaky lines smooth while you draw (port of Swift's StrokeStabilizer, same constants).
//
// It works like a "pulled string": the brush sits at the end of an invisible string and only moves
// when your pen pulls the string tight. Small wobbles never pull it, so they vanish.
// On top of that, the brush glides toward where it's pulled instead of jumping.
// `amount` 0 draws exactly where you touch. 1 is the strongest smoothing.

const G = require('./geometry');

class StrokeStabilizer {
  constructor(amount, scale = 1) {
    this.amount = Math.min(1, Math.max(0, amount));
    this.scale = Math.max(0.01, scale);
    this.lazy = G.v(0, 0);
    this.out = G.v(0, 0);
    this.outPressure = 0.5;
    this.cursor = null;
    this.lastEmitted = null;
    this.started = false;
  }

  /** Length of the string in canvas pixels. */
  get stringLength() {
    return Math.pow(this.amount, 1.2) * 34 * this.scale;
  }

  /** How quickly the brush glides (1 = instantly). */
  get glide() {
    return 1 - 0.78 * this.amount;
  }

  begin(p) {
    this.started = true;
    this.lazy = G.v(p.x, p.y);
    this.out = this.lazy;
    this.outPressure = p.pressure;
    this.cursor = p;
    this.lastEmitted = this.out;
    return [{ ...p }];
  }

  add(p) {
    if (!this.started) return this.begin(p);
    this.cursor = p;
    if (this.amount <= 0.001) return this.emit(G.v(p.x, p.y), p, p.pressure);
    const target = G.v(p.x, p.y);
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

  /** Finishes the line where you lifted, gliding in smoothly. */
  end() {
    if (!this.started || !this.cursor) {
      this.started = false;
      return [];
    }
    this.started = false;
    const c = this.cursor;
    const target = G.v(c.x, c.y);
    const gap = G.dist(this.out, target);
    if (gap < 0.75 || this.amount <= 0.001) return [];
    const result = [];
    const steps = Math.max(1, Math.ceil(gap / 2));
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
    if (this.lastEmitted && G.dist(this.lastEmitted, pos) < 0.35) return [];
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

/** A last smoothing pass when a stroke is finished: evens out positions and pressure, keeping both ends. */
function smooth(points, amount) {
  const a = Math.min(1, Math.max(0, amount));
  if (points.length <= 3 || a <= 0.01) return points;
  const radius = Math.max(1, Math.round(a * 4));
  const passes = a > 0.5 ? 2 : 1;
  let pts = points;
  for (let pass = 0; pass < passes; pass++) {
    const next = pts.map((p) => ({ ...p }));
    for (let i = 1; i < pts.length - 1; i++) {
      const r = Math.min(radius, i, pts.length - 1 - i);
      let sx = 0, sy = 0, sp = 0, sw = 0;
      for (let k = -r; k <= r; k++) {
        const w = r + 1 - Math.abs(k);
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

module.exports = { StrokeStabilizer, smooth };
