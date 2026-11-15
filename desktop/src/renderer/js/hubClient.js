'use strict';
// The editor talks to this computer's hub like any other device: over the same WebSocket protocol.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const MAX_OPS_PER_PUSH = 4000;

  class HubClient {
    constructor({ port, token, deviceId, deviceName }) {
      this.port = port;
      this.token = token;
      this.deviceId = deviceId;
      this.deviceName = deviceName;
      this.ws = null;
      this.connected = false;
      this.projects = [];
      this.subs = new Map(); // project id -> last seq we have
      this.pending = new Map(); // ref -> { p, ops }
      this.refCounter = 0;
      this.handlers = {};
      this.retry = 500;
      this.presence = null;
    }

    on(type, fn) {
      (this.handlers[type] = this.handlers[type] || []).push(fn);
      return () => {
        this.handlers[type] = this.handlers[type].filter((f) => f !== fn);
      };
    }

    emit(type, data) {
      for (const fn of this.handlers[type] || []) {
        try {
          fn(data);
        } catch (err) {
          console.error(err);
        }
      }
    }

    connect() {
      const ws = new WebSocket(`ws://127.0.0.1:${this.port}/api/v1/sync?token=${encodeURIComponent(this.token)}`);
      this.ws = ws;
      ws.onopen = () => {
        this.retry = 500;
        this.connected = true;
        const since = {};
        for (const [p, seq] of this.subs) since[p] = seq;
        this.raw({ type: 'hello', deviceId: this.deviceId, deviceName: this.deviceName, since });
        // Anything not yet saved goes again (ops are safe to send twice).
        for (const [ref, item] of this.pending) this.raw({ type: 'push', p: item.p, ops: item.ops, ref });
        if (this.presence) this.raw(this.presence);
        this.emit('status', true);
      };
      ws.onmessage = (e) => {
        let msg;
        try {
          msg = JSON.parse(e.data);
        } catch (_) {
          return;
        }
        this.handle(msg);
      };
      ws.onclose = () => {
        if (this.ws !== ws) return;
        this.connected = false;
        this.emit('status', false);
        setTimeout(() => this.connect(), this.retry);
        this.retry = Math.min(5000, this.retry * 2);
      };
      ws.onerror = () => {};
      clearInterval(this.pinger);
      this.pinger = setInterval(() => this.raw({ type: 'ping' }), 20000);
    }

    raw(msg) {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify(msg));
        return true;
      }
      return false;
    }

    handle(msg) {
      switch (msg.type) {
        case 'welcome':
          this.projects = Array.isArray(msg.projects) ? msg.projects : [];
          this.emit('projects', this.projects);
          break;
        case 'projects':
          this.projects = Array.isArray(msg.projects) ? msg.projects : [];
          this.emit('projects', this.projects);
          break;
        case 'ops':
          if (this.subs.has(msg.p)) {
            this.subs.set(msg.p, Math.max(this.subs.get(msg.p) || 0, Number(msg.seq) || 0));
            this.emit('ops', msg);
          }
          break;
        case 'ack': {
          const item = this.pending.get(msg.ref);
          this.pending.delete(msg.ref);
          if (item && this.subs.has(item.p)) this.subs.set(item.p, Math.max(this.subs.get(item.p) || 0, Number(msg.seq) || 0));
          this.emit('saved', this.pending.size);
          break;
        }
        case 'live':
          this.emit('live', msg);
          break;
        case 'presence':
          this.emit('presence', msg);
          break;
        case 'ping':
          this.raw({ type: 'pong' });
          break;
        case 'error':
          console.warn('Hub:', msg.message);
          break;
        default:
          break;
      }
    }

    subscribe(p) {
      this.subs.set(p, 0);
      this.raw({ type: 'subscribe', p, since: 0 });
    }

    unsubscribe(p) {
      this.subs.delete(p);
      this.raw({ type: 'unsubscribe', p });
    }

    /** Sends local edits. Big batches go in parts. */
    push(p, ops) {
      for (let i = 0; i < ops.length; i += MAX_OPS_PER_PUSH) {
        const part = ops.slice(i, i + MAX_OPS_PER_PUSH);
        const ref = `r${++this.refCounter}`;
        this.pending.set(ref, { p, ops: part });
        this.raw({ type: 'push', p, ops: part, ref });
      }
      this.emit('saved', this.pending.size);
    }

    /** Waits until every push so far has been saved by the hub. */
    flushed(timeoutMs = 10000) {
      if (this.pending.size === 0) return Promise.resolve(true);
      return new Promise((resolve) => {
        const off = this.on('saved', (n) => {
          if (n === 0) {
            off();
            clearTimeout(t);
            resolve(true);
          }
        });
        const t = setTimeout(() => {
          off();
          resolve(false);
        }, timeoutMs);
      });
    }

    live(msg) {
      this.raw({ type: 'live', ...msg });
    }

    setPresence(p, frame) {
      this.presence = { type: 'presence', deviceId: this.deviceId, deviceName: this.deviceName, p, frame };
      this.raw(this.presence);
    }

    /** The project as project.json, read from the hub. */
    async fetchProject(id) {
      const res = await fetch(`http://127.0.0.1:${this.port}/api/v1/projects/${encodeURIComponent(id)}`, {
        headers: { Authorization: `Bearer ${this.token}` },
      });
      if (!res.ok) throw new Error(`Couldn't read the drawing (${res.status})`);
      return res.json();
    }
  }

  Gale.HubClient = HubClient;
})();
