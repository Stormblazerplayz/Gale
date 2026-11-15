'use strict';
// Keeps a real "<Name>.gale/project.json" folder for every hub project under Documents/Gale,
// so the drawings are plain files you can copy, back up or open on another computer.

const fs = require('fs');
const path = require('path');
const Model = require('../shared/model');
const { writeFileAtomic } = require('./store');

/** A folder name that's safe for files: letters, numbers, spaces, - and _. */
function safeName(name) {
  const cleaned = Array.from(String(name || ''))
    .map((ch) => (/[\p{L}\p{N} _-]/u.test(ch) ? ch : '-'))
    .join('')
    .trim();
  const short = Array.from(cleaned).slice(0, 60).join('').trim();
  // Windows doesn't allow these names for folders.
  if (!short || /^(con|prn|aux|nul|com\d|lpt\d)$/i.test(short)) return short ? `${short}-` : 'Untitled';
  return short;
}

class ProjectFiles {
  constructor({ store, docsDir, delay = 1500, log = () => {} }) {
    this.store = store;
    this.docsDir = docsDir;
    this.delay = delay;
    this.log = log;
    this.mapFile = path.join(store.dir, 'folders.json');
    try {
      this.folders = JSON.parse(fs.readFileSync(this.mapFile, 'utf8')) || {};
    } catch (_) {
      this.folders = {};
    }
    this.timers = new Map();
  }

  saveMap() {
    writeFileAtomic(this.mapFile, JSON.stringify(this.folders, null, 1));
  }

  /** Writes the project a little later (many quick edits make one write). */
  schedule(id) {
    clearTimeout(this.timers.get(id));
    const t = setTimeout(() => {
      this.timers.delete(id);
      this.write(id);
    }, this.delay);
    if (t.unref) t.unref();
    this.timers.set(id, t);
  }

  flushAll() {
    for (const [id, t] of this.timers) {
      clearTimeout(t);
      this.write(id);
    }
    this.timers.clear();
  }

  folderFor(id, name) {
    const want = safeName(name);
    const current = this.folders[id];
    const taken = new Set(Object.entries(this.folders).filter(([pid]) => pid !== id).map(([, f]) => f.toLowerCase()));
    if (current && current.replace(/( \d+)?\.gale$/, '') === want) return current;
    for (let n = 1; n < 1000; n++) {
      const folder = n === 1 ? `${want}.gale` : `${want} ${n}.gale`;
      const full = path.join(this.docsDir, folder);
      const ours = current && current.toLowerCase() === folder.toLowerCase();
      if (taken.has(folder.toLowerCase())) continue;
      if (!ours && fs.existsSync(full)) {
        // Someone else's folder with that name (or one from before): only reuse it if it's this project.
        try {
          const j = JSON.parse(fs.readFileSync(path.join(full, 'project.json'), 'utf8'));
          if (!j || j.id !== id) continue;
        } catch (_) {
          continue;
        }
      }
      return folder;
    }
    return `${want} ${id}.gale`;
  }

  write(id) {
    try {
      fs.mkdirSync(this.docsDir, { recursive: true });
      const log = this.store.log(id);
      if (!log) return;
      const current = this.folders[id];
      if (log.deleted) {
        if (current) this.moveToDeleted(id, current);
        return;
      }
      const project = Model.toJSON(log.toProject(id));
      const folder = this.folderFor(id, project.name);
      if (current && current !== folder) {
        const from = path.join(this.docsDir, current);
        const to = path.join(this.docsDir, folder);
        if (fs.existsSync(from) && !fs.existsSync(to)) {
          try {
            fs.renameSync(from, to);
          } catch (err) {
            this.log(`Couldn't rename ${current}: ${err.message}`);
          }
        }
      }
      this.folders[id] = folder;
      this.saveMap();
      const dir = path.join(this.docsDir, folder);
      fs.mkdirSync(path.join(dir, 'media'), { recursive: true });
      writeFileAtomic(path.join(dir, 'project.json'), JSON.stringify(project, null, 1));
      for (const m of project.media) {
        if (!m.sha256 || !m.file || m.file.includes('/') || m.file.includes('\\') || m.file.startsWith('.')) continue;
        const dest = path.join(dir, 'media', m.file);
        if (!fs.existsSync(dest) && this.store.hasBlob(m.sha256)) fs.copyFileSync(this.store.blobPath(m.sha256), dest);
      }
    } catch (err) {
      this.log(`Couldn't save project files: ${err.message}`);
    }
  }

  moveToDeleted(id, folder) {
    const from = path.join(this.docsDir, folder);
    delete this.folders[id];
    this.saveMap();
    if (!fs.existsSync(from)) return;
    const binDir = path.join(this.docsDir, 'Deleted');
    fs.mkdirSync(binDir, { recursive: true });
    let to = path.join(binDir, folder);
    for (let n = 2; fs.existsSync(to) && n < 1000; n++) to = path.join(binDir, folder.replace(/\.gale$/, ` ${n}.gale`));
    try {
      fs.renameSync(from, to);
    } catch (err) {
      this.log(`Couldn't move ${folder} to Deleted: ${err.message}`);
    }
  }

  /** Where a project's folder is (or null). */
  pathOf(id) {
    return this.folders[id] ? path.join(this.docsDir, this.folders[id]) : null;
  }
}

module.exports = { ProjectFiles, safeName };
