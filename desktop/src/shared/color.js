'use strict';
// Colors are "#RRGGBBAA" strings (alpha last). Readers also accept "#RGB" and "#RRGGBB" (the # is optional).

function clamp01(v) {
  return Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0;
}

/** Reads a hex color into { r, g, b, a } from 0 to 1. Returns null for anything that isn't a color. */
function parse(hex) {
  if (typeof hex !== 'string') return null;
  let s = hex.trim();
  if (s.startsWith('#')) s = s.slice(1);
  if (s.length === 3) s = s.split('').map((c) => c + c).join('');
  if (s.length === 6) s += 'FF';
  if (!/^[0-9a-fA-F]{8}$/.test(s)) return null;
  const v = parseInt(s, 16) >>> 0;
  return {
    r: ((v >>> 24) & 0xff) / 255,
    g: ((v >>> 16) & 0xff) / 255,
    b: ((v >>> 8) & 0xff) / 255,
    a: (v & 0xff) / 255,
  };
}

function byte(v) {
  const n = Math.round(clamp01(v) * 255);
  return n.toString(16).toUpperCase().padStart(2, '0');
}

/** { r, g, b, a } (0-1) to "#RRGGBBAA". */
function toHex(c) {
  return '#' + byte(c.r) + byte(c.g) + byte(c.b) + byte(c.a == null ? 1 : c.a);
}

/** Any accepted color string to "#RRGGBBAA", or the fallback when it isn't a color. */
function normalize(hex, fallback = '#000000FF') {
  const c = parse(hex);
  return c ? toHex(c) : fallback;
}

/** A CSS color, with the alpha multiplied by `alphaScale`. */
function toCss(hex, alphaScale = 1) {
  const c = parse(hex) || { r: 0, g: 0, b: 0, a: 1 };
  const a = clamp01(c.a * alphaScale);
  return `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${+a.toFixed(4)})`;
}

/** "#RRGGBB" for an <input type=color>. */
function toInputValue(hex) {
  return normalize(hex).slice(0, 7).toLowerCase();
}

/** Same color with a new alpha. */
function withAlpha(hex, a) {
  const c = parse(hex) || { r: 0, g: 0, b: 0, a: 1 };
  return toHex({ ...c, a });
}

module.exports = { parse, toHex, normalize, toCss, toInputValue, withAlpha, clamp01, BLACK: '#000000FF', WHITE: '#FFFFFFFF' };
