'use strict';
// Everything the hub keeps on disk, as plain JSON files (no database, so Windows builds stay simple):
//
//   <dir>/state.json          server id and paired devices (only a hash of each token is kept)
//   <dir>/projects/<id>.json  each project's winning ops, with their seq numbers
//   <dir>/blobs/<sha256>      media files, named by their hash

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Replica } = require('../shared/replica');
const Objects = require('../shared/objects');
const Model = require('../shared/model');

const PROJECT_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const SHA_RE = /^[0-9a-f]{64}$/;

function writeFileAtomic(file, data) {
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(tmp, data);
  try {
    fs.renameSync(tmp, file);
  } catch (err) {
    // Windows can refuse to replace a file another program has open for a moment. Write it in place instead.
    try {
      fs.writeFileSync(file, data);
    } finally {
      try { fs.unlinkSync(tmp); } catch (_) { /* already gone */ }
    }
  }
}

function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

const hashToken = (token) => crypto.createHash('sha256').update(String(token)).digest('hex');

/** One project's ops. Keeps only the winning op per (object, field), each with the seq it was accepted at. */
class ProjectLog extends Replica {
  constructor(id) {
    super();
    this.id = id;
    this.seq = 0;
  }

  /** Merges ops; returns the winners (with their new seq numbers). */
  merge(ops) {
    const won = this.apply(ops);
    for (const op of won) op.seq = ++this.seq;
    return won;
  }

  /** Winning ops accepted after `since`, oldest first, without the seq field. */
  since(since) {
    const s = Number.isFinite(since) ? since : 0;
    const out = [];
    for (const m of this.fields.values()) {
      for (const op of m.values()) if (op.seq > s) out.push(op);
    }
    out.sort((a, b) => a.seq - b.seq);
    return out.map(({ t, a, o, k, v }) => ({ t, a, o, k, v }));
  }

  get deleted() {
    return Objects.isDeleted(this.objs, this.id);
  }

  get name() {
    const n = this.get(this.id, 'name');
    return typeof n === 'string' ? n : 'Untitled';
  }

  summary() {
    return { id: this.id, name: this.name, modified: this.modified() || Model.formatDate(Date.now()), seq: this.seq };
  }

  toJSON() {
    const ops = [];
    for (const m of this.fields.values()) for (const op of m.values()) ops.push([op.t, op.a, op.o, op.k, op.v, op.seq]);
    ops.sort((x, y) => x[5] - y[5]);
    return { format: 'gale-hub-project/1', id: this.id, seq: this.seq, ops };
  }

  static fromJSON(json) {
    const log = new ProjectLog(json.id);
    let top = Number(json.seq) || 0;
    for (const row of Array.isArray(json.ops) ? json.ops : []) {
      if (!Array.isArray(row)) continue;
      const [t, a, o, k, v, seq] = row;
      const [op] = log.apply([{ t, a, o, k, v }]);
      const s = Number(seq) || 0;
      if (op) op.seq = s;
      if (s > top) top = s;
    }
    log.seq = top;
    return log;
  }
}

class HubStore {
  constructor(dir) {
    this.dir = dir;
    this.projectsDir = path.join(dir, 'projects');
    this.blobsDir = path.join(dir, 'blobs');
    fs.mkdirSync(this.projectsDir, { recursive: true });
    fs.mkdirSync(this.blobsDir, { recursive: true });
    this.stateFile = path.join(dir, 'state.json');
    const state = readJSON(this.stateFile, {});
    this.state = {
      serverId: typeof state.serverId === 'string' && /^[a-z0-9]{8,64}$/.test(state.serverId) ? state.serverId : Model.makeId(),
      devices: state.devices && typeof state.devices === 'object' ? state.devices : {},
    };
    this.projects = new Map();
    for (const file of fs.readdirSync(this.projectsDir)) {
      if (!file.endsWith('.json')) continue;
      const json = readJSON(path.join(this.projectsDir, file), null);
      if (json && typeof json.id === 'string' && PROJECT_ID_RE.test(json.id)) {
        this.projects.set(json.id, ProjectLog.fromJSON(json));
      }
    }
    this.dirty = new Set();
    this.timer = null;
    this.saveState();
  }

  get serverId() {
    return this.state.serverId;
  }

  // ---------- devices ----------

  saveState() {
    writeFileAtomic(this.stateFile, JSON.stringify(this.state, null, 1));
  }

  addDevice(deviceId, deviceName, token) {
    this.state.devices[deviceId] = {
      deviceId,
      deviceName,
      tokenHash: hashToken(token),
      pairedAt: new Date().toISOString(),
      lastSeen: new Date().toISOString(),
    };
    this.saveState();
  }

  removeDevice(deviceId) {
    if (!this.state.devices[deviceId]) return false;
    delete this.state.devices[deviceId];
    this.saveState();
    return true;
  }

  deviceForToken(token) {
    if (typeof token !== 'string' || token.length < 16 || token.length > 200) return null;
    const h = Buffer.from(hashToken(token), 'hex');
    for (const d of Object.values(this.state.devices)) {
      const other = Buffer.from(d.tokenHash || '', 'hex');
      if (other.length === h.length && crypto.timingSafeEqual(other, h)) return d;
    }
    return null;
  }

  touchDevice(deviceId, deviceName) {
    const d = this.state.devices[deviceId];
    if (!d) return;
    d.lastSeen = new Date().toISOString();
    if (typeof deviceName === 'string' && deviceName.trim()) d.deviceName = deviceName.trim().slice(0, 100);
    this.saveState();
  }

  listDevices() {
    return Object.values(this.state.devices).map(({ deviceId, deviceName, pairedAt, lastSeen }) => ({ deviceId, deviceName, pairedAt, lastSeen }));
  }

  // ---------- projects ----------

  static isProjectId(id) {
    return typeof id === 'string' && PROJECT_ID_RE.test(id);
  }

  log(id) {
    return this.projects.get(id) || null;
  }

  /** Merges pushed ops. Returns the winners, the new seq and whether the project list changed. */
  merge(id, ops) {
    let log = this.projects.get(id);
    const isNew = !log;
    if (!log) log = new ProjectLog(id);
    const before = { name: log.name, deleted: log.deleted };
    const won = log.merge(ops);
    if (isNew && won.length === 0) return { won, seq: 0, listChanged: false };
    if (isNew) this.projects.set(id, log);
    if (won.length) this.markDirty(id);
    const listChanged = isNew || before.name !== log.name || before.deleted !== log.deleted;
    return { won, seq: log.seq, listChanged };
  }

  /** Projects that aren't deleted, newest first. */
  list() {
    const out = [];
    for (const log of this.projects.values()) if (!log.deleted) out.push(log.summary());
    out.sort((a, b) => (a.modified < b.modified ? 1 : a.modified > b.modified ? -1 : 0));
    return out;
  }

  /** The project as project.json, or null when there's no such project. */
  project(id) {
    const log = this.projects.get(id);
    if (!log || log.deleted) return null;
    return Model.toJSON(log.toProject(id));
  }

  markDirty(id) {
    this.dirty.add(id);
    if (!this.timer) {
      this.timer = setTimeout(() => this.flush(), 400);
      if (this.timer.unref) this.timer.unref();
    }
  }

  flush() {
    clearTimeout(this.timer);
    this.timer = null;
    for (const id of this.dirty) {
      const log = this.projects.get(id);
      if (log) writeFileAtomic(path.join(this.projectsDir, `${id}.json`), JSON.stringify(log.toJSON()));
    }
    this.dirty.clear();
  }

  // ---------- blobs ----------

  static isSha(s) {
    return typeof s === 'string' && SHA_RE.test(s);
  }

  blobPath(sha) {
    return path.join(this.blobsDir, sha);
  }

  hasBlob(sha) {
    try {
      return fs.statSync(this.blobPath(sha)).isFile();
    } catch (_) {
      return false;
    }
  }
}

module.exports = { HubStore, ProjectLog, writeFileAtomic, hashToken, PROJECT_ID_RE };
