'use strict';
// Last-writer-wins merge of ops. For each (object, field) the op with the biggest `t` wins.
// Getting an op twice, or in any order, ends in the same state.

const Hlc = require('./hlc');
const Objects = require('./objects');
const Model = require('./model');

const MAX_ID = 200;
const MAX_FIELD = 100;

/** JSON with object keys sorted, so equal values always give equal text. */
function stableStringify(v) {
  if (v === null || typeof v !== 'object') return JSON.stringify(v === undefined ? null : v);
  if (Array.isArray(v)) return '[' + v.map(stableStringify).join(',') + ']';
  return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + stableStringify(v[k])).join(',') + '}';
}

/** Checks the shape of an op from the network. */
function isValidOp(op) {
  if (!op || typeof op !== 'object' || Array.isArray(op)) return false;
  if (typeof op.t !== 'string' || !Hlc.T_RE.test(op.t)) return false;
  if (typeof op.a !== 'string' || !Hlc.ACTOR_RE.test(op.a) || op.a.length > 64) return false;
  if (typeof op.o !== 'string' || op.o.length === 0 || op.o.length > MAX_ID) return false;
  if (typeof op.k !== 'string' || op.k.length === 0 || op.k.length > MAX_FIELD) return false;
  if (op.k === '__proto__' || op.o === '__proto__' || op.k === 'constructor' || op.k === 'prototype') return false;
  if (!('v' in op)) return false;
  return true;
}

/** True when `op` beats `current` (the op stored for the same object and field). */
function beats(op, current) {
  if (!current) return true;
  if (op.t !== current.t) return op.t > current.t;
  // Same time from a misbehaving device: pick by value so every replica picks the same one.
  return stableStringify(op.v) > stableStringify(current.v);
}

class Replica {
  constructor() {
    /** objectId -> Map(field -> op) */
    this.fields = new Map();
    /** objectId -> { field: value } (the winning values) */
    this.objs = Object.create(null);
    this.maxMs = 0;
  }

  /** Merges ops. Returns the ones that changed something (the winners). */
  apply(ops) {
    const won = [];
    for (const op of ops || []) {
      if (!isValidOp(op)) continue;
      let m = this.fields.get(op.o);
      const cur = m && m.get(op.k);
      if (!beats(op, cur)) continue;
      if (!m) {
        m = new Map();
        this.fields.set(op.o, m);
      }
      const clean = { t: op.t, a: op.a, o: op.o, k: op.k, v: op.v === undefined ? null : op.v };
      m.set(op.k, clean);
      let obj = this.objs[op.o];
      if (!obj) {
        obj = Object.create(null);
        this.objs[op.o] = obj;
      }
      obj[op.k] = clean.v;
      const p = Hlc.parse(op.t);
      if (p && p.ms > this.maxMs) this.maxMs = p.ms;
      won.push(clean);
    }
    return won;
  }

  get(objectId, field) {
    const o = this.objs[objectId];
    return o ? o[field] : undefined;
  }

  /** objectId -> { field: value }. Don't change what you get back. */
  objects() {
    return this.objs;
  }

  /** Every winning op (what a newcomer needs to catch up). */
  allOps() {
    const out = [];
    for (const m of this.fields.values()) for (const op of m.values()) out.push(op);
    return out;
  }

  get size() {
    return this.fields.size;
  }

  /** Latest edit time as an ISO date (or null when empty). */
  modified() {
    return this.maxMs ? Model.formatDate(this.maxMs) : null;
  }

  /** The project built from the objects. */
  toProject(projectId) {
    return Objects.fromObjects(this.objs, projectId, { modified: this.modified() || undefined });
  }
}

/** Turns changes ({o,k,v}) into ops with fresh clock times. */
function makeOps(changes, clock) {
  return changes.map((c) => ({ t: clock.tick(), a: clock.actor, o: c.o, k: c.k, v: c.v }));
}

module.exports = { Replica, isValidOp, beats, makeOps, stableStringify };
