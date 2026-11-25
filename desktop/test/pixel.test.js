'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { Model, Objects, Hlc, Replica: R, Pixel, PixelStory: PS, PixelGif } = require('../src/shared');

// Made by the Swift test DesktopParityTests from the real iPad code (see that file to rewrite it).
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'pixel-swift.json'), 'utf8'));

function fnv(bytes) {
  let h = 2166136261;
  for (const b of bytes) {
    h ^= b;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

/** Same JSON whatever the key order. */
function sorted(v) {
  if (Array.isArray(v)) return v.map(sorted);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])]));
  return v;
}

function fixtureProject() {
  return Model.readProject(fixture.project);
}

/** A story drawn with the real tools: two scenes, three frames, a caption and a bubble. */
function makeStory() {
  const s = Pixel.newStory({ width: 16, height: 12, paletteName: 'PICO-8' });
  const g = new Pixel.Grid(16, 12);
  g.drawLine({ x: 0, y: 0 }, { x: 15, y: 11 }, 8);
  s.scenes[0].frames[0].cells = g.cells;
  s.scenes[0].caption = 'Once upon a time, a tiny frog wanted to see the sea.';
  s.scenes[0].bubbles = [Pixel.newBubble('Ribbit!', { x: 0.3, y: 0.2, tailX: 0.5, tailY: 0.8 })];
  const f = Pixel.blankFrame(16, 12, undefined, 2);
  f.cells = g.flippedHorizontally().cells;
  Pixel.insertFrame(s, f, 0, null);
  const two = Pixel.newScene('Sea', 16, 12, { fps: 6, loops: 3, background: 12, caption: 'The end.', transition: 'fade' });
  two.bubbles = [Pixel.newBubble('Wow', { style: 'shout' })];
  Pixel.insertScene(s, two, null);
  return s;
}

function pixelProject() {
  const p = Model.newPixelProject({ name: 'Frog', width: 16, height: 12 });
  p.pixel = makeStory();
  return p;
}

// ---------- same as the iPad ----------

test('renderer matches Swift: layout, timing and every picture', () => {
  const s = fixtureProject().pixel;
  const r = new PS.Renderer(s, 200);
  const L = r.layout;
  assert.deepEqual(sorted({ artScale: L.artScale, textScale: L.textScale, width: L.width, height: L.height, barHeight: L.barHeight, captionChars: L.captionChars }), sorted(fixture.layout));
  assert.deepEqual(r.timing.spans.map((x) => [x.start, x.duration, x.typeStart]), fixture.spans);
  assert.equal(r.timing.total, fixture.total);
  for (const im of fixture.images) {
    const img = r.imageAt(im.t, false);
    assert.equal(img.width, im.w);
    assert.equal(img.height, im.h);
    assert.equal(fnv(img.data), im.hash, `picture at ${im.t}s`);
  }
});

test('GIF frames and bytes match Swift exactly', () => {
  const r = new PS.Renderer(fixtureProject().pixel, 200);
  const frames = r.frames(25);
  assert.deepEqual(frames.map((f) => [fnv(f.image.data), f.centiseconds]), fixture.frames);
  const gif = new PixelGif.GifWriter(r.layout.width, r.layout.height);
  for (const f of frames) gif.add(f.image, f.centiseconds);
  const bytes = gif.finish();
  assert.equal(bytes.length, fixture.gif.size);
  assert.equal(fnv(bytes), fixture.gif.hash);
});

test('sprite sheet, onion skin and bubbles match Swift', () => {
  const s = fixtureProject().pixel;
  const sheet = PS.spriteSheet(s, 0, 3, null, false);
  assert.equal(sheet.image.width, fixture.sheet.w);
  assert.equal(sheet.image.height, fixture.sheet.h);
  assert.equal(fnv(sheet.image.data), fixture.sheet.hash);
  assert.equal(PS.spriteSheetJSON(s, 0, sheet.layout, 'frog "1".png'), fixture.sheet.json);
  assert.equal(fnv(Pixel.editorFrame(s, 0, 1, { on: true, before: 1, after: 1, opacity: 0.5 }).data), fixture.editor);
  const r = new PS.Renderer(s, 200);
  const shapes = [];
  for (const sc of s.scenes) {
    for (const b of sc.bubbles) {
      const sh = r.bubbleShape(b, b.text);
      const cells = sh.cells.sort((a, c) => a.y - c.y || a.x - c.x).map((c) => [c.x, c.y]);
      shapes.push({ text: b.text, cells, box: [sh.box.x, sh.box.y, sh.box.w, sh.box.h], lines: sh.lines });
    }
  }
  assert.deepEqual(sorted(shapes), sorted(fixture.shapes));
});

test('tools, palette switch, resize and word wrap match Swift', () => {
  const s = fixtureProject().pixel;
  const g = new Pixel.Grid(24, 18);
  g.drawLine({ x: 0, y: 0 }, { x: 23, y: 17 }, 3, 2, true);
  g.drawEllipse({ x: 4, y: 3 }, { x: 14, y: 11 }, 6);
  g.drawRect({ x: 16, y: 1 }, { x: 22, y: 6 }, 9, true);
  assert.equal(g.floodFill(9, 7, 12), fixture.filled);
  assert.deepEqual(Array.from(g.cells), Array.from(s.scenes[0].frames[0].cells));
  const sw = Pixel.cloneStory(s);
  Pixel.switchPalette(sw, Pixel.paletteNamed('Game Boy'));
  assert.deepEqual(sw.scenes.map((sc) => sc.frames.map((f) => Pixel.encodeRuns(f.cells))), fixture.switched);
  assert.deepEqual(sw.scenes.map((sc) => sc.background), fixture.switchedBackgrounds);
  assert.equal(sw.paletteName, 'Game Boy');
  const rs = Pixel.cloneStory(s);
  Pixel.resize(rs, 30, 10);
  assert.deepEqual(rs.scenes.map((sc) => sc.frames.map((f) => Pixel.encodeRuns(f.cells))), fixture.resized);
  assert.deepEqual(PS.Font.wrap('Hello there, this is a looooooooooooong word test\n\nnew para ', 10), fixture.wrapped);
  assert.deepEqual(Pixel.ellipse({ x: 2, y: 1 }, { x: 9, y: 6 }).map((c) => [c.x, c.y]), fixture.ellipse);
});

test('reads and writes the iPad project file the same way', () => {
  const p = fixtureProject();
  assert.deepEqual(sorted(Model.toJSON(p).pixel), sorted(fixture.project.pixel));
  assert.deepEqual(sorted(Model.toJSON(Model.readProject(JSON.parse(JSON.stringify(Model.toJSON(p))))).pixel), sorted(fixture.project.pixel));
});

test('sync objects match the iPad, both ways', () => {
  const p = fixtureProject();
  const mine = Objects.toObjects(p);
  // Nothing about the story differs from what the iPad sends.
  const changes = Objects.diff(fixture.objects, mine).filter((c) => c.k === 'pixel' || ['pxscene', 'pxframe'].includes((fixture.objects[c.o] || {}).$type));
  assert.deepEqual(changes, []);
  for (const [id, o] of Object.entries(fixture.objects)) {
    if (o.$type === 'pxscene' || o.$type === 'pxframe') assert.deepEqual(sorted(mine[id]), sorted(o), id);
  }
  const built = Objects.fromObjects(fixture.objects, 'projfixture');
  assert.deepEqual(sorted(Model.toJSON(built).pixel), sorted(fixture.project.pixel));
});

// ---------- the model ----------

test('runs pack and unpack like Swift, and bad runs are safe', () => {
  assert.deepEqual(Pixel.encodeRuns(Uint8Array.from([0, 0, 0, 5, 5, 1, 0, 0])), [3, 0, 2, 5, 1, 1, 2, 0]);
  assert.deepEqual(Array.from(Pixel.decodeRuns([3, 0, 2, 5, 1, 1, 2, 0])), [0, 0, 0, 5, 5, 1, 0, 0]);
  assert.deepEqual(Pixel.encodeRuns(new Uint8Array(0)), []);
  assert.deepEqual(Array.from(Pixel.decodeRuns([2, 300, -1, 4, 0.5, 1, 1, 7])), [255, 255, 7]);
  assert.equal(Pixel.decodeRuns([1e300, 3, 1e300, 4]).length, Pixel.MAX_SIDE * Pixel.MAX_SIDE);
  assert.equal(Pixel.decodeRuns([1000000, 3], 5).length, 5);
  assert.deepEqual(Array.from(Pixel.decodeRuns([2, 'x'])), []);
  assert.deepEqual(Array.from(Pixel.decodeRuns('nope')), []);
});

test('a story reads forgivingly with the Swift defaults', () => {
  const s = Pixel.readStory({ width: 3, height: 9000, palette: ['#F00', 'nope'], scenes: [{ fps: 99, loops: 0, background: 7, transition: 'spin', bubbles: [{ x: 4, style: 'yell' }], frames: [{ hold: 0, runs: [5, 9, 2, 1] }] }] });
  assert.equal(s.width, Pixel.MIN_SIDE);
  assert.equal(s.height, Pixel.MAX_SIDE);
  assert.deepEqual(s.palette, [Pixel.CLEAR, '#000000FF']);
  assert.equal(s.paper, '#FFFFFFFF');
  const sc = s.scenes[0];
  assert.equal(sc.fps, 30);
  assert.equal(sc.loops, 1);
  assert.equal(sc.background, 0);
  assert.equal(sc.transition, 'cut');
  assert.equal(sc.name, 'Scene');
  assert.deepEqual(sc.bubbles.map((b) => [b.x, b.y, b.tailX, b.tailY, b.style, b.text]), [[1, 0.2, 0.45, 0.5, 'speech', '']]);
  assert.equal(sc.frames[0].hold, 1);
  assert.equal(sc.frames[0].cells.length, 8 * 256);
  // Index 9 is past the palette, so it turns see-through; index 1 stays.
  assert.deepEqual(Array.from(sc.frames[0].cells.subarray(0, 8)), [0, 0, 0, 0, 0, 1, 1, 0]);
  const empty = Pixel.readStory(null);
  assert.equal(empty.width, 32);
  assert.equal(empty.palette.length, 17);
  assert.equal(empty.scenes.length, 1);
  assert.equal(empty.scenes[0].frames.length, 1);
});

test('normal drawings have no pixel field, pixel projects keep theirs', () => {
  const plain = Model.newProject({ name: 'Plain' });
  assert.equal('pixel' in Model.toJSON(plain), false);
  assert.equal(Model.readProject({ name: 'x' }).pixel, undefined);
  assert.equal(Objects.toObjects(plain)[plain.id].pixel, undefined);
  const p = Model.newPixelProject({ name: 'Tiny', width: 16, height: 16, paletteName: 'Game Boy' });
  assert.deepEqual(p.canvas, { width: 1024, height: 1024, background: '#9BBC0FFF' });
  assert.equal(p.fps, 8);
  assert.equal(p.pixel.paletteName, 'Game Boy');
  const json = JSON.parse(JSON.stringify(Model.toJSON(p)));
  assert.ok(Array.isArray(json.pixel.scenes[0].frames[0].runs));
  assert.equal(json.pixel.scenes[0].frames[0].cells, undefined);
  assert.deepEqual(json.pixel.scenes[0].frames[0].runs, [256, 0]);
});

test('keys stay in order when scenes and frames are added and moved', () => {
  const s = makeStory();
  const before = s.scenes.map((x) => x.id);
  Pixel.insertScene(s, Pixel.newScene('Middle', 16, 12), 0);
  assert.equal(s.scenes[1].name, 'Middle');
  Pixel.moveScene(s, 2, 0);
  assert.equal(s.scenes[0].id, before[1]);
  const keys = s.scenes.map((x) => x.key);
  assert.deepEqual(keys.slice().sort(), keys, 'keys sort like the list');
  Pixel.moveFrame(s, 1, 0, 1);
  const fk = s.scenes[1].frames.map((x) => x.key);
  assert.deepEqual(fk.slice().sort(), fk);
  // Reading again (which sorts by key) keeps the same order.
  const again = Pixel.readStory(Pixel.storyToJSON(s));
  assert.deepEqual(again.scenes.map((x) => x.id), s.scenes.map((x) => x.id));
});

test('copying a pixel project gives new ids everywhere', () => {
  const p = pixelProject();
  const c = Model.withFreshIds(p, 'Copy');
  assert.notEqual(c.id, p.id);
  assert.notEqual(c.pixel.scenes[0].id, p.pixel.scenes[0].id);
  assert.notEqual(c.pixel.scenes[0].frames[0].id, p.pixel.scenes[0].frames[0].id);
  assert.notEqual(c.pixel.scenes[0].bubbles[0].id, p.pixel.scenes[0].bubbles[0].id);
  assert.deepEqual(Array.from(c.pixel.scenes[0].frames[0].cells), Array.from(p.pixel.scenes[0].frames[0].cells));
  c.pixel.scenes[0].frames[0].cells[0] = 3;
  assert.equal(p.pixel.scenes[0].frames[0].cells[0], 8, 'the copy has its own cells');
});

// ---------- sync ----------

test('drawing on one frame sends one op, and a replica rebuilds it', () => {
  const oldP = pixelProject();
  const rep = new R.Replica();
  rep.apply(R.makeOps(Objects.diff({}, Objects.toObjects(oldP)), new Hlc.HLC('desk-1', () => 1763229600000)));
  const newP = { ...oldP, pixel: Pixel.cloneStory(oldP.pixel) };
  const g = new Pixel.Grid(16, 12, newP.pixel.scenes[1].frames[0].cells);
  g.stamp(5, 5, 3);
  newP.pixel.scenes[1].frames[0].cells = g.cells;
  const changes = Objects.diff(rep.objects(), Objects.toObjects(newP));
  assert.equal(changes.length, 1);
  assert.equal(changes[0].o, newP.pixel.scenes[1].frames[0].id);
  assert.equal(changes[0].k, 'runs');
  rep.apply(R.makeOps(changes, new Hlc.HLC('desk-1', () => 1763229601000)));
  const back = rep.toProject(newP.id);
  assert.deepEqual(sorted(Model.toJSON(back).pixel), sorted(Model.toJSON(newP).pixel));
});

test('two devices drawing on different frames both win', () => {
  const base = pixelProject();
  const start = Objects.diff({}, Objects.toObjects(base));
  const a = new R.Replica();
  const b = new R.Replica();
  const seed = R.makeOps(start, new Hlc.HLC('seed', () => 1763229600000));
  a.apply(seed);
  b.apply(seed);
  const edit = (rep, scene, color, actor, ms) => {
    const p = rep.toProject(base.id);
    const g = new Pixel.Grid(16, 12, p.pixel.scenes[scene].frames[0].cells);
    g.floodFill(0, 11, color);
    p.pixel.scenes[scene].frames[0].cells = g.cells;
    return R.makeOps(Objects.diff(rep.objects(), Objects.toObjects(p)), new Hlc.HLC(actor, () => ms));
  };
  const opsA = edit(a, 0, 2, 'ipad', 1763229601000);
  const opsB = edit(b, 1, 9, 'desk', 1763229602000);
  a.apply(opsA);
  a.apply(opsB);
  b.apply(opsB);
  b.apply(opsA);
  const pa = Model.toJSON(a.toProject(base.id));
  const pb = Model.toJSON(b.toProject(base.id));
  assert.deepEqual(sorted(pa.pixel), sorted(pb.pixel));
  const story = Pixel.readStory(pa.pixel);
  assert.equal(story.scenes[0].frames[0].cells[11 * 16], 2);
  assert.equal(story.scenes[1].frames[0].cells[0], 9);
});

test('a story with no scenes yet builds the same ids every time', () => {
  const objs = { p1: { $type: 'project', name: 'Early', pixel: { width: 16, height: 16, palette: ['#00000000', '#000000FF'], paletteName: '1-bit', paper: '#FFFFFFFF' } } };
  const a = Objects.fromObjects(objs, 'p1');
  const b = Objects.fromObjects(objs, 'p1');
  assert.equal(a.pixel.scenes[0].id, 'p1-pxscene');
  assert.equal(a.pixel.scenes[0].frames[0].id, 'p1-pxscene-pxframe');
  assert.deepEqual(Objects.toObjects(a), Objects.toObjects(b));
});

test('frames whose scene is gone are left out, and deleting a scene works', () => {
  const p = pixelProject();
  const objs = JSON.parse(JSON.stringify(Objects.toObjects(p)));
  const gone = p.pixel.scenes[1].id;
  objs[gone].$del = true;
  const back = Objects.fromObjects(objs, p.id);
  assert.equal(back.pixel.scenes.length, 1);
  assert.equal(back.pixel.scenes[0].frames.length, 2);
});

// ---------- tools ----------

test('pencil with mirrors, fill through edges only, shifts and flips', () => {
  const g = new Pixel.Grid(8, 8);
  g.stamp(1, 1, 4, 1, true, true);
  assert.deepEqual([g.get(1, 1), g.get(6, 1), g.get(1, 6), g.get(6, 6)], [4, 4, 4, 4]);
  assert.equal(g.inkCount, 4);
  const box = new Pixel.Grid(8, 8);
  box.drawRect({ x: 1, y: 1 }, { x: 6, y: 6 }, 1);
  assert.equal(box.floodFill(3, 3, 2), 16, 'inside of the box');
  assert.equal(box.floodFill(0, 0, 3), 28, 'outside ring');
  assert.equal(box.floodFill(0, 0, 3), 0, 'same color changes nothing');
  const diag = new Pixel.Grid(4, 4);
  diag.drawLine({ x: 0, y: 0 }, { x: 3, y: 3 }, 1);
  assert.equal(diag.floodFill(3, 0, 5), 6, 'corners do not leak');
  const shifted = diag.shifted(1, 0);
  assert.equal(shifted.get(0, 3), 1, 'wraps around');
  assert.equal(diag.shifted(1, 0, false).get(0, 3), 0);
  assert.equal(diag.flippedHorizontally().get(3, 0), 1);
  assert.equal(diag.flippedVertically().get(0, 3), 1);
  const line = Pixel.line({ x: 0, y: 0 }, { x: 5, y: 2 });
  assert.equal(line.length, 6);
  assert.deepEqual(line[0], { x: 0, y: 0 });
  assert.deepEqual(line[5], { x: 5, y: 2 });
});

test('the GIF reads back with the exact colors and timing', () => {
  const p = pixelProject();
  const r = new PS.Renderer(p.pixel, 96);
  const frames = r.frames(25);
  const gif = new PixelGif.GifWriter(r.layout.width, r.layout.height);
  for (const f of frames) gif.add(f.image, f.centiseconds);
  const back = PixelGif.decode(gif.finish());
  assert.equal(back.width, r.layout.width);
  assert.equal(back.loops, 0);
  assert.equal(back.frames.length, frames.length);
  frames.forEach((f, i) => {
    assert.equal(back.frames[i].centiseconds, f.centiseconds);
    assert.deepEqual(Buffer.from(back.frames[i].data), Buffer.from(f.image.data), `frame ${i}`);
  });
  const sum = frames.reduce((n, f) => n + f.centiseconds, 0);
  assert.ok(Math.abs(sum / 100 - r.timing.total) < 0.05);
});

test('too many colors still makes a GIF (color cube)', () => {
  const img = Pixel.image(40, 40);
  for (let i = 0; i < 1600; i++) Pixel.setPx(img, i % 40, Math.floor(i / 40), [i % 256, (i * 7) % 256, (i * 13) % 256, 255]);
  const gif = new PixelGif.GifWriter(40, 40);
  gif.add(img, 10);
  const back = PixelGif.decode(gif.finish());
  const px = back.frames[0].data;
  for (let i = 0; i < 1600; i += 97) {
    for (let c = 0; c < 3; c++) assert.ok(Math.abs(px[i * 4 + c] - img.data[i * 4 + c]) <= 26, `pixel ${i}`);
  }
});

test('typewriter shows the caption, then each bubble in turn', () => {
  const s = makeStory();
  const t = new PS.Timing(s);
  assert.equal(t.typed(0, 0.1), 0);
  assert.equal(t.typed(0, 0.2 + 1), 24);
  assert.equal(PS.sceneLetters(s.scenes[0]), 52 + 7);
  const span = t.spans[0];
  assert.ok(span.duration >= 0.2 + 59 / 24 + 1.6 - 1e-9);
  assert.deepEqual(t.locate(span.start + 0.01), { scene: 0, local: 0.01 });
  assert.equal(t.locate(t.total + 0.5).scene, 0, 'loops');
  assert.equal(t.locate(t.total + 5, false).scene, s.scenes.length - 1, 'stops at the end');
  const sc = s.scenes[0];
  assert.equal(PS.Timing.frameIndex(sc, 0), 0);
  assert.equal(PS.Timing.frameIndex(sc, 1 / 8), 1);
  assert.equal(PS.Timing.frameIndex(sc, 3 / 8), 0, 'second frame holds 2 ticks, then loops');
});
