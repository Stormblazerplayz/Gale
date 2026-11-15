'use strict';
// Small 2D helpers (same as Swift's Geometry.swift). Points are { x, y }.

const v = (x, y) => ({ x, y });
const add = (a, b) => v(a.x + b.x, a.y + b.y);
const sub = (a, b) => v(a.x - b.x, a.y - b.y);
const mul = (a, s) => v(a.x * s, a.y * s);
const dot = (a, b) => a.x * b.x + a.y * b.y;
const len = (a) => Math.sqrt(a.x * a.x + a.y * a.y);
const dist = (a, b) => Math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
const perp = (a) => v(-a.y, a.x);
function norm(a) {
  const l = len(a);
  return l > 1e-12 ? v(a.x / l, a.y / l) : v(0, 0);
}
const lerp = (a, b, t) => v(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);

function emptyBox() {
  return { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
}
function boxAdd(b, p) {
  if (p.x < b.minX) b.minX = p.x;
  if (p.y < b.minY) b.minY = p.y;
  if (p.x > b.maxX) b.maxX = p.x;
  if (p.y > b.maxY) b.maxY = p.y;
  return b;
}
const boxEmpty = (b) => b.minX > b.maxX || b.minY > b.maxY;
function boxInset(b, d) {
  return boxEmpty(b) ? b : { minX: b.minX + d, minY: b.minY + d, maxX: b.maxX - d, maxY: b.maxY - d };
}
const boxContains = (b, p) => p.x >= b.minX && p.x <= b.maxX && p.y >= b.minY && p.y <= b.maxY;

/** Box around a flat x, y, x, y... list. */
function boundsOfPath(path) {
  const b = emptyBox();
  for (let i = 0; i + 1 < path.length; i += 2) boxAdd(b, v(path[i], path[i + 1]));
  return b;
}

/** Even-odd point-in-polygon test. `poly` is x, y, x, y... */
function contains(poly, p) {
  const n = Math.floor(poly.length / 2);
  if (n < 3) return false;
  let inside = false;
  let j = n - 1;
  for (let i = 0; i < n; i++) {
    const xi = poly[2 * i], yi = poly[2 * i + 1];
    const xj = poly[2 * j], yj = poly[2 * j + 1];
    if ((yi > p.y) !== (yj > p.y)) {
      const x = ((xj - xi) * (p.y - yi)) / (yj - yi) + xi;
      if (p.x < x) inside = !inside;
    }
    j = i;
  }
  return inside;
}

function distanceToSegment(p, a, b) {
  const ab = sub(b, a);
  const l2 = dot(ab, ab);
  if (l2 < 1e-12) return dist(p, a);
  const t = Math.max(0, Math.min(1, dot(sub(p, a), ab) / l2));
  return dist(p, add(a, mul(ab, t)));
}

/** Shortest distance from p to the outline of a closed polygon. */
function distanceToOutline(poly, p) {
  const n = Math.floor(poly.length / 2);
  if (n < 2) return Infinity;
  let best = Infinity;
  for (let i = 0; i < n; i++) {
    const j = (i + 1) % n;
    best = Math.min(best, distanceToSegment(p, v(poly[2 * i], poly[2 * i + 1]), v(poly[2 * j], poly[2 * j + 1])));
  }
  return best;
}

module.exports = {
  v, add, sub, mul, dot, len, dist, perp, norm, lerp,
  emptyBox, boxAdd, boxEmpty, boxInset, boxContains, boundsOfPath, contains, distanceToSegment, distanceToOutline,
};
