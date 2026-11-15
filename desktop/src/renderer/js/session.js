'use strict';
// One open project: its ops (a replica of the hub's), the project built from them, and undo/redo.
// Every edit is a whole new project; the diff against the replica becomes one op per changed field.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { Objects, Replica: R, Hlc } = window.GaleShared;
  const UNDO_LIMIT = 100;

  class ProjectSession {
    constructor(client, projectId) {
      this.client = client;
      this.id = projectId;
      this.replica = new R.Replica();
      this.clock = new Hlc.HLC(client.deviceId);
      this.project = null;
      this.loaded = false;
      this.undoStack = [];
      this.redoStack = [];
      this.listeners = [];
      /** "frameId|layerId" -> number that goes up whenever that cel's drawing changes. */
      this.celVersions = new Map();
      this.allVersion = 0;
      this.offOps = client.on('ops', (msg) => {
        if (msg.p === this.id) this.receive(msg.ops || []);
      });
      client.subscribe(projectId);
    }

    close() {
      this.offOps();
      this.client.unsubscribe(this.id);
      this.listeners = [];
    }

    onChange(fn) {
      this.listeners.push(fn);
    }

    changed(info) {
      for (const fn of this.listeners) fn(info);
    }

    celVersion(frameId, layerId) {
      return `${this.allVersion}.${this.celVersions.get(`${frameId}|${layerId}`) || 0}`;
    }

    /** Notes which cels an op touches, so only those get redrawn. */
    touch(op, before) {
      const o = this.replica.objs[op.o];
      const type = (o && o.$type) || (before && before.$type);
      if (type !== 'stroke' && type !== 'fill') return;
      if (op.k === 'frame' || op.k === 'layer') {
        this.allVersion += 1;
        return;
      }
      const f = o && o.frame;
      const l = o && o.layer;
      if (typeof f === 'string' && typeof l === 'string') {
        const key = `${f}|${l}`;
        this.celVersions.set(key, (this.celVersions.get(key) || 0) + 1);
      }
    }

    applyOps(ops) {
      const won = this.replica.apply(ops);
      for (const op of won) this.touch(op);
      return won;
    }

    rebuild() {
      this.project = this.replica.toProject(this.id);
    }

    receive(ops) {
      for (const op of ops) this.clock.observe(op.t);
      const won = this.applyOps(ops);
      const first = !this.loaded;
      this.loaded = true;
      if (won.length || first) {
        this.rebuild();
        this.changed({ remote: true, first, ops: won });
      }
    }

    /** Saves a new version of the project. Returns false when nothing changed. */
    commit(next, { undoable = true } = {}) {
      const objs = this.replica.objects();
      const changes = Objects.diff(objs, Objects.toObjects(next));
      if (!changes.length) return false;
      if (undoable) {
        this.undoStack.push(this.inverse(changes, objs));
        if (this.undoStack.length > UNDO_LIMIT) this.undoStack.shift();
        this.redoStack = [];
      }
      this.send(changes);
      return true;
    }

    send(changes) {
      const ops = R.makeOps(changes, this.clock);
      this.applyOps(ops);
      this.client.push(this.id, ops);
      this.rebuild();
      this.changed({ remote: false, ops });
    }

    /** What undoes `changes`, and what does them again. */
    inverse(changes, objs) {
      const back = [];
      const fwd = [];
      const fresh = new Set();
      for (const c of changes) {
        const o = objs[c.o];
        const isNew = !o || o.$del === true;
        if (isNew) {
          if (!fresh.has(c.o)) {
            fresh.add(c.o);
            back.push({ o: c.o, k: '$del', v: true });
          }
        } else if (c.k === '$del') {
          back.push({ o: c.o, k: '$del', v: c.v ? false : true });
        } else {
          back.push({ o: c.o, k: c.k, v: o[c.k] === undefined ? null : o[c.k] });
        }
        // A new object keeps its fields while undone (deleting only sets $del), so redo just brings it back.
        if (!isNew) fwd.push(c);
      }
      for (const id of fresh) fwd.push({ o: id, k: '$del', v: false });
      return { back, fwd };
    }

    get canUndo() {
      return this.undoStack.length > 0;
    }

    get canRedo() {
      return this.redoStack.length > 0;
    }

    undo() {
      const e = this.undoStack.pop();
      if (!e) return false;
      this.redoStack.push(e);
      this.send(e.back);
      return true;
    }

    redo() {
      const e = this.redoStack.pop();
      if (!e) return false;
      this.undoStack.push(e);
      this.send(e.fwd);
      return true;
    }
  }

  Gale.ProjectSession = ProjectSession;
})();
