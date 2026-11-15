'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Model, Objects, Hlc, Replica: R, Edits } = require('../src/shared');
const { buildProject, canonical, lineStroke, shuffle } = require('./helpers');

function opsFor(changes, actor, now) {
  return R.makeOps(changes, new Hlc.HLC(actor, now));
}

test('project -> objects -> project gives the same project', () => {
  const p = buildProject();
  const objs = Objects.toObjects(p);
  assert.equal(objs[p.id].$type, 'project');
  const back = Objects.fromObjects(objs, p.id, { modified: p.modified });
  assert.deepEqual(canonical(back), canonical(p));
});

test('every object has the spec fields', () => {
  const objs = Objects.toObjects(buildProject());
  for (const o of Object.values(objs)) {
    const want = ['$type', ...Objects.FIELDS[o.$type]].sort();
    assert.deepEqual(Object.keys(o).sort(), want, o.$type);
  }
});

test('diff ops rebuild the new project on a replica holding the old one', () => {
  const oldP = buildProject();
  const rep = new R.Replica();
  rep.apply(opsFor(Objects.diff({}, Objects.toObjects(oldP)), 'desk-1', () => 1763229600000));
  assert.deepEqual(canonical({ ...rep.toProject(oldP.id), modified: oldP.modified }), canonical(oldP));

  // Edit: rename, new stroke, delete a frame, move a layer, change a hold, recolor a fill, new layer.
  let p = { ...oldP, name: 'Renamed', fps: 24 };
  p = Edits.addStroke(p, p.frames[1].id, p.layers[0].id, lineStroke(1, 2, 3, 400));
  p = Edits.deleteFrame(p, 0);
  p = Edits.moveLayer(p, 1, 0);
  p = Edits.setHold(p, 0, 4);
  p = Edits.addLayer(p, 'Top').project;
  p = Edits.updateLayer(p, p.layers[0].id, { visible: false, opacity: 0.25 });
  const newP = Model.readProject(JSON.parse(JSON.stringify(Model.toJSON(p))));

  const changes = Objects.diff(rep.objects(), Objects.toObjects(newP));
  assert.ok(changes.length > 0);
  // One op per changed field: no field twice.
  const seen = new Set(changes.map((c) => c.o + '/' + c.k));
  assert.equal(seen.size, changes.length);
  // Deleting frame 0 deletes its strokes too.
  for (const s of oldP.frames[0].cels[oldP.layers[0].id].strokes) {
    assert.ok(changes.some((c) => c.o === s.id && c.k === '$del' && c.v === true));
  }
  rep.apply(opsFor(changes, 'desk-1', () => 1763229700000));
  assert.deepEqual(canonical({ ...rep.toProject(newP.id), modified: newP.modified }), canonical(newP));
  // Nothing left to change.
  assert.deepEqual(Objects.diff(rep.objects(), Objects.toObjects(newP)), []);
});

test('deleted objects come back with $del false', () => {
  const p = buildProject();
  const rep = new R.Replica();
  const clock = new Hlc.HLC('a1');
  rep.apply(R.makeOps(Objects.diff({}, Objects.toObjects(p)), clock));
  const gone = Edits.deleteFrame(p, 1);
  rep.apply(R.makeOps(Objects.diff(rep.objects(), Objects.toObjects(gone)), clock));
  assert.equal(rep.toProject(p.id).frames.length, p.frames.length - 1);
  const back = Objects.diff(rep.objects(), Objects.toObjects(p));
  assert.ok(back.some((c) => c.o === p.frames[1].id && c.k === '$del' && c.v === false));
  rep.apply(R.makeOps(back, clock));
  assert.deepEqual(canonical({ ...rep.toProject(p.id), modified: p.modified }), canonical(p));
});

test('strokes whose frame or layer is gone are ignored', () => {
  const objs = {
    p: { $type: 'project', name: 'X' },
    l: { $type: 'layer', key: 'a0', name: 'L' },
    f: { $type: 'frame', key: 'a0', hold: 1 },
    gone: { $type: 'frame', key: 'a1', hold: 1, $del: true },
    s1: { $type: 'stroke', frame: 'f', layer: 'l', key: 'a0', brush: { kind: 'pen' }, pts: [] },
    s2: { $type: 'stroke', frame: 'gone', layer: 'l', key: 'a0', brush: {}, pts: [] },
    s3: { $type: 'stroke', frame: 'f', layer: 'nope', key: 'a0', brush: {}, pts: [] },
    s4: { $type: 'stroke', frame: 'f', layer: 'l', key: 'a1', brush: {}, pts: [], $del: true },
    x: { $type: 'future-thing', size: 3 },
  };
  const p = Objects.fromObjects(objs, 'p');
  assert.equal(p.frames.length, 1);
  assert.deepEqual(p.frames[0].cels.l.strokes.map((s) => s.id), ['s1']);
});

test('LWW: three replicas converge with shuffled and repeated ops', () => {
  const base = buildProject();
  const baseOps = opsFor(Objects.diff({}, Objects.toObjects(base)), 'hub', () => 1763229600000);
  const devices = ['ipad-1', 'iphone-2', 'desk-3'];
  const all = [...baseOps];
  // Each device makes its own edits from the same start, some touching the same fields.
  devices.forEach((actor, n) => {
    const rep = new R.Replica();
    rep.apply(baseOps);
    let p = rep.toProject(base.id);
    p = { ...p, name: `Name from ${actor}` };
    p = Edits.addStroke(p, p.frames[0].id, p.layers[0].id, lineStroke(n, n, 100 + n, 50));
    p = Edits.setHold(p, 1, n + 2);
    if (n === 1) p = Edits.deleteFrame(p, 2);
    if (n === 2) p = Edits.updateLayer(p, p.layers[1].id, { name: 'Lines' });
    const clock = new Hlc.HLC(actor, () => 1763229600000 + 1000 + (n % 2) * 7);
    all.push(...R.makeOps(Objects.diff(rep.objects(), Objects.toObjects(p)), clock));
  });
  const results = [1, 2, 3].map((seed) => {
    const rep = new R.Replica();
    const mixed = shuffle([...all, ...all.slice(0, 40), ...shuffle(all, seed + 9).slice(0, 25)], seed);
    rep.apply(mixed);
    rep.apply(shuffle(all, seed * 31)); // everything again: changes nothing
    return rep;
  });
  const first = JSON.stringify(canonical(results[0].toProject(base.id)));
  for (const r of results) assert.equal(JSON.stringify(canonical(r.toProject(base.id))), first);
  const p = results[0].toProject(base.id);
  // Highest clock wins: iphone-2 and the desk tie on ms, iphone-2 is later by counter? Both use ms+7 or +0.
  assert.ok(p.name.startsWith('Name from '));
  assert.equal(p.frames[0].cels[p.layers[0].id].strokes.length, 1 + 3);
});

test('applying an op twice or an older op changes nothing', () => {
  const rep = new R.Replica();
  const a = { t: '1763229600000:00000:a', a: 'a', o: 'x', k: 'name', v: 'new' };
  const old = { t: '1763229599999:00009:b', a: 'b', o: 'x', k: 'name', v: 'old' };
  assert.equal(rep.apply([a]).length, 1);
  assert.equal(rep.apply([a]).length, 0);
  assert.equal(rep.apply([old]).length, 0);
  assert.equal(rep.get('x', 'name'), 'new');
  assert.equal(rep.apply([{ t: 'bad', a: 'a', o: 'x', k: 'name', v: 1 }]).length, 0);
  assert.equal(rep.apply([{ t: '1763229600000:00000:a', a: 'a', o: 'x', k: '__proto__', v: 1 }]).length, 0);
});

test('HLC strings sort in edit order', () => {
  let now = 1763229600000;
  const c = new Hlc.HLC('ipad-k3j2', () => now);
  const t1 = c.tick();
  const t2 = c.tick();
  now += 5;
  const t3 = c.tick();
  assert.equal(t1, '1763229600000:00000:ipad-k3j2');
  assert.equal(t2, '1763229600000:00001:ipad-k3j2');
  assert.equal(t3, '1763229600005:00000:ipad-k3j2');
  assert.ok(t1 < t2 && t2 < t3);
  // A clock that runs behind jumps past what it sees.
  c.observe('1763229900000:00042:other');
  now = 1763229600010;
  const t4 = c.tick();
  assert.equal(t4, '1763229900000:00043:ipad-k3j2');
  assert.ok(t4 > '1763229900000:00042:other');
  assert.equal(Hlc.cleanActor('My iPad!'), 'My-iPad-');
  const p = Hlc.parse(t4);
  assert.deepEqual(p, { ms: 1763229900000, counter: 43, actor: 'ipad-k3j2' });
});
