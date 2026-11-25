'use strict';
// Makes shaky lines smooth while you draw (port of Swift's Stabilizer.swift, same constants).
//
// Two steps, both tuned so faces, eyes and corners keep the shape you drew:
// 1. A "pulled string" (StrokeStabilizer) for strong smoothing only: the brush sits at the end of an
//    invisible string and only moves when your pen pulls it tight. The string starts at zero and grows
//    with the line, so short strokes draw exactly where you touch.
//    Adaptive: when you turn a sharp corner or stop for a moment, the brush snaps to exactly where your
//    pen turned and the string starts again from there, so corners and zigzags stay crisp.
// 2. A finishing step (shape) that evens out wobbles by distance along the line, keeps both ends and
//    every real corner exactly where they are, and blends short lines less.
//    Adaptive: it smooths less where the line bends on purpose and more along long, steady curves.
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

/** The numbers adaptive smoothing uses (same as Swift's StrokeSmoothing.Adaptive). */
const ADAPTIVE = {
  /** A turn sharper than this (degrees) while drawing makes the brush snap to the corner. */
  snapAngle: 55,
  /** How far each way (screen points) a turn is measured while drawing, at 50% smoothing (more for stronger smoothing). */
  snapArm: 12,
  /** Each side of a corner must be this straight: touches stray from a straight line by at most this much of its length. */
  straightness: 0.07,
  /** Each side's straight-across distance must be at least this much of the distance drawn along it. */
  chord: 0.8,
  /** While drawing, touches are evened out over this many screen points before looking for corners. */
  blur: 1.5,
  /** How much a wobbly hand raises the turn needed to snap (times the wobble seen so far). */
  wobbleWeight: 5,
  /** The side after a corner is checked over this many arms. */
  outArm: 2,
  /** With a long string, corners are measured over at least this many string lengths. */
  armPerString: 1.5,
  /** Holding the pen within this many screen points... */
  pauseMove: 1,
  /** ...for this many seconds is a pause: the brush catches up to the pen. */
  pauseTime: 0.12,
  /** Steady stretches are measured over this many corner arms. */
  longArm: 2.5,
  /** Below this bend (degrees, over the long arm) a stretch is a steady curve and gets extra smoothing. */
  steadyBend: 10,
  /** From this bend up, smoothing is turned down... */
  softBend: 30,
  /** ...to this much of normal at the corner angle. */
  cornerFactor: 0.3,
  /** Steady curves get up to this much more smoothing. */
  curveBoost: 1.5,
  /** Only lines at least this long (screen points) get the extra smoothing on curves. */
  boostLength: 50,
};

const clamp01 = (a) => Math.min(1, Math.max(0, Number.isFinite(a) ? a : 0));

/** How a smoothing amount reads in the app: "Off" or a percentage. */
function label(amount) {
  const a = clamp01(amount);
  return a < 0.005 ? 'Off' : `${Math.round(a * 100)}%`;
}

const hasTime = (p) => typeof p.time === 'number' && Number.isFinite(p.time);

class StrokeStabilizer {
  constructor(amount, scale = 1, adaptive = true) {
    this.amount = clamp01(amount);
    this.scale = Math.max(0.01, scale);
    this.adaptive = adaptive !== false;
    this.lazy = G.v(0, 0);
    this.out = G.v(0, 0);
    this.outPressure = 0.5;
    this.cursor = null;
    this.lastTouch = G.v(0, 0);
    this.lastEmitted = null;
    this.started = false;
    this.traveled = 0;
    /** Distance since the brush last snapped to a corner or caught up after a pause (null = never). */
    this.sinceReset = null;
    /** Every point drawn so far in this stroke. A snap can redraw the end of it. */
    this.points = [];
    /** How many corners the brush snapped to in this stroke. */
    this.corners = 0;
    this.hist = [];
    this.histDone = [];
    this.lastCorner = -1;
    this.stillAt = null;
    this.stillSince = 0;
    this.wobble = 0;
    this.wobbleSeen = false;
  }

  /** How hard the string pulls back (0 for light smoothing). */
  get pull() {
    return Math.max(0, (this.amount - STRING_STARTS) / (1 - STRING_STARTS));
  }

  /** Longest the string gets, in canvas pixels (about 16 screen points at full strength). */
  get maxStringLength() {
    return Math.pow(this.pull, 1.3) * 16 * this.scale;
  }

  /** Length of the string right now. It grows with the line (again after a corner), so short strokes keep their shape. */
  get stringLength() {
    const d = this.sinceReset === null ? this.traveled : this.sinceReset;
    return Math.min(this.maxStringLength, d * 0.1);
  }

  /** How quickly the brush glides (1 = instantly). Right after a corner it glides in gently again. */
  get glide() {
    const ramp = this.sinceReset === null ? 1 : Math.min(1, this.sinceReset / (20 * this.scale));
    return 1 - 0.6 * this.pull * ramp;
  }

  begin(p) {
    this.started = true;
    this.traveled = 0;
    this.sinceReset = null;
    this.lazy = G.v(p.x, p.y);
    this.out = this.lazy;
    this.lastTouch = this.lazy;
    this.outPressure = p.pressure;
    this.cursor = p;
    this.lastEmitted = this.out;
    this.points = [{ ...p }];
    this.corners = 0;
    this.hist = [{ ...p }];
    this.histDone = [1];
    this.lastCorner = -1;
    this.stillAt = this.lazy;
    this.stillSince = hasTime(p) ? p.time : 0;
    this.wobble = 0;
    this.wobbleSeen = false;
    return [{ ...p }];
  }

  add(p) {
    if (!this.started) return this.begin(p);
    const before = this.points.length;
    const target = G.v(p.x, p.y);
    if (this.adaptive && this.pull > 0) {
      // A pause: you held the pen still, so the brush catches up to exactly where you stopped.
      if (hasTime(p) && this.stillAt && G.dist(this.stillAt, target) > ADAPTIVE.pauseMove * this.scale) {
        if (p.time - this.stillSince >= ADAPTIVE.pauseTime) this.catchUp(this.stillAt, this.cursor.pressure);
        this.stillAt = target;
        this.stillSince = p.time;
      }
    }
    this.cursor = p;
    this.traveled += G.dist(this.lastTouch, target);
    if (this.sinceReset !== null) this.sinceReset += G.dist(this.lastTouch, target);
    this.lastTouch = target;
    this.step(p);
    if (this.adaptive && this.pull > 0) {
      const last = this.hist[this.hist.length - 1];
      if (G.dist(last, target) >= 0.5 * this.scale) {
        this.hist.push({ ...p });
        this.histDone.push(this.points.length);
        this.checkCorner(false);
      }
    }
    return this.newSince(before);
  }

  /** Moves the brush toward a touch and draws it. */
  step(p) {
    const target = G.v(p.x, p.y);
    if (this.pull <= 0) {
      this.out = target;
      this.lazy = target;
      this.outPressure = p.pressure;
      this.emit(target, p, p.pressure);
      return;
    }
    const d = G.dist(this.lazy, target);
    const r = this.stringLength;
    if (d > r) {
      this.lazy = G.add(this.lazy, G.mul(G.sub(target, this.lazy), (d - r) / d));
    }
    const a = this.glide;
    this.out = G.add(this.out, G.mul(G.sub(this.lazy, this.out), a));
    this.outPressure += (p.pressure - this.outPressure) * Math.min(1, a + 0.2);
    this.emit(this.out, p, this.outPressure);
  }

  /** Draws straight from the brush to `pos` and starts the string again from there. */
  catchUp(pos, pressure) {
    this.lineTo(pos, pressure, this.cursor);
    this.lazy = pos;
    this.out = pos;
    this.outPressure = pressure;
    this.sinceReset = 0;
  }

  lineTo(pos, pressure, from) {
    const start = this.out;
    const gap = G.dist(start, pos);
    if (gap < 0.05 * this.scale) return;
    const steps = Math.max(1, Math.ceil(gap / (1.5 * this.scale)));
    for (let i = 1; i <= steps; i++) {
      const t = i / steps;
      const q = G.lerp(start, pos, t);
      this.emit(q, from, this.outPressure + (pressure - this.outPressure) * t, true);
    }
  }

  /** Looks back along where the pen went for a sharp turn, and snaps the brush to it. */
  checkCorner(atEnd) {
    const h = this.hist;
    const n = h.length;
    const s = this.scale;
    // Shakier hands use stronger smoothing, so corners are measured over a longer stretch (at least the string).
    const arm = Math.max(ADAPTIVE.snapArm * s * (0.5 + this.amount), this.maxStringLength * ADAPTIVE.armPerString);
    if (n < 4) return;
    // Walk back from the pen far enough to see both sides (never past the last corner).
    let lo = n - 1;
    let walked = 0;
    while (lo > this.lastCorner + 1 && lo > 0 && walked < (2 + ADAPTIVE.outArm) * arm) {
      walked += G.dist(h[lo], h[lo - 1]);
      lo--;
    }
    if (walked < 1.6 * arm) return;
    // Spread the touches evenly and even out hand shake a little (just for measuring).
    const step = 0.5 * s;
    const even = evenly(h, lo, n - 1, step);
    const pts = blur(even, Math.max(1, Math.round((ADAPTIVE.blur * s) / step)));
    const m = pts.length;
    const k = Math.round(arm / step);
    // The side after the corner must stay straight for longer, so a quick wobble isn't taken for a corner.
    const kOut = Math.round((arm * ADAPTIVE.outArm) / step);
    if (m < k + 3) return;
    // The point furthest from the straight line across the window is where it turned.
    const a = pts[0], c = pts[m - 1];
    let best = -1, bestD = -1;
    for (let j = 1; j < m - 1; j++) {
      const d = distToSegment(pts[j], a, c);
      if (d > bestD) { bestD = d; best = j; }
    }
    if (best < 0) return;
    const outLen = Math.min(kOut, m - 1 - best);
    const inLen = Math.min(k, best);
    if (outLen < (atEnd ? 0.45 * k : kOut) || inLen < 0.6 * k) return;
    // Both sides must be straight lines: fit a line to each and check how far the touches stray from it.
    // Hand shake strays a lot; a corner you drew doesn't.
    const fIn = fitLine(pts, best - inLen, best);
    const fOut = fitLine(pts, best, best + outLen);
    // How much your hand has wobbled so far in this stroke. Wobblier hands need a sharper turn to count.
    this.wobble = this.wobbleSeen ? this.wobble + (fIn.spread - this.wobble) * 0.15 : fIn.spread;
    this.wobbleSeen = true;
    // Straight across must be nearly as far as along the touches (a zigzagging shake isn't).
    const chordIn = G.dist(pts[best], pts[best - inLen]);
    const chordOut = G.dist(pts[best + outLen], pts[best]);
    if (chordIn < ADAPTIVE.chord * along(pts, best - inLen, best) || chordOut < ADAPTIVE.chord * along(pts, best, best + outLen)) return;
    const tol = ADAPTIVE.straightness;
    if (fIn.spread > tol * chordIn || fOut.spread > tol * chordOut) return;
    const noise = (2 * Math.atan((ADAPTIVE.wobbleWeight * this.wobble) / chordIn) * 180) / Math.PI;
    if (angleBetween(fIn.dir, fOut.dir) < ADAPTIVE.snapAngle + noise) return;
    // Snap to the real touch nearest the corner.
    const corner = even[best];
    let index = lo, nearest = Infinity;
    for (let j = lo; j < n; j++) {
      const d = G.dist(h[j], corner);
      if (d < nearest) { nearest = d; index = j; }
    }
    if (index <= this.lastCorner || index >= n - 1) return;
    this.snapTo(index);
  }

  /** Redraws the end of the line so it goes straight into the corner, then follows the pen out of it. */
  snapTo(index) {
    const v = this.hist[index];
    // Take back what was drawn after the pen reached the corner (the brush was cutting across it).
    const keep = Math.max(1, Math.min(this.points.length, this.histDone[index]));
    this.points.length = keep;
    const last = this.points[keep - 1];
    this.out = G.v(last.x, last.y);
    this.outPressure = last.pressure;
    this.lastEmitted = this.out;
    this.lineTo(G.v(v.x, v.y), v.pressure, v);
    this.lazy = G.v(v.x, v.y);
    this.out = this.lazy;
    this.outPressure = v.pressure;
    this.lastEmitted = this.out;
    this.sinceReset = 0;
    this.lastCorner = index;
    this.corners += 1;
    // Follow the pen from the corner to where it is now.
    let prev = this.lazy;
    for (let k = index + 1; k < this.hist.length; k++) {
      const q = this.hist[k];
      this.sinceReset += G.dist(prev, q);
      prev = G.v(q.x, q.y);
      this.step(q);
      this.histDone[k] = this.points.length;
    }
    const tip = G.v(this.cursor.x, this.cursor.y);
    this.sinceReset += G.dist(prev, tip);
    if (G.dist(prev, tip) > 0) this.step(this.cursor);
  }

  /** Finishes the line where you lifted, gliding in smoothly, so the end is never cut short. */
  end() {
    if (!this.started || !this.cursor) {
      this.started = false;
      return [];
    }
    const before = this.points.length;
    if (this.adaptive && this.pull > 0) this.checkCorner(true);
    this.started = false;
    const c = this.cursor;
    const target = G.v(c.x, c.y);
    const gap = G.dist(this.out, target);
    if (gap >= 0.05 * this.scale) {
      const steps = Math.max(1, Math.ceil(gap / (1.5 * this.scale)));
      const start = this.out;
      for (let i = 1; i <= steps; i++) {
        // Ease out so the end doesn't look like a straight tail.
        const t = i / steps;
        const e = 1 - (1 - t) * (1 - t);
        const pos = G.lerp(start, target, e);
        this.points.push({ ...c, x: pos.x, y: pos.y, pressure: this.outPressure + (c.pressure - this.outPressure) * t });
      }
      this.out = target;
      this.lastEmitted = target;
    }
    return this.newSince(before);
  }

  newSince(before) {
    // After a snap the line was redrawn from an earlier point: hand back the redrawn part.
    return this.points.slice(Math.min(before, this.points.length)).map((p) => ({ ...p }));
  }

  emit(pos, p, pressure, force = false) {
    if (!force && this.lastEmitted && G.dist(this.lastEmitted, pos) < 0.35 * Math.min(1, this.scale)) return;
    if (force && this.lastEmitted && G.dist(this.lastEmitted, pos) < 1e-9) return;
    this.lastEmitted = pos;
    this.points.push({ ...p, x: pos.x, y: pos.y, pressure });
  }

  /** Runs a whole list of points through a fresh stabilizer (for tests, imports and replays). */
  static stabilize(points, amount, scale = 1, adaptive = true) {
    if (!points.length) return [];
    const s = new StrokeStabilizer(amount, scale, adaptive);
    s.begin(points[0]);
    for (let i = 1; i < points.length; i++) s.add(points[i]);
    s.end();
    return s.points.map((p) => ({ ...p }));
  }
}

/** Touches `lo...hi` spread evenly, `step` apart (positions only). */
function evenly(h, lo, hi, step) {
  const out = [G.v(h[lo].x, h[lo].y)];
  let carried = 0;
  for (let i = lo; i < hi; i++) {
    const a = h[i], b = h[i + 1];
    const seg = G.dist(a, b);
    if (seg <= 0) continue;
    let at = step - carried;
    while (at <= seg) {
      out.push(G.lerp(a, b, at / seg));
      at += step;
    }
    carried = seg - (at - step);
  }
  return out;
}

/** Each point averaged with `reach` neighbours each way. */
function blur(pts, reach) {
  const out = [];
  for (let k = 0; k < pts.length; k++) {
    const a = Math.max(0, k - reach), z = Math.min(pts.length - 1, k + reach);
    let sx = 0, sy = 0;
    for (let j = a; j <= z; j++) { sx += pts[j].x; sy += pts[j].y; }
    out.push(G.v(sx / (z - a + 1), sy / (z - a + 1)));
  }
  return out;
}

/** The straight line that best fits points `a...b`: which way it goes (from a toward b) and how far points stray (RMS). */
function fitLine(pts, a, b) {
  let cx = 0, cy = 0;
  const n = b - a + 1;
  for (let i = a; i <= b; i++) { cx += pts[i].x; cy += pts[i].y; }
  cx /= n; cy /= n;
  let sxx = 0, sxy = 0, syy = 0;
  for (let i = a; i <= b; i++) {
    const dx = pts[i].x - cx, dy = pts[i].y - cy;
    sxx += dx * dx; sxy += dx * dy; syy += dy * dy;
  }
  const theta = 0.5 * Math.atan2(2 * sxy, sxx - syy);
  let dir = G.v(Math.cos(theta), Math.sin(theta));
  if (G.dot(dir, G.sub(pts[b], pts[a])) < 0) dir = G.mul(dir, -1);
  const nrm = G.v(-dir.y, dir.x);
  let ss = 0;
  for (let i = a; i <= b; i++) {
    const d = G.dot(G.sub(pts[i], G.v(cx, cy)), nrm);
    ss += d * d;
  }
  return { dir, spread: Math.sqrt(ss / n) };
}

/** Distance along points `a...b`. */
function along(pts, a, b) {
  let d = 0;
  for (let i = a + 1; i <= b; i++) d += G.dist(pts[i - 1], pts[i]);
  return d;
}

/** The angle between two directions, in degrees. */
function angleBetween(a, b) {
  if (G.len(a) < 1e-9 || G.len(b) < 1e-9) return 180;
  const c = Math.max(-1, Math.min(1, G.dot(G.norm(a), G.norm(b))));
  return (Math.acos(c) * 180) / Math.PI;
}

function distToSegment(p, a, b) {
  const ab = G.sub(b, a);
  const l2 = G.dot(ab, ab);
  if (l2 < 1e-12) return G.dist(p, a);
  const t = Math.max(0, Math.min(1, G.dot(G.sub(p, a), ab) / l2));
  return G.dist(p, G.add(a, G.mul(ab, t)));
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

/** How much each point bends (degrees), measured `k` points each way after a light blur. */
function bends(even, k, arm) {
  const n = even.length;
  const out = new Array(n).fill(0);
  if (n <= 2 * k + 1) return out;
  // A light blur (a third of the arm) just for measuring, so hand shake doesn't count as bends.
  const blurReach = Math.max(1, Math.floor(k / 3));
  const pos = [];
  for (let i = 0; i < n; i++) {
    const lo = Math.max(0, i - blurReach), hi = Math.min(n - 1, i + blurReach);
    let sx = 0, sy = 0;
    for (let j = lo; j <= hi; j++) { sx += even[j].x; sy += even[j].y; }
    pos.push(G.v(sx / (hi - lo + 1), sy / (hi - lo + 1)));
  }
  for (let i = k; i < n - k; i++) {
    const d1 = G.sub(pos[i], pos[i - k]);
    const d2 = G.sub(pos[i + k], pos[i]);
    if (G.len(d1) <= arm * 0.3 || G.len(d2) <= arm * 0.3) continue;
    const c = Math.max(-1, Math.min(1, G.dot(G.norm(d1), G.norm(d2))));
    out[i] = (Math.acos(c) * 180) / Math.PI;
  }
  return out;
}

/** Corners you meant to draw in an evenly spread line: the sharpest point of every bend over `angle`. */
function corners(even, arm, angle, spacing) {
  const n = even.length;
  const k = Math.max(1, Math.round(arm / spacing));
  if (n <= 2 * k + 1) return [];
  const bend = bends(even, k, arm);
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

/**
 * How much of the normal smoothing each point gets (adaptive smoothing): less where the line bends on
 * purpose (so soft corners and zigzags stay crisp), more along long steady curves.
 * `even` is spread `spacing` apart, `arm` is the corner arm in canvas pixels.
 */
function adaptiveFactors(even, arm, angle, spacing, length, scale) {
  const n = even.length;
  const k = Math.max(1, Math.round((arm * ADAPTIVE.longArm) / spacing));
  const bend = bends(even, k, arm * ADAPTIVE.longArm);
  const canBoost = length >= ADAPTIVE.boostLength * scale;
  const raw = new Array(n);
  for (let i = 0; i < n; i++) {
    const b = bend[i];
    let f = 1;
    if (b >= ADAPTIVE.softBend) {
      const t = Math.min(1, (b - ADAPTIVE.softBend) / Math.max(1, angle - ADAPTIVE.softBend));
      f = 1 - t * (1 - ADAPTIVE.cornerFactor);
    } else if (canBoost && b <= ADAPTIVE.steadyBend && i >= k && i < n - k) {
      f = ADAPTIVE.curveBoost;
    } else if (canBoost && i >= k && i < n - k) {
      const t = (b - ADAPTIVE.steadyBend) / (ADAPTIVE.softBend - ADAPTIVE.steadyBend);
      f = ADAPTIVE.curveBoost + (1 - ADAPTIVE.curveBoost) * t;
    }
    raw[i] = f;
  }
  // Take the smallest factor nearby (so the smoothing turns down before it reaches a bend), then soften it.
  const near = new Array(n);
  for (let i = 0; i < n; i++) {
    let m = raw[i];
    for (let j = Math.max(0, i - k); j <= Math.min(n - 1, i + k); j++) if (raw[j] < m) m = raw[j];
    near[i] = m;
  }
  const out = new Array(n);
  const r = Math.max(1, Math.floor(k / 2));
  for (let i = 0; i < n; i++) {
    let s = 0, c = 0;
    for (let j = Math.max(0, i - r); j <= Math.min(n - 1, i + r); j++) { s += near[j]; c++; }
    out[i] = s / c;
  }
  return out;
}

/** Evens out wobbles by distance along the line; keeps both ends and corners, blends short lines less. */
function round(points, r, cornerArm = null, cornerAngle = CORNER_ANGLE, adaptive = false, scale = 1) {
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
  const factors = adaptive && cornerArm && cornerArm > 0
    ? adaptiveFactors(even, cornerArm, cornerAngle, spacing, length, Math.max(0.01, scale))
    : null;
  // Longest reach anywhere (steady curves reach further, but short lines still never more than an eighth).
  const maxReach = factors
    ? Math.max(reach, Math.round(Math.min(r * ADAPTIVE.curveBoost, length / 8) / spacing))
    : reach;
  const out = even.map((p) => ({ ...p }));
  for (let a = 0; a < anchors.length - 1; a++) {
    const lo = anchors[a], hi = anchors[a + 1];
    for (let i = lo + 1; i < hi; i++) {
      const ri = factors ? Math.max(0, Math.min(maxReach, Math.round(reach * factors[i]))) : reach;
      const w0 = Math.min(ri, i - lo, hi - i);
      if (w0 < 1) continue;
      const sigma = Math.max(0.5, ri / 2);
      let sx = 0, sy = 0, sp = 0, sw = 0;
      for (let k = -w0; k <= w0; k++) {
        const w = Math.exp(-(k * k) / (2 * sigma * sigma));
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

/**
 * The finishing step the editor uses while drawing and when you lift. `scale` = canvas pixels per screen point.
 * `adaptive` (on unless you turn "Keep corners sharp" off) smooths less at bends and more on long curves.
 */
function shape(points, amount, scale = 1, adaptive = true) {
  const a = clamp01(amount);
  if (a <= 0.005) return points;
  const s = Math.max(0.01, scale);
  return round(points, radius(a, s), CORNER_ARM * s, CORNER_ANGLE, adaptive !== false, s);
}

/** The whole pipeline on a list of points: the live string, then the finishing step. */
function finish(raw, amount, scale = 1, adaptive = true) {
  return shape(StrokeStabilizer.stabilize(raw, amount, scale, adaptive), amount, scale, adaptive);
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
  StrokeStabilizer, smooth, shape, finish, round, corners, bends, adaptiveFactors, resample, radius, label,
  DEFAULT_AMOUNT, CORNER_ANGLE, CORNER_ARM, STRING_STARTS, ADAPTIVE,
};
