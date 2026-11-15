'use strict';
// Onion skin: which nearby frames show through, and how (port of Swift's OnionSkin).

const DEFAULTS = { on: true, before: 2, after: 1, opacity: 0.5, falloff: 0.6, frosted: true, blur: 3, wrap: false };

/** Ghost tints: frames before are a cool blue, frames after a warm orange. */
const TINT_BEFORE = { r: 0.25, g: 0.55, b: 1.0, a: 1 };
const TINT_AFTER = { r: 1.0, g: 0.55, b: 0.2, a: 1 };

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/** Settings with every field filled in and in range. */
function settings(s) {
  const c = s && typeof s === 'object' ? s : {};
  const n = (v, fb) => (typeof v === 'number' && Number.isFinite(v) ? v : fb);
  const b = (v, fb) => (typeof v === 'boolean' ? v : fb);
  return {
    on: b(c.on, DEFAULTS.on),
    before: clamp(Math.round(n(c.before, DEFAULTS.before)), 0, 5),
    after: clamp(Math.round(n(c.after, DEFAULTS.after)), 0, 5),
    opacity: clamp(n(c.opacity, DEFAULTS.opacity), 0, 1),
    falloff: clamp(n(c.falloff, DEFAULTS.falloff), 0, 1),
    frosted: b(c.frosted, DEFAULTS.frosted),
    blur: Math.max(0, n(c.blur, DEFAULTS.blur)),
    wrap: b(c.wrap, DEFAULTS.wrap),
  };
}

/** Ghosts to draw, farthest first (so the nearest ends up on top). */
function ghosts(current, frameCount, s) {
  const st = settings(s);
  if (!st.on || frameCount <= 1 || current < 0 || current >= frameCount) return [];
  const out = [];
  const used = new Set([current]);
  const add = (offset, side) => {
    let idx = current + offset;
    if (st.wrap) idx = ((idx % frameCount) + frameCount) % frameCount;
    if (idx < 0 || idx >= frameCount || used.has(idx)) return;
    used.add(idx);
    const d = Math.abs(offset);
    const opacity = st.opacity * Math.pow(st.falloff, d - 1);
    const blur = st.frosted ? st.blur * (1 + 0.6 * (d - 1)) : 0;
    out.push({ frameIndex: idx, offset, opacity, blur, side, tint: side === 'before' ? TINT_BEFORE : TINT_AFTER });
  };
  // Nearest first so wrapping never lets a far ghost steal a near frame's spot.
  for (let d = 1; d <= Math.max(1, Math.max(st.before, st.after)); d++) {
    if (d <= st.before) add(-d, 'before');
    if (d <= st.after) add(d, 'after');
  }
  // Stable sort, like Swift's sorted for these inputs: farthest first.
  return out.map((g, i) => [g, i]).sort((x, y) => Math.abs(y[0].offset) - Math.abs(x[0].offset) || x[1] - y[1]).map((x) => x[0]);
}

module.exports = { DEFAULTS, TINT_BEFORE, TINT_AFTER, settings, ghosts };
