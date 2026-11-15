'use strict';
// The live-sync hub (spec section 4): HTTP + WebSocket on port 47820, pairing with a 6-digit code,
// a blob store, and one op log per project. Plain Node: no Electron in here, so tests can run it.

const http = require('http');
const os = require('os');
const fs = require('fs');
const crypto = require('crypto');
const { EventEmitter } = require('events');
const { WebSocketServer, WebSocket } = require('ws');
const { HubStore, hashToken } = require('./store');
const { ProjectFiles } = require('./projectFiles');
const net = require('./net');
const Hlc = require('../shared/hlc');
const { isValidOp } = require('../shared/replica');

const PROTOCOL_VERSION = 1;
const DEFAULT_PORT = 47820;
const MAX_BODY = 50 * 1024 * 1024;
const PAIR_MS = 2 * 60 * 1000;
const PAIR_TRIES = 5;
const KEEPALIVE_MS = 20 * 1000;
const DEVICE_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function sendJSON(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, 'Cache-Control': 'no-store' });
  res.end(data);
}

/** Reads a request body, refusing anything over `limit` bytes. */
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > limit) {
      reject(new HttpError(413, 'Too big (50 MB at most)'));
      req.resume();
      return;
    }
    const chunks = [];
    let size = 0;
    let failed = false;
    req.on('data', (c) => {
      if (failed) return;
      size += c.length;
      if (size > limit) {
        failed = true;
        reject(new HttpError(413, 'Too big (50 MB at most)'));
        req.resume();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      if (!failed) resolve(Buffer.concat(chunks));
    });
    req.on('error', (err) => {
      if (!failed) reject(err);
    });
  });
}

async function readJSONBody(req, limit) {
  const buf = await readBody(req, limit);
  try {
    return JSON.parse(buf.toString('utf8'));
  } catch (_) {
    throw new HttpError(400, 'Not valid JSON');
  }
}

function bearer(req) {
  const h = req.headers.authorization;
  if (typeof h === 'string' && /^Bearer\s+/i.test(h)) return h.replace(/^Bearer\s+/i, '').trim();
  return null;
}

class GaleHub extends EventEmitter {
  /**
   * @param {object} o
   * @param {string} o.dataDir   where the hub keeps its files (the app's userData folder)
   * @param {number} [o.port]    47820 (0 = any free port, for tests)
   * @param {string} [o.host]    address to listen on
   * @param {string} [o.serverName] the computer's name
   * @param {string} [o.docsDir] also write each project as <Name>.gale under this folder
   * @param {boolean} [o.announce] announce with Bonjour
   */
  constructor({ dataDir, port = DEFAULT_PORT, host = '0.0.0.0', serverName = os.hostname(), docsDir = null, announce = false, log = () => {} }) {
    super();
    this.store = new HubStore(dataDir);
    this.wantPort = port;
    this.host = host;
    this.serverName = String(serverName || 'Computer').slice(0, 63);
    this.announce = announce;
    this.log = log;
    this.files = docsDir ? new ProjectFiles({ store: this.store, docsDir, log }) : null;
    this.pairing = null;
    this.clients = new Set();
    this.localTokens = new Map(); // token hash -> { deviceId, deviceName, local: true }
    this.server = null;
    this.wss = null;
    this.bonjour = null;
    this.port = null;
  }

  get serverId() {
    return this.store.serverId;
  }

  hello() {
    return { serverId: this.serverId, serverName: this.serverName, protocolVersion: PROTOCOL_VERSION };
  }

  // ---------- start / stop ----------

  start() {
    return new Promise((resolve, reject) => {
      this.server = http.createServer((req, res) => {
        this.handle(req, res).catch((err) => {
          const status = err instanceof HttpError ? err.status : 500;
          if (status === 500) this.log(`Hub error: ${err.stack || err.message}`);
          if (!res.headersSent) sendJSON(res, status, { error: status === 500 ? 'Something went wrong' : err.message });
          else res.destroy();
        });
      });
      this.server.requestTimeout = 5 * 60 * 1000;
      this.wss = new WebSocketServer({ noServer: true, maxPayload: MAX_BODY });
      this.server.on('upgrade', (req, socket, head) => this.upgrade(req, socket, head));
      this.server.once('error', reject);
      this.server.listen(this.wantPort, this.host, () => {
        this.server.removeListener('error', reject);
        this.server.on('error', (err) => this.log(`Hub error: ${err.message}`));
        this.port = this.server.address().port;
        this.keepAlive = setInterval(() => this.ping(), KEEPALIVE_MS);
        if (this.keepAlive.unref) this.keepAlive.unref();
        if (this.announce) this.startBonjour();
        resolve(this.port);
      });
    });
  }

  startBonjour() {
    try {
      // eslint-disable-next-line global-require
      const { Bonjour } = require('bonjour-service');
      this.bonjour = new Bonjour({}, (err) => this.log(`Bonjour: ${err && err.message}`));
      const svc = this.bonjour.publish({ name: this.serverName, type: 'gale', port: this.port, txt: { id: this.serverId, v: String(PROTOCOL_VERSION) } });
      if (svc && svc.on) svc.on('error', (err) => this.log(`Bonjour: ${err.message}`));
    } catch (err) {
      this.log(`Bonjour couldn't start: ${err.message}`);
      this.bonjour = null;
    }
  }

  async stop() {
    clearInterval(this.keepAlive);
    if (this.pairing) clearTimeout(this.pairing.timer);
    if (this.bonjour) {
      const b = this.bonjour;
      this.bonjour = null;
      await new Promise((r) => {
        try {
          b.unpublishAll(() => b.destroy(() => r()));
          setTimeout(r, 1500).unref();
        } catch (_) {
          r();
        }
      });
    }
    for (const c of this.clients) c.ws.terminate();
    this.clients.clear();
    if (this.wss) this.wss.close();
    this.store.flush();
    if (this.files) this.files.flushAll();
    if (this.server) {
      await new Promise((r) => this.server.close(() => r()));
      if (this.server.closeAllConnections) this.server.closeAllConnections();
    }
  }

  // ---------- pairing ----------

  /** Makes a fresh 6-digit code that works for 2 minutes and 5 tries. */
  startPairing() {
    if (this.pairing) clearTimeout(this.pairing.timer);
    const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
    const expiresAt = Date.now() + PAIR_MS;
    const timer = setTimeout(() => this.endPairing(), PAIR_MS);
    if (timer.unref) timer.unref();
    this.pairing = { code, expiresAt, triesLeft: PAIR_TRIES, timer };
    this.emit('pairing', this.pairingInfo());
    return this.pairingInfo();
  }

  stopPairing() {
    this.endPairing();
  }

  endPairing() {
    if (!this.pairing) return;
    clearTimeout(this.pairing.timer);
    this.pairing = null;
    this.emit('pairing', this.pairingInfo());
  }

  pairingInfo() {
    const ips = net.lanAddresses();
    const host = ips.length ? ips[0].address : '127.0.0.1';
    const p = this.pairing && this.pairing.expiresAt > Date.now() ? this.pairing : null;
    const port = this.port || this.wantPort;
    const url = p
      ? `gale://pair?v=${PROTOCOL_VERSION}&host=${encodeURIComponent(host)}&port=${port}&code=${p.code}` +
        `&name=${encodeURIComponent(this.serverName)}&id=${encodeURIComponent(this.serverId)}`
      : null;
    return {
      code: p ? p.code : null,
      expiresAt: p ? p.expiresAt : null,
      triesLeft: p ? p.triesLeft : 0,
      url,
      host,
      port,
      ips,
      serverId: this.serverId,
      serverName: this.serverName,
    };
  }

  pair(body) {
    const { code, deviceId, deviceName } = body || {};
    if (typeof deviceId !== 'string' || !DEVICE_ID_RE.test(deviceId)) throw new HttpError(400, 'deviceId is missing or has odd characters');
    const name = typeof deviceName === 'string' && deviceName.trim() ? deviceName.trim().slice(0, 100) : 'Device';
    const p = this.pairing;
    if (!p || p.expiresAt <= Date.now()) throw new HttpError(403, 'No pairing code right now. Open "Pair a device" on the computer.');
    const given = Buffer.from(String(code == null ? '' : code).trim());
    const want = Buffer.from(p.code);
    const ok = given.length === want.length && crypto.timingSafeEqual(given, want);
    if (!ok) {
      p.triesLeft -= 1;
      if (p.triesLeft <= 0) {
        this.endPairing();
        throw new HttpError(403, 'Too many wrong codes. Make a new code on the computer.');
      }
      this.emit('pairing', this.pairingInfo());
      throw new HttpError(401, `Wrong code. ${p.triesLeft} ${p.triesLeft === 1 ? 'try' : 'tries'} left.`);
    }
    const token = crypto.randomBytes(32).toString('hex');
    // Pairing again replaces the old token (and drops its connections).
    if (this.store.state.devices[deviceId]) this.dropDevice(deviceId);
    this.store.addDevice(deviceId, name, token);
    this.endPairing();
    this.emit('paired', { deviceId, deviceName: name });
    this.emit('devices', this.devices());
    return { token, serverId: this.serverId, serverName: this.serverName, protocolVersion: PROTOCOL_VERSION };
  }

  /** A token for this computer's own editor window. Kept in memory only. */
  createLocalToken(deviceId, deviceName) {
    const token = crypto.randomBytes(32).toString('hex');
    this.localTokens.set(hashToken(token), { deviceId: Hlc.cleanActor(deviceId), deviceName, local: true });
    return token;
  }

  devices() {
    const online = new Set([...this.clients].map((c) => c.device.deviceId));
    return this.store
      .listDevices()
      .map((d) => ({ ...d, online: online.has(d.deviceId) }))
      .sort((a, b) => (a.pairedAt < b.pairedAt ? -1 : 1));
  }

  dropDevice(deviceId) {
    for (const c of [...this.clients]) {
      if (c.device.deviceId === deviceId && !c.device.local) c.ws.close(4001, 'Removed');
    }
  }

  removeDevice(deviceId) {
    const removed = this.store.removeDevice(deviceId);
    this.dropDevice(deviceId);
    if (removed) this.emit('devices', this.devices());
    return removed;
  }

  authenticate(token) {
    if (!token) return null;
    const local = this.localTokens.get(hashToken(token));
    if (local) return local;
    const d = this.store.deviceForToken(token);
    return d ? { deviceId: d.deviceId, deviceName: d.deviceName, local: false } : null;
  }

  // ---------- HTTP ----------

  async handle(req, res) {
    const url = new URL(req.url, 'http://hub.local');
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] !== 'api' || parts[1] !== 'v1') throw new HttpError(404, 'Not found');
    const route = parts.slice(2);
    const method = req.method;

    if (route.length === 1 && route[0] === 'hello') {
      if (method !== 'GET') throw new HttpError(405, 'Use GET');
      return sendJSON(res, 200, this.hello());
    }
    if (route.length === 1 && route[0] === 'pair') {
      if (method !== 'POST') throw new HttpError(405, 'Use POST');
      const body = await readJSONBody(req, 64 * 1024);
      return sendJSON(res, 200, this.pair(body));
    }

    const device = this.authenticate(bearer(req));
    if (!device) {
      req.resume();
      throw new HttpError(401, 'Pair this device first');
    }

    if (route[0] === 'projects') {
      if (method !== 'GET') throw new HttpError(405, 'Use GET');
      if (route.length === 1) return sendJSON(res, 200, this.store.list());
      if (route.length === 2) {
        const id = decodeURIComponent(route[1]);
        if (!HubStore.isProjectId(id)) throw new HttpError(400, 'Bad project id');
        const p = this.store.project(id);
        if (!p) throw new HttpError(404, 'No such project');
        return sendJSON(res, 200, p);
      }
    }
    if (route[0] === 'blobs' && route.length === 2) {
      const sha = route[1].toLowerCase();
      if (!HubStore.isSha(sha)) throw new HttpError(400, 'Bad sha256');
      if (method === 'PUT') return this.putBlob(req, res, sha);
      if (method === 'GET' || method === 'HEAD') return this.getBlob(req, res, sha, method === 'HEAD');
      throw new HttpError(405, 'Use GET, HEAD or PUT');
    }
    throw new HttpError(404, 'Not found');
  }

  putBlob(req, res, sha) {
    return new Promise((resolve, reject) => {
      const declared = Number(req.headers['content-length']);
      if (Number.isFinite(declared) && declared > MAX_BODY) {
        req.resume();
        reject(new HttpError(413, 'Too big (50 MB at most)'));
        return;
      }
      const tmp = `${this.store.blobPath(sha)}.${crypto.randomBytes(4).toString('hex')}.part`;
      const out = fs.createWriteStream(tmp);
      const hash = crypto.createHash('sha256');
      let size = 0;
      let failed = null;
      const fail = (err) => {
        if (failed) return;
        failed = err;
        req.unpipe(out);
        out.destroy();
        fs.unlink(tmp, () => {});
        req.resume();
        reject(err);
      };
      req.on('data', (c) => {
        size += c.length;
        if (size > MAX_BODY) return fail(new HttpError(413, 'Too big (50 MB at most)'));
        hash.update(c);
        return undefined;
      });
      req.on('error', fail);
      out.on('error', fail);
      out.on('finish', () => {
        if (failed) return;
        const got = hash.digest('hex');
        if (got !== sha) {
          fs.unlink(tmp, () => {});
          reject(new HttpError(400, 'The file doesn\'t match its sha256'));
          return;
        }
        const existed = this.store.hasBlob(sha);
        fs.rename(tmp, this.store.blobPath(sha), (err) => {
          if (err) {
            fs.unlink(tmp, () => {});
            reject(err);
            return;
          }
          sendJSON(res, existed ? 200 : 201, { sha256: sha, size });
          this.emit('blob', sha);
          resolve();
        });
      });
      req.pipe(out);
    });
  }

  getBlob(req, res, sha, headOnly) {
    let stat;
    try {
      stat = fs.statSync(this.store.blobPath(sha));
    } catch (_) {
      if (headOnly) {
        res.writeHead(404);
        res.end();
        return undefined;
      }
      throw new HttpError(404, 'No such file');
    }
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': stat.size, 'Cache-Control': 'no-store' });
    if (headOnly) {
      res.end();
      return undefined;
    }
    return new Promise((resolve) => {
      const s = fs.createReadStream(this.store.blobPath(sha));
      s.on('error', () => {
        res.destroy();
        resolve();
      });
      s.on('end', resolve);
      s.pipe(res);
    });
  }

  // ---------- WebSocket ----------

  upgrade(req, socket, head) {
    let url;
    try {
      url = new URL(req.url, 'http://hub.local');
    } catch (_) {
      socket.destroy();
      return;
    }
    const refuse = (status, text) => {
      socket.write(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
      socket.destroy();
    };
    if (url.pathname !== '/api/v1/sync') return refuse(404, 'Not Found');
    const device = this.authenticate(bearer(req) || url.searchParams.get('token'));
    if (!device) return refuse(401, 'Unauthorized');
    this.wss.handleUpgrade(req, socket, head, (ws) => this.connected(ws, device));
    return undefined;
  }

  connected(ws, device) {
    const client = { ws, device: { ...device }, subs: new Set(), alive: true, lastSeen: Date.now() };
    this.clients.add(client);
    if (!device.local) {
      this.store.touchDevice(device.deviceId);
      this.emit('devices', this.devices());
    }
    ws.on('pong', () => {
      client.alive = true;
    });
    ws.on('message', (data, isBinary) => {
      client.alive = true;
      if (isBinary) return;
      let msg;
      try {
        msg = JSON.parse(data.toString('utf8'));
      } catch (_) {
        this.send(client, { type: 'error', message: 'Not valid JSON' });
        return;
      }
      try {
        this.onMessage(client, msg);
      } catch (err) {
        this.log(`Hub message error: ${err.stack || err.message}`);
        this.send(client, { type: 'error', message: 'Something went wrong', ref: msg && msg.ref });
      }
    });
    ws.on('close', () => {
      this.clients.delete(client);
      if (!device.local) this.emit('devices', this.devices());
      if (client.lastPresence) {
        this.broadcast({ type: 'presence', deviceId: client.device.deviceId, deviceName: client.device.deviceName, p: null, frame: null, gone: true }, client);
      }
    });
    ws.on('error', () => {});
  }

  send(client, msg) {
    if (client.ws.readyState === WebSocket.OPEN) client.ws.send(JSON.stringify(msg));
  }

  /** Sends to every other client (only ones subscribed to `p` when given). */
  broadcast(msg, except, p) {
    const text = JSON.stringify(msg);
    for (const c of this.clients) {
      if (c === except) continue;
      if (p && !c.subs.has(p)) continue;
      if (c.ws.readyState === WebSocket.OPEN) c.ws.send(text);
    }
  }

  ping() {
    for (const c of [...this.clients]) {
      if (!c.alive) {
        c.ws.terminate();
        continue;
      }
      c.alive = false;
      try {
        c.ws.ping();
      } catch (_) { /* closing */ }
      this.send(c, { type: 'ping' });
    }
  }

  sendOps(client, p, since) {
    const log = this.store.log(p);
    const ops = log ? log.since(Number(since) || 0) : [];
    this.send(client, { type: 'ops', p, ops, seq: log ? log.seq : 0 });
  }

  onMessage(client, msg) {
    if (!msg || typeof msg !== 'object') return;
    switch (msg.type) {
      case 'hello': {
        if (typeof msg.deviceName === 'string' && msg.deviceName.trim()) {
          client.device.deviceName = msg.deviceName.trim().slice(0, 100);
          if (!client.device.local) this.store.touchDevice(client.device.deviceId, client.device.deviceName);
        }
        this.send(client, { type: 'welcome', ...this.hello(), projects: this.store.list() });
        const since = msg.since && typeof msg.since === 'object' ? msg.since : {};
        for (const [p, seq] of Object.entries(since)) {
          if (!HubStore.isProjectId(p)) continue;
          client.subs.add(p);
          this.sendOps(client, p, seq);
        }
        if (!client.device.local) this.emit('devices', this.devices());
        break;
      }
      case 'subscribe': {
        if (!HubStore.isProjectId(msg.p)) return this.send(client, { type: 'error', message: 'Bad project id', ref: msg.ref });
        client.subs.add(msg.p);
        this.sendOps(client, msg.p, msg.since);
        break;
      }
      case 'unsubscribe': {
        client.subs.delete(msg.p);
        break;
      }
      case 'push': {
        if (!HubStore.isProjectId(msg.p)) return this.send(client, { type: 'error', message: 'Bad project id', ref: msg.ref });
        if (!Array.isArray(msg.ops)) return this.send(client, { type: 'error', message: 'ops must be a list', ref: msg.ref });
        client.subs.add(msg.p);
        const valid = msg.ops.filter(isValidOp);
        const { won, seq, listChanged } = this.store.merge(msg.p, valid);
        const log = this.store.log(msg.p);
        this.send(client, { type: 'ack', ref: msg.ref, seq: log ? log.seq : seq });
        if (valid.length < msg.ops.length) {
          this.send(client, { type: 'error', ref: msg.ref, message: 'Some changes were not valid and were skipped', skipped: msg.ops.length - valid.length });
        }
        if (won.length) {
          const ops = won.map(({ t, a, o, k, v }) => ({ t, a, o, k, v }));
          this.broadcast({ type: 'ops', p: msg.p, ops, seq: log.seq }, client, msg.p);
          if (this.files) this.files.schedule(msg.p);
          this.emit('changed', msg.p);
        }
        if (listChanged) {
          this.broadcast({ type: 'projects', projects: this.store.list() });
          this.emit('projects', this.store.list());
        }
        break;
      }
      case 'live': {
        if (!HubStore.isProjectId(msg.p)) return undefined;
        this.broadcast({
          type: 'live',
          p: msg.p,
          frame: msg.frame,
          layer: msg.layer,
          stroke: msg.stroke,
          done: !!msg.done,
          deviceId: client.device.deviceId,
          deviceName: client.device.deviceName,
        }, client, msg.p);
        break;
      }
      case 'presence': {
        const p = HubStore.isProjectId(msg.p) ? msg.p : null;
        client.lastPresence = { p, frame: msg.frame };
        this.broadcast({
          type: 'presence',
          deviceId: client.device.deviceId,
          deviceName: client.device.deviceName,
          p,
          frame: typeof msg.frame === 'string' || typeof msg.frame === 'number' ? msg.frame : null,
        }, client);
        break;
      }
      case 'ping':
        this.send(client, { type: 'pong' });
        break;
      case 'pong':
        break;
      default:
        this.send(client, { type: 'error', message: `Unknown message type: ${String(msg.type).slice(0, 40)}`, ref: msg.ref });
    }
    return undefined;
  }
}

module.exports = { GaleHub, PROTOCOL_VERSION, DEFAULT_PORT, MAX_BODY };
