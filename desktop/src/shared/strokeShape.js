'use strict';
// Turns stroke points into the shape that gets painted (port of Swift's StrokeShape, same numbers).
// Points are { x, y, pressure, altitude, azimuth, time }. A brush is { kind, color, size, opacity }.

const Color = require('./color');
const G = require('./geometry');
const Model = require('./model');

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/** Width at one point, in canvas pixels. */
function width(p, brush, index, count) {
  const size = Math.max(0.5, brush.size);
  const pr = clamp(p.pressure, 0, 1);
  let w;
  switch (brush.kind) {
    case 'pencil': {
      // Leaning the pencil over shades with its side, like a real pencil.
      const upright = clamp(p.altitude / (Math.PI / 2), 0, 1);
      const lean = Math.pow(1 - upright, 2);
      w = size * (0.5 + 0.5 * pr) * (1 + 2.2 * lean);
      break;
    }
    case 'marker': w = size * (0.85 + 0.15 * pr); break;
    case 'brush': w = size * (0.08 + 0.92 * Math.pow(pr, 1.3)); break;
    case 'airbrush': w = size; break;
    case 'eraser': w = size * (0.6 + 0.4 * pr); break;
    case 'pen':
    default:
      w = size * (0.28 + 0.72 * Math.pow(pr, 0.8));
      break;
  }
  // Pointy ends for inked lines.
  if ((brush.kind === 'pen' || brush.kind === 'brush') && count > 4) {
    const ramp = Math.min(6, Math.floor(count / 3));
    if (ramp > 0) {
      const fromStart = index / ramp;
      const fromEnd = (count - 1 - index) / ramp;
      const t = Math.min(1, Math.min(fromStart, fromEnd));
      w *= 0.35 + 0.65 * t;
    }
  }
  return Math.max(0.3, w);
}

function widths(points, brush) {
  const n = points.length;
  return points.map((p, i) => width(p, brush, i, n));
}

/** How opaque the whole stroke is. */
function alpha(points, brush) {
  const c = Color.parse(brush.color) || { a: 1 };
  const base = c.a * brush.opacity;
  switch (brush.kind) {
    case 'pencil': {
      const avg = points.length ? points.reduce((s, p) => s + p.pressure, 0) / points.length : 0.5;
      return base * (0.55 + 0.45 * avg);
    }
    case 'marker': return base * 0.8;
    case 'airbrush': return base * 0.35;
    default: return base;
  }
}

/** Adds points between far-apart samples along a smooth curve (Catmull-Rom), so fast strokes stay round. */
function densify(pts, spacing = 3) {
  if (pts.length <= 1) return pts.slice();
  const out = [pts[0]];
  const step = Math.max(0.5, spacing);
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[Math.max(0, i - 1)];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[Math.min(pts.length - 1, i + 2)];
    const d = G.dist(p1, p2);
    const n = Math.trunc(d / step);
    if (n > 1) {
      for (let k = 1; k < n; k++) {
        const t = k / n;
        const t2 = t * t, t3 = t2 * t;
        const x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3);
        const y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3);
        out.push({
          x,
          y,
          pressure: p1.pressure + (p2.pressure - p1.pressure) * t,
          altitude: p1.altitude + (p2.altitude - p1.altitude) * t,
          azimuth: p1.azimuth,
          time: p1.time + (p2.time - p1.time) * t,
        });
      }
    }
    out.push(p2);
  }
  return out;
}

/** Drops points that sit on top of the one before. */
function dedupe(pts, minDistance = 0.05) {
  if (!pts.length) return [];
  let last = pts[0];
  const out = [last];
  for (let i = 1; i < pts.length; i++) {
    if (G.dist(pts[i], last) >= minDistance) {
      out.push(pts[i]);
      last = pts[i];
    }
  }
  if (out.length === 1 && pts.length > 1) out.push(pts[pts.length - 1]);
  return out;
}

function circle(center, radius, segments = 16) {
  const out = [];
  for (let i = 0; i < segments; i++) {
    const a = (i / segments) * 2 * Math.PI;
    out.push(G.v(center.x + Math.cos(a) * radius, center.y + Math.sin(a) * radius));
  }
  return out;
}

/** Points on a half circle, starting at direction `from`, sweeping 180 degrees (not including the ends). */
function arc(center, radius, from, clockwise, segments = 8) {
  const start = Math.atan2(from.y, from.x);
  const out = [];
  for (let i = 1; i < segments; i++) {
    const a = start + (clockwise ? -1 : 1) * (i / segments) * Math.PI;
    out.push(G.v(center.x + Math.cos(a) * radius, center.y + Math.sin(a) * radius));
  }
  return out;
}

/** Outline from centers and widths: a round cap, one side, a round cap, the other side. */
function outlineFrom(points, ws) {
  if (!points.length) return [];
  if (points.length === 1) return circle(points[0], (ws[0] || 1) / 2);
  const n = points.length;
  const normals = new Array(n);
  for (let i = 0; i < n; i++) {
    const a = points[Math.max(0, i - 1)];
    const b = points[Math.min(n - 1, i + 1)];
    let dir = G.norm(G.sub(b, a));
    if (dir.x === 0 && dir.y === 0) dir = G.v(1, 0);
    normals[i] = G.perp(dir);
  }
  const left = new Array(n);
  const right = new Array(n);
  for (let i = 0; i < n; i++) {
    const h = ws[i] / 2;
    left[i] = G.v(points[i].x + normals[i].x * h, points[i].y + normals[i].y * h);
    right[i] = G.v(points[i].x - normals[i].x * h, points[i].y - normals[i].y * h);
  }
  const poly = left.slice();
  // End cap: half circle from left to right around the last point.
  for (const q of arc(points[n - 1], ws[n - 1] / 2, normals[n - 1], true)) poly.push(q);
  for (let i = n - 1; i >= 0; i--) poly.push(right[i]);
  // Start cap: half circle from right back to left around the first point.
  for (const q of arc(points[0], ws[0] / 2, G.v(-normals[0].x, -normals[0].y), true)) poly.push(q);
  return poly;
}

/** The filled outline of a stroke (a closed polygon). Fill it with the non-zero rule. */
function outline(points, brush, spacing = 3) {
  const pts = densify(dedupe(points), spacing);
  const n = pts.length;
  const ws = pts.map((p, i) => width(p, brush, i, n));
  return outlineFrom(pts, ws);
}

/** Centers for airbrush puffs along the stroke, with each puff's radius. */
function airbrushDabs(points, brush) {
  const pts = densify(dedupe(points), Math.max(1, brush.size / 6));
  const out = [];
  let last = null;
  const step = Math.max(1, brush.size / 5);
  for (const p of pts) {
    if (last && G.dist(last, p) < step) continue;
    last = p;
    out.push({ center: G.v(p.x, p.y), radius: Math.max(1, brush.size / 2), pressure: p.pressure });
  }
  return out;
}

/** Points of a stroke object ({ brush, pts }). */
function pointsOf(stroke) {
  return Model.unpackPoints(stroke.pts);
}

module.exports = { width, widths, alpha, densify, dedupe, outline, outlineFrom, airbrushDabs, circle, arc, pointsOf };
