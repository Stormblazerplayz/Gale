'use strict';
// Fractional order keys: the same scheme as the "fractional-indexing" npm package by rocicorp
// and Swift's OrderKey. Sort keys as plain strings. You can always make a key between two others,
// so moving or inserting one thing never changes the keys of the rest.

const DIGITS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const ZERO = DIGITS[0];
const SMALLEST_INTEGER = 'A' + ZERO.repeat(26);
const FIRST = 'a0';

function integerLength(head) {
  if (head >= 'a' && head <= 'z') return head.charCodeAt(0) - 97 + 2;
  if (head >= 'A' && head <= 'Z') return 90 - head.charCodeAt(0) + 2;
  return null;
}

function integerPart(key) {
  if (typeof key !== 'string' || key.length === 0) return null;
  const n = integerLength(key[0]);
  if (n == null || key.length < n) return null;
  return key.slice(0, n);
}

function isValid(key) {
  if (typeof key !== 'string') return false;
  const ip = integerPart(key);
  if (ip == null) return false;
  if (key === SMALLEST_INTEGER) return false;
  for (const c of key) if (DIGITS.indexOf(c) < 0) return false;
  const frac = key.slice(ip.length);
  if (frac.length && frac[frac.length - 1] === ZERO) return false;
  return true;
}

function incrementInteger(x) {
  const head = x[0];
  const digs = x.slice(1).split('');
  let carry = true;
  for (let i = digs.length - 1; carry && i >= 0; i--) {
    const d = DIGITS.indexOf(digs[i]) + 1;
    if (d === DIGITS.length) digs[i] = ZERO;
    else { digs[i] = DIGITS[d]; carry = false; }
  }
  if (carry) {
    if (head === 'Z') return 'a' + ZERO;
    if (head === 'z') return null;
    const h = String.fromCharCode(head.charCodeAt(0) + 1);
    if (h > 'a') digs.push(ZERO);
    else digs.pop();
    return h + digs.join('');
  }
  return head + digs.join('');
}

function decrementInteger(x) {
  const head = x[0];
  const digs = x.slice(1).split('');
  let borrow = true;
  for (let i = digs.length - 1; borrow && i >= 0; i--) {
    const d = DIGITS.indexOf(digs[i]) - 1;
    if (d === -1) digs[i] = DIGITS[DIGITS.length - 1];
    else { digs[i] = DIGITS[d]; borrow = false; }
  }
  if (borrow) {
    if (head === 'a') return 'Z' + DIGITS[DIGITS.length - 1];
    if (head === 'A') return null;
    const h = String.fromCharCode(head.charCodeAt(0) - 1);
    if (h < 'Z') digs.push(DIGITS[DIGITS.length - 1]);
    else digs.pop();
    return h + digs.join('');
  }
  return head + digs.join('');
}

// The fractional part between a and b (b null = no upper bound). Neither may end in "0".
function midpoint(a, b) {
  if (b != null && a >= b) return null;
  if (b != null) {
    let n = 0;
    while (n < b.length && (a[n] || ZERO) === b[n]) n++;
    if (n > 0) {
      const m = midpoint(a.slice(n), b.slice(n));
      return m == null ? null : b.slice(0, n) + m;
    }
  }
  const digitA = a ? DIGITS.indexOf(a[0]) : 0;
  const digitB = b != null && b.length ? DIGITS.indexOf(b[0]) : DIGITS.length;
  if (digitB - digitA > 1) {
    return DIGITS[Math.round(0.5 * (digitA + digitB))];
  }
  if (b != null && b.length > 1) return b.slice(0, 1);
  const rest = midpoint(a.slice(1), null);
  return rest == null ? null : DIGITS[digitA] + rest;
}

/** The key between a and b. Pass null for "start" or "end". Returns null if the keys are broken or out of order. */
function between(a, b) {
  if (a === undefined) a = null;
  if (b === undefined) b = null;
  if (a != null && !isValid(a)) return null;
  if (b != null && !isValid(b)) return null;
  if (a != null && b != null && a >= b) return null;
  if (a == null && b == null) return FIRST;
  if (a == null) {
    const ib = integerPart(b);
    const fb = b.slice(ib.length);
    if (ib === SMALLEST_INTEGER) {
      const m = midpoint('', fb);
      return m == null ? null : ib + m;
    }
    if (ib < b) return ib;
    return decrementInteger(ib);
  }
  if (b == null) {
    const ia = integerPart(a);
    const fa = a.slice(ia.length);
    const i = incrementInteger(ia);
    if (i != null) return i;
    const m = midpoint(fa, null);
    return m == null ? null : ia + m;
  }
  const ia = integerPart(a);
  const fa = a.slice(ia.length);
  const ib = integerPart(b);
  const fb = b.slice(ib.length);
  if (ia === ib) {
    const m = midpoint(fa, fb);
    return m == null ? null : ia + m;
  }
  const i = incrementInteger(ia);
  if (i != null && i < b) return i;
  const m = midpoint(fa, null);
  return m == null ? null : ia + m;
}

/** `count` keys in order, after a (null = start) and before b (null = end). */
function keysBetween(a, b, count) {
  if (count <= 0) return [];
  const out = [];
  if (b == null) {
    let last = a;
    for (let i = 0; i < count; i++) {
      const k = between(last, null);
      if (k == null) break;
      out.push(k);
      last = k;
    }
    return out;
  }
  if (count === 1) {
    const k = between(a, b);
    return k == null ? [] : [k];
  }
  const mid = between(a, b);
  if (mid == null) return [];
  const half = Math.floor(count / 2);
  return [...keysBetween(a, mid, half), mid, ...keysBetween(mid, b, count - half - 1)];
}

/** Sort helper: by key (plain string order), then by id. */
function compare(x, y) {
  if (x.key < y.key) return -1;
  if (x.key > y.key) return 1;
  if (x.id < y.id) return -1;
  if (x.id > y.id) return 1;
  return 0;
}

module.exports = { FIRST, between, keysBetween, isValid, compare };
