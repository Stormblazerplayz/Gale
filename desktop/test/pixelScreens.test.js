'use strict';
// The desktop pixel editor screens, driven end to end in a small fake browser (test/fakeDom.js):
// drawing tools, frames, scenes, the storyboard, the player, settings, export and the home screen.
const { test } = require('node:test');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const { makeDocument } = require('./fakeDom');

const ROOT = path.join(__dirname, '..', 'src');
const Shared = require(path.join(ROOT, 'shared/index.js'));
const { Model, Objects, Replica, Hlc, Pixel, PixelGif } = Shared;

/** Checks that pictures handed to a canvas are the right size, like a browser does. */
class ImageData {
  constructor(data, w, h) {
    if (!(data instanceof Uint8ClampedArray)) throw new Error('ImageData wants Uint8ClampedArray');
    if (data.length !== w * h * 4) throw new Error(`ImageData size mismatch ${data.length} vs ${w}x${h}`);
    this.data = data;
    this.width = w;
    this.height = h;
  }
}

test('pixel editor: draw, frames, scenes, storyboard, player, settings, export', async () => {
  const doc = makeDocument();
  let rafQ = [];
  let now = 1000;
  const store = {};
  const saved = [];
  const written = [];
  const ctx = {
    document: doc,
    console,
    ImageData,
    Uint8Array,
    Uint8ClampedArray,
    Map,
    Set,
    WeakMap,
    Promise,
    Math,
    JSON,
    Date,
    Number,
    String,
    Array,
    Object,
    Error,
    RegExp,
    Symbol,
    Intl,
    TextEncoder,
    setTimeout,
    clearTimeout,
    performance: { now: () => now },
    requestAnimationFrame: (fn) => {
      rafQ.push(fn);
      return rafQ.length;
    },
    cancelAnimationFrame: () => {},
    ResizeObserver: class {
      observe() {}
    },
    localStorage: {
      getItem: (k) => store[k] || null,
      setItem: (k, v) => {
        store[k] = String(v);
      },
    },
    devicePixelRatio: 1,
    listeners: {},
  };
  ctx.window = ctx;
  ctx.addEventListener = (t, fn) => {
    (ctx.listeners[t] = ctx.listeners[t] || []).push(fn);
  };
  ctx.GaleShared = Shared;
  ctx.galeAPI = {
    saveFile: async (o) => {
      saved.push(o);
      return `/fake/${o.name}`;
    },
    pickFolder: async () => ({ id: 0, path: '/fake' }),
    writeInFolder: async (o) => {
      if (!/^[\p{L}\p{N} _.-]{1,120}\.(png|json)$/u.test(o.name)) throw new Error(`Bad file name ${o.name}`);
      written.push(o);
      return true;
    },
  };
  vm.createContext(ctx);
  for (const f of ['ui.js', 'session.js', 'exporter.js', 'pixelEditor.js']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, 'renderer/js', f), 'utf8'), ctx, { filename: f });
  }
  const Gale = ctx.Gale;
  const flush = (ms = 16, rounds = 1) => {
    for (let r = 0; r < rounds; r++) {
      now += ms;
      const q = rafQ;
      rafQ = [];
      for (const fn of q) fn(now);
    }
  };
  const key = (k, extra = {}) => {
    for (const fn of ctx.listeners.keydown || [])
      fn({ key: k, target: doc.body, preventDefault() {}, ctrlKey: false, metaKey: false, shiftKey: false, altKey: false, ...extra });
  };

  // ----- a fake hub client -----
  class FakeClient {
    constructor() {
      this.deviceId = 'dev1';
      this.connected = true;
      this.pending = new Set();
      this.handlers = {};
      this.logs = {};
      this.projects = [];
      this.pushed = [];
    }
    on(t, fn) {
      (this.handlers[t] = this.handlers[t] || []).push(fn);
      return () => {
        this.handlers[t] = this.handlers[t].filter((f) => f !== fn);
      };
    }
    emit(t, m) {
      for (const fn of this.handlers[t] || []) fn(m);
    }
    subscribe(id) {
      this.waiting = id;
    }
    deliver() {
      const id = this.waiting;
      this.waiting = null;
      if (id) this.emit('ops', { p: id, ops: (this.logs[id] || []).slice() });
    }
    unsubscribe() {}
    push(id, ops) {
      (this.logs[id] = this.logs[id] || []).push(...ops);
      this.pushed.push(...ops);
    }
    setPresence() {}
  }
  const client = new FakeClient();
  const clock = new Hlc.HLC('hub');
  const p0 = Model.newPixelProject({ name: 'Frog Tale', width: 16, height: 12, paletteName: 'PICO-8' });
  client.logs[p0.id] = Replica.makeOps(Objects.diff({}, Objects.toObjects(p0)), clock);
  client.projects = [{ id: p0.id, name: p0.name, pixel: true }];

  Gale.pixelEditor.init();
  Gale.pixelEditor.attach(client);
  let closed = 0;
  Gale.pixelEditor.open(client, p0.id, () => {
    closed += 1;
  });
  client.deliver();
  flush(16, 2);
  const view = doc.getElementById('px-view');
  assert.ok(Gale.pixelEditor.isOpen);
  assert.strictEqual(doc.getElementById('px-name').textContent, 'Frog Tale');
  assert.strictEqual(doc.getElementById('px-size').textContent, '16×12');
  assert.strictEqual(doc.getElementById('px-msg').hidden, true);
  assert.ok(view.ctx.calls.includes('drawImage'), 'drew the canvas');
  assert.strictEqual(doc.getElementById('px-palette').children.length, 16 + 1, '16 swatches + add');
  assert.strictEqual(doc.getElementById('px-frames').children.length, 1);

  // Rebuild the project from everything pushed, like another device would.
  function remote() {
    const r = new Replica.Replica();
    r.apply(client.logs[p0.id]);
    return r.toProject(p0.id);
  }

  // zoom: 800x600 stage, 16x12 grid → z = floor(min(752/16, 552/12)) = 46 → clamp 46 (max 64)
  const z = Math.floor(Math.min(752 / 16, 552 / 12));
  const ox = Math.round((800 - 16 * z) / 2);
  const oy = Math.round((600 - 12 * z) / 2);
  assert.strictEqual(doc.getElementById('px-zoom').textContent, `${z}×`);
  const at = (x, y) => ({ clientX: ox + x * z + z / 2, clientY: oy + y * z + z / 2, pointerId: 1, button: 0 });

  // pencil a line from (1,1) to (4,1)
  view.dispatch('pointerdown', at(1, 1));
  view.dispatch('pointermove', at(4, 1));
  view.dispatch('pointerup', at(4, 1));
  let st = remote().pixel;
  let cells = st.scenes[0].frames[0].cells;
  assert.deepStrictEqual(
    [1, 2, 3, 4].map((x) => cells[1 * 16 + x]),
    [1, 1, 1, 1],
    'pencil line synced',
  );
  assert.strictEqual(cells[1 * 16 + 5], 0);

  // pick color 8 (key), rect tool (R), filled box
  key('8');
  key('r');
  doc
    .getElementById('px-tools')
    .all()
    .find((b) => b.textContent === '■ Filled')
    .click();
  view.dispatch('pointerdown', at(6, 4));
  view.dispatch('pointermove', at(8, 6));
  view.dispatch('pointerup', at(8, 6));
  st = remote().pixel;
  cells = st.scenes[0].frames[0].cells;
  assert.strictEqual(cells[5 * 16 + 7], 8, 'filled rect');

  // fill tool on empty area with color 12
  key('g');
  doc.getElementById('px-palette').children[11].click(); // color 12
  view.dispatch('pointerdown', at(0, 11));
  st = remote().pixel;
  cells = st.scenes[0].frames[0].cells;
  assert.strictEqual(cells[11 * 16 + 0], 12, 'fill');
  assert.strictEqual(cells[1 * 16 + 1], 1, 'fill keeps the line');

  // eraser via right click
  key('b');
  view.dispatch('pointerdown', { ...at(2, 1), button: 2 });
  view.dispatch('pointerup', { ...at(2, 1), button: 2 });
  assert.strictEqual(remote().pixel.scenes[0].frames[0].cells[1 * 16 + 2], 0, 'right click erases');

  // picker with alt
  view.dispatch('pointerdown', { ...at(7, 5), altKey: true });
  assert.ok(doc.getElementById('px-palette').children[7].classList.contains('on'), 'alt-click picked color 8');

  // undo / redo
  const before = remote().pixel.scenes[0].frames[0].cells.slice();
  key('z', { ctrlKey: true });
  assert.strictEqual(remote().pixel.scenes[0].frames[0].cells[1 * 16 + 2], 1, 'undo brings pixel back');
  key('y', { ctrlKey: true });
  assert.deepStrictEqual(remote().pixel.scenes[0].frames[0].cells, before, 'redo');

  // frames: copy (D), new (N), hold, fps, move, delete
  key('d');
  assert.strictEqual(remote().pixel.scenes[0].frames.length, 2);
  assert.deepStrictEqual(remote().pixel.scenes[0].frames[1].cells, before, 'copy keeps cells');
  key('n');
  assert.strictEqual(remote().pixel.scenes[0].frames.length, 3);
  assert.strictEqual(
    remote().pixel.scenes[0].frames[2].cells.every((v) => v === 0),
    true,
    'new frame empty',
  );
  assert.strictEqual(doc.getElementById('px-pos').textContent, 'Scene 1 of 1 · frame 3 of 3');
  doc.getElementById('px-hold-up').click();
  doc.getElementById('px-hold-up').click();
  assert.strictEqual(remote().pixel.scenes[0].frames[2].hold, 3);
  const fps = doc.getElementById('px-fps');
  fps.value = '99';
  fps.dispatch('change', { target: fps });
  assert.strictEqual(remote().pixel.scenes[0].fps, 30);
  doc.getElementById('px-fr-left').click();
  assert.strictEqual(remote().pixel.scenes[0].frames[1].hold, 3, 'moved left');
  assert.strictEqual(doc.getElementById('px-pos').textContent, 'Scene 1 of 1 · frame 2 of 3');
  doc.getElementById('px-fr-del').click();
  assert.strictEqual(remote().pixel.scenes[0].frames.length, 2);

  // move tool shifts (wraps)
  key('ArrowLeft'); // to frame 1
  key('m');
  const pre = remote().pixel.scenes[0].frames[0].cells.slice();
  view.dispatch('pointerdown', at(3, 3));
  view.dispatch('pointermove', at(4, 3));
  view.dispatch('pointerup', at(4, 3));
  const post = remote().pixel.scenes[0].frames[0].cells;
  assert.strictEqual(post[1 * 16 + 2], pre[1 * 16 + 1], 'moved right by 1');

  // line with mirror
  key('l');
  doc
    .getElementById('px-tools')
    .all()
    .find((b) => b.textContent === '⇆ Mirror')
    .click();
  view.dispatch('pointerdown', at(0, 9));
  view.dispatch('pointermove', at(2, 9));
  view.dispatch('pointerup', at(2, 9));
  const mc = remote().pixel.scenes[0].frames[0].cells;
  assert.ok(mc[9 * 16 + 15] !== 0 && mc[9 * 16 + 13] !== 0, 'mirrored line');

  // circle + flip + clear
  key('c');
  view.dispatch('pointerdown', at(9, 0));
  view.dispatch('pointermove', { ...at(13, 4), shiftKey: true });
  view.dispatch('pointerup', at(13, 4));
  doc
    .getElementById('px-tools')
    .all()
    .find((b) => b.textContent === '↔ Flip')
    .click();
  doc
    .getElementById('px-tools')
    .all()
    .find((b) => b.textContent === '✕ Clear')
    .click();
  assert.ok(
    remote().pixel.scenes[0].frames[0].cells.every((v) => v === 0),
    'cleared',
  );
  key('z', { ctrlKey: true });
  assert.ok(
    remote().pixel.scenes[0].frames[0].cells.some((v) => v !== 0),
    'clear undone',
  );

  // onion + play scene
  key('o');
  flush();
  assert.ok(doc.getElementById('px-onion').classList.contains('on'));
  key('Enter');
  flush(40, 5);
  key('Enter');
  assert.ok(!doc.getElementById('px-play').classList.contains('on'));

  // scenes: add from side panel
  doc.getElementById('px-scene-add').click();
  st = remote().pixel;
  assert.strictEqual(st.scenes.length, 2);
  assert.strictEqual(st.scenes[1].transition, 'fade');
  assert.strictEqual(doc.getElementById('px-scenes').children.length, 2);
  assert.ok(doc.getElementById('px-scenes').children[1].classList.contains('on'), 'new scene selected');

  // storyboard
  key('s');
  const board = doc.getElementById('pixel').querySelector('.px-board');
  assert.ok(board, 'board open');
  assert.strictEqual(board.querySelectorAll('.px-card').length, 2);
  const cap = board.querySelector('[data-field="caption"]');
  cap.value = 'The frog hops away… “bye”';
  cap.dispatch('change');
  st = remote().pixel;
  assert.strictEqual(st.scenes[1].caption, 'The frog hops away… “bye”');
  const nm = doc.getElementById('pixel').querySelector('.px-board').querySelector('[data-field="name"]');
  nm.value = 'Goodbye';
  nm.dispatch('change');
  assert.strictEqual(remote().pixel.scenes[1].name, 'Goodbye');
  let b2 = doc.getElementById('pixel').querySelector('.px-board');
  b2.all()
    .find((b) => b.textContent === 'Circle')
    .click();
  assert.strictEqual(remote().pixel.scenes[1].transition, 'iris');
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  b2.all()
    .find((b) => b.textContent === '+ Speech bubble')
    .click();
  st = remote().pixel;
  assert.strictEqual(st.scenes[1].bubbles.length, 1);
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  const bub = b2.all().find((e) => e.dataset.field === `bubble-${st.scenes[1].bubbles[0].id}`);
  bub.value = 'Ribbit!';
  bub.dispatch('change');
  assert.strictEqual(remote().pixel.scenes[1].bubbles[0].text, 'Ribbit!');
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  const sel = b2.all().find((e) => e.dataset.field === `bubble-style-${st.scenes[1].bubbles[0].id}`);
  sel.value = 'shout';
  sel.dispatch('change');
  assert.strictEqual(remote().pixel.scenes[1].bubbles[0].style, 'shout');
  // drag the bubble body
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  const body = b2.querySelector('.px-handle.body');
  body.dispatch('pointerdown', { pointerId: 7, clientX: 0, clientY: 0 });
  body.dispatch('pointermove', { pointerId: 7, clientX: 400, clientY: 150 });
  body.dispatch('pointerup', { pointerId: 7, clientX: 400, clientY: 150 });
  st = remote().pixel;
  assert.strictEqual(st.scenes[1].bubbles[0].x, 0.5);
  assert.strictEqual(st.scenes[1].bubbles[0].y, 0.25);
  // background swatch
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  b2.querySelector('.px-bgs').children[3].click();
  assert.strictEqual(remote().pixel.scenes[1].background, 3);
  // copy and move scene 2 earlier, then delete via confirm
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  b2.querySelectorAll('.px-card')[1]
    .all()
    .find((b) => b.textContent === 'Copy')
    .click();
  assert.strictEqual(remote().pixel.scenes.length, 3);
  assert.strictEqual(remote().pixel.scenes[2].name, 'Goodbye copy');
  assert.notStrictEqual(remote().pixel.scenes[2].id, remote().pixel.scenes[1].id);
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  b2.querySelectorAll('.px-card')[2]
    .all()
    .find((b) => b.textContent === '◀')
    .click();
  assert.strictEqual(remote().pixel.scenes[1].name, 'Goodbye copy');
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  b2.querySelectorAll('.px-card')[1]
    .all()
    .find((b) => b.textContent === 'Delete')
    .click();
  await new Promise((r) => setTimeout(r, 0));
  const ok = doc
    .getElementById('modal-root')
    .all()
    .find((b) => b.textContent === 'Delete' && b.classList.contains('primary'));
  ok.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.strictEqual(remote().pixel.scenes.length, 2);
  assert.ok(remote().pixel.scenes.every((s) => s.name !== 'Goodbye copy'));

  // player from the board
  b2 = doc.getElementById('pixel').querySelector('.px-board');
  b2.all()
    .find((b) => b.textContent === '▶ Play story')
    .click();
  const player = doc.getElementById('pixel').querySelector('.px-player');
  assert.ok(player, 'player open');
  flush(100, 80);
  const label = player.querySelector('.px-tv-label');
  assert.ok(/^\d\/2 /.test(label.textContent), `label ${label.textContent}`);
  key('Escape');
  assert.ok(!doc.getElementById('pixel').querySelector('.px-player'), 'player closed');
  key('Escape');
  assert.ok(!doc.getElementById('pixel').querySelector('.px-board'), 'board closed');

  // grid & colors: resize to 20x10 and switch palette to Game Boy
  doc.getElementById('px-settings').click();
  await new Promise((r) => setTimeout(r, 0));
  const m = doc.getElementById('modal-root');
  const nums = m.all().filter((e) => e.tagName === 'INPUT' && e.attrs.type === 'number');
  nums[0].value = '20';
  nums[1].value = '10';
  const palSel = m.all().find((e) => e.tagName === 'SELECT');
  palSel.value = 'Game Boy';
  m.all()
    .find((b) => b.textContent === 'Save')
    .click();
  await new Promise((r) => setTimeout(r, 0));
  const rp = remote();
  assert.strictEqual(rp.pixel.width, 20);
  assert.strictEqual(rp.pixel.height, 10);
  assert.strictEqual(rp.pixel.paletteName, 'Game Boy');
  assert.strictEqual(rp.pixel.palette.length, 5);
  assert.strictEqual(rp.canvas.width, 20 * Math.floor(1024 / 20));
  flush(16, 2);
  assert.strictEqual(doc.getElementById('px-palette').children.length, 5, '4 colors + add');

  // exports
  const exportChoose = async (label, extra) => {
    doc.getElementById('px-export').click();
    await new Promise((r) => setTimeout(r, 0));
    const mm = doc.getElementById('modal-root');
    mm.all()
      .find((b) => b.textContent === label)
      .click();
    if (extra) extra(mm);
    mm.all()
      .find((b) => b.textContent === 'Export' && b.tagName === 'BUTTON')
      .click();
    for (let i = 0; i < 400; i++) await new Promise((r) => setTimeout(r, 0));
  };
  await exportChoose('🖼 This frame as a PNG');
  assert.strictEqual(saved.length, 1);
  assert.strictEqual(saved[0].kind, 'png');
  assert.ok(saved[0].name.endsWith('.png'));
  await exportChoose('🧩 Sprite sheet (this scene)');
  assert.strictEqual(written.length, 2, 'png + json');
  assert.ok(written[1].name.endsWith(' sheet.json'), written[1].name);
  const json = JSON.parse(Buffer.from(written[1].data).toString('utf8'));
  assert.strictEqual(json.image, written[0].name);
  await exportChoose('🎞 Whole story as a GIF');
  for (let i = 0; i < 4000 && saved.length < 2; i++) await new Promise((r) => setTimeout(r, 0));
  assert.strictEqual(saved.length, 2, 'gif saved');
  assert.strictEqual(saved[1].kind, 'gif');
  const g = PixelGif.decode(saved[1].data);
  assert.ok(g.frames.length > 1, `gif frames ${g.frames.length}`);

  // a sync change from another device keeps the selection
  const other = new Hlc.HLC('ipad');
  const r = new Replica.Replica();
  r.apply(client.logs[p0.id]);
  for (const op of client.logs[p0.id]) other.observe(op.t);
  const remoteP = r.toProject(p0.id);
  const next = { ...remoteP, pixel: Pixel.editableCopy(remoteP.pixel) };
  next.pixel.scenes[0].name = 'From iPad';
  const ops = Replica.makeOps(Objects.diff(r.objects(), Objects.toObjects(next)), other);
  assert.strictEqual(ops.length, 1, 'one op for a rename');
  client.logs[p0.id].push(...ops);
  client.emit('ops', { p: p0.id, ops });
  flush();
  assert.ok(doc.getElementById('px-scenes').children[0].textContent.includes('From iPad'));

  // new story box
  const pr = Gale.pixelEditor.askNewStory();
  await new Promise((r2) => setTimeout(r2, 0));
  const nb = doc.getElementById('modal-root');
  nb.all()
    .find((b) => b.classList.contains('px-size-pick') && b.textContent.includes('Wide'))
    .click();
  nb.all()
    .find((b) => b.classList.contains('px-pal-pick') && b.textContent.includes('Sweetie 16'))
    .click();
  nb.all()
    .find((b) => b.textContent === '▶ Start')
    .click();
  const np = await pr;
  assert.strictEqual(np.pixel.width, 64);
  assert.strictEqual(np.pixel.height, 36);
  assert.strictEqual(np.pixel.paletteName, 'Sweetie 16');

  // back button
  doc.getElementById('px-back').click();
  assert.strictEqual(closed, 1);
  assert.ok(!Gale.pixelEditor.isOpen);
});

test('home screen: pixel story covers and the new story box', async () => {
  const doc = makeDocument();
  const ctx = {
    document: doc,
    console,
    ImageData,
    Uint8ClampedArray,
    Uint8Array,
    Map,
    Set,
    WeakMap,
    Promise,
    Math,
    JSON,
    Date,
    Number,
    String,
    Array,
    Object,
    Error,
    setTimeout,
    Intl,
    TextEncoder,
    requestAnimationFrame: () => 0,
    localStorage: { getItem: () => null, setItem() {} },
    ResizeObserver: class {
      observe() {}
    },
    performance: { now: () => 0 },
  };
  ctx.window = ctx;
  ctx.addEventListener = () => {};
  ctx.GaleShared = Shared;
  ctx.galeAPI = {};
  vm.createContext(ctx);
  for (const f of ['ui.js', 'session.js', 'exporter.js', 'pixelEditor.js', 'home.js'])
    vm.runInContext(fs.readFileSync(path.join(ROOT, 'renderer/js', f), 'utf8'), ctx, { filename: f });
  const p = Shared.Model.newPixelProject({ name: 'Pix', width: 16, height: 16 });
  p.pixel.scenes[0].frames[0].cells[0] = 3;
  const pushed = [];
  const opened = [];
  const client = {
    deviceId: 'd',
    projects: [{ id: p.id, name: 'Pix', modified: p.modified, seq: 1, pixel: true }],
    on() {},
    push: (id, ops) => pushed.push({ id, ops }),
    fetchProject: async () => JSON.parse(JSON.stringify(Shared.Model.toJSON(p))),
  };
  ctx.Gale.home.init(
    client,
    (...a) => opened.push(a),
    () => {},
  );
  for (let i = 0; i < 20; i++) await new Promise((r) => setTimeout(r, 0));
  const grid = doc.getElementById('project-grid');
  const card = grid.children[0];
  assert.ok(card.classList.contains('px-card-home'));
  assert.ok(card.querySelector('.px-tag'));
  const cv = card.querySelector('.thumb').children[0];
  assert.ok(cv && cv.tagName === 'CANVAS' && cv.className === 'px-cover', 'pixel cover');
  assert.strictEqual(cv.width, 16 * 18); // floor(min(460/16, 288/16)) = 18
  // new pixel story button
  doc.getElementById('home-new-pixel').click();
  await new Promise((r) => setTimeout(r, 0));
  doc
    .getElementById('modal-root')
    .all()
    .find((b) => b.textContent === '▶ Start')
    .click();
  for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0));
  assert.strictEqual(pushed.length, 1);
  assert.strictEqual(opened.length, 1);
  assert.strictEqual(opened[0][2], 'pixel');
  const objs = Object.fromEntries(pushed[0].ops.filter((o) => o.o === pushed[0].id).map((o) => [o.k, o.v]));
  assert.ok(objs.pixel && objs.pixel.width === 32, 'project object carries pixel');
});
