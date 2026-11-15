'use strict';
// Hybrid logical clock: "<milliseconds, 13 digits>:<counter, 5 digits>:<actor>". Compare as plain strings.

const ACTOR_RE = /^[A-Za-z0-9-]+$/;
const T_RE = /^(\d{13}):(\d{5}):([A-Za-z0-9-]+)$/;
const MAX_COUNTER = 99999;

/** Makes any text a valid actor id (letters, digits and - only). */
function cleanActor(actor) {
  const s = String(actor || '').replace(/[^A-Za-z0-9-]/g, '-').slice(0, 64);
  return s || 'device';
}

function parse(t) {
  const m = typeof t === 'string' ? T_RE.exec(t) : null;
  if (!m) return null;
  return { ms: Number(m[1]), counter: Number(m[2]), actor: m[3] };
}

function format(ms, counter, actor) {
  return `${String(ms).padStart(13, '0')}:${String(counter).padStart(5, '0')}:${actor}`;
}

class HLC {
  constructor(actor, now = () => Date.now()) {
    this.actor = cleanActor(actor);
    if (!ACTOR_RE.test(this.actor)) throw new Error('bad actor');
    this.now = now;
    this.ms = 0;
    this.counter = 0;
  }

  /** A new timestamp for a local edit. Always bigger than every one made or seen before. */
  tick() {
    const now = Math.floor(this.now());
    if (now > this.ms) {
      this.ms = now;
      this.counter = 0;
    } else {
      this.counter += 1;
      if (this.counter > MAX_COUNTER) {
        this.ms += 1;
        this.counter = 0;
      }
    }
    return format(this.ms, this.counter, this.actor);
  }

  /** Moves the clock past a timestamp that arrived from somewhere else. */
  observe(t) {
    const p = parse(t);
    if (!p) return;
    if (p.ms > this.ms) {
      this.ms = p.ms;
      this.counter = p.counter;
    } else if (p.ms === this.ms && p.counter > this.counter) {
      this.counter = p.counter;
    }
  }
}

module.exports = { HLC, parse, format, cleanActor, ACTOR_RE, T_RE };
