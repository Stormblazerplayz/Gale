'use strict';
// Automatic hair sway (port of Swift's HairSway). Roots stay put, tips swing the most, with wind and gusts.

const G = require('./geometry');

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

function frameOf(region) {
  if (!region.root || region.root.length < 4 || !region.polygon || region.polygon.length < 6) return null;
  const a = G.v(region.root[0], region.root[1]);
  const b = G.v(region.root[2], region.root[3]);
  let along = G.norm(G.sub(b, a));
  if (along.x === 0 && along.y === 0) along = G.v(1, 0);
  let out = G.perp(along);
  const poly = region.polygon;
  const n = Math.floor(poly.length / 2);
  let c = G.v(0, 0);
  for (let i = 0; i < n; i++) c = G.add(c, G.v(poly[2 * i], poly[2 * i + 1]));
  c = G.mul(c, 1 / n);
  const mid = G.mul(G.add(a, b), 0.5);
  if (G.dot(G.sub(c, mid), out) < 0) out = G.v(-out.x, -out.y);
  let length = 0;
  for (let i = 0; i < n; i++) length = Math.max(length, G.dot(G.sub(G.v(poly[2 * i], poly[2 * i + 1]), a), out));
  if (!(length > 1)) return null;
  return { origin: a, along, out, length };
}

/** Sways per second, after stiffness (stiff hair moves faster and less). */
function frequency(region) {
  return Math.max(0.05, region.speed) * (0.6 + 0.8 * clamp(region.stiffness, 0, 1));
}

function period(region) {
  return 1 / frequency(region);
}

/** Biggest sideways swing at the very tip, in pixels. */
function amplitude(region, length) {
  return length * 0.2 * (1 - 0.82 * clamp(region.stiffness, 0, 1));
}

function wave(u, t, region) {
  const w = 2 * Math.PI * frequency(region);
  const lag = 2.4 * u;
  const main = Math.sin(w * t - lag);
  const g = clamp(region.gust, 0, 1);
  const gusts = g * (0.45 * Math.sin(2 * w * t - 1.7 * lag + 1.3) + 0.25 * Math.sin(3 * w * t - 2.3 * lag + 0.4));
  const wind = clamp(region.wind, -1, 1) * 0.9;
  return wind + main * (1 - 0.35 * Math.abs(wind)) + gusts;
}

/** Moves points that are in the hair region. Points outside stay, with a soft edge so lines don't tear. */
function deform(points, region, time, feather = 18) {
  if (!region.on) return points;
  const f = frameOf(region);
  if (!f) return points;
  const box = G.boxInset(G.boundsOfPath(region.polygon), -feather);
  const amp = amplitude(region, f.length);
  return points.map((p) => {
    if (!G.boxContains(box, p)) return p;
    let weight = 1;
    if (!G.contains(region.polygon, p)) {
      const d = G.distanceToOutline(region.polygon, p);
      if (d >= feather) return p;
      weight = 1 - d / feather;
    }
    const u = clamp(G.dot(G.sub(p, f.origin), f.out) / f.length, 0, 1);
    const side = amp * Math.pow(u, 1.6) * wave(u, time, region) * weight;
    const lift = (-(side * side) / (2 * f.length)) * u;
    return { ...p, x: p.x + f.along.x * side + f.out.x * lift, y: p.y + f.along.y * side + f.out.y * lift };
  });
}

/** The regions that act on a layer. */
function regionsFor(project, layerId) {
  return project.hair.filter((h) => h.on && h.layer === layerId);
}

module.exports = { frameOf, frequency, period, amplitude, wave, deform, regionsFor };
