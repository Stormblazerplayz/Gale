'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const WebSocket = require('ws');
const { GaleHub } = require('../src/hub');
const { Model, Objects, Hlc, Replica: R, Edits } = require('../src/shared');
const { buildProject, canonical, lineStroke } = require('./helpers');

function tmpDir(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `gale-${name}-`));
}

async function startHub(extra = {}) {
  const dataDir = tmpDir('hub');
  const hub = new GaleHub({ dataDir, port: 0, host: '127.0.0.1', serverName: 'Test PC', ...extra });
  const port = await hub.start();
  const base = `http://127.0.0.1:${port}/api/v1`;
  return { hub, port, base, dataDir };
}

async function api(base, pathName, { method = 'GET', token, body, raw } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  let payload;
  if (raw) payload = raw;
  else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(base + pathName, { method, headers, body: payload });
  const text = method === 'HEAD' ? '' : await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch (_) { /* not JSON */ }
  return { status: res.status, json, text, headers: res.headers };
}

async function pairDevice(hub, base, deviceId, deviceName) {
  const info = hub.startPairing();
  const r = await api(base, '/pair', { method: 'POST', body: { code: info.code, deviceId, deviceName } });
  assert.equal(r.status, 200, r.text);
  return r.json.token;
}

/** A tiny test client that keeps every message it gets. */
function connect(port, token, viaHeader = false) {
  const url = viaHeader ? `ws://127.0.0.1:${port}/api/v1/sync` : `ws://127.0.0.1:${port}/api/v1/sync?token=${token}`;
  const ws = new WebSocket(url, viaHeader ? { headers: { Authorization: `Bearer ${token}` } } : undefined);
  const inbox = [];
  const waiters = [];
  ws.on('message', (d) => {
    const msg = JSON.parse(d.toString());
    inbox.push(msg);
    for (const w of [...waiters]) {
      if (w.match(msg)) {
        waiters.splice(waiters.indexOf(w), 1);
        w.resolve(msg);
      }
    }
  });
  const client = {
    ws,
    inbox,
    open: new Promise((resolve, reject) => {
      ws.once('open', resolve);
      ws.once('error', reject);
      ws.once('unexpected-response', (_, res) => reject(new Error(`HTTP ${res.statusCode}`)));
    }),
    send: (m) => ws.send(JSON.stringify(m)),
    next(match, ms = 3000) {
      const found = inbox.find(match);
      if (found) {
        inbox.splice(inbox.indexOf(found), 1);
        return Promise.resolve(found);
      }
      return new Promise((resolve, reject) => {
        const w = {
          match,
          resolve: (m) => {
            clearTimeout(timer);
            inbox.splice(inbox.indexOf(m), 1);
            resolve(m);
          },
        };
        const timer = setTimeout(() => {
          waiters.splice(waiters.indexOf(w), 1);
          reject(new Error('timed out waiting for a message'));
        }, ms);
        waiters.push(w);
      });
    },
    close: () => ws.close(),
  };
  return client;
}

const ofType = (type, extra = () => true) => (m) => m.type === type && extra(m);

test('pairing: code, wrong tries, token, hello', async () => {
  const { hub, base } = await startHub();
  try {
    const hello = await api(base, '/hello');
    assert.equal(hello.status, 200);
    assert.equal(hello.json.serverName, 'Test PC');
    assert.equal(hello.json.protocolVersion, 1);
    assert.equal(hello.json.serverId, hub.serverId);

    // No code yet.
    let r = await api(base, '/pair', { method: 'POST', body: { code: '123456', deviceId: 'ipad-1', deviceName: 'iPad' } });
    assert.equal(r.status, 403);

    const info = hub.startPairing();
    assert.match(info.code, /^\d{6}$/);
    assert.ok(info.expiresAt - Date.now() <= 120000 && info.expiresAt - Date.now() > 110000);
    const url = new URL(info.url);
    assert.equal(url.protocol, 'gale:');
    assert.equal(url.searchParams.get('v'), '1');
    assert.equal(url.searchParams.get('port'), String(hub.port));
    assert.equal(url.searchParams.get('code'), info.code);
    assert.equal(url.searchParams.get('name'), 'Test PC');
    assert.equal(url.searchParams.get('id'), hub.serverId);
    assert.ok(url.searchParams.get('host'));

    const wrong = info.code === '000000' ? '000001' : '000000';
    for (let i = 4; i >= 1; i--) {
      r = await api(base, '/pair', { method: 'POST', body: { code: wrong, deviceId: 'ipad-1', deviceName: 'iPad' } });
      assert.equal(r.status, 401);
      assert.match(r.json.error, new RegExp(`${i} tr`));
    }
    // Fifth wrong try uses the code up.
    r = await api(base, '/pair', { method: 'POST', body: { code: wrong, deviceId: 'ipad-1', deviceName: 'iPad' } });
    assert.equal(r.status, 403);
    r = await api(base, '/pair', { method: 'POST', body: { code: info.code, deviceId: 'ipad-1', deviceName: 'iPad' } });
    assert.equal(r.status, 403, 'the old code is gone');

    // New code, right answer.
    const fresh = hub.startPairing();
    r = await api(base, '/pair', { method: 'POST', body: { code: fresh.code, deviceId: 'bad id!', deviceName: 'iPad' } });
    assert.equal(r.status, 400);
    r = await api(base, '/pair', { method: 'POST', body: { code: fresh.code, deviceId: 'ipad-1', deviceName: 'Storm iPad' } });
    assert.equal(r.status, 200);
    assert.match(r.json.token, /^[0-9a-f]{64}$/);
    assert.equal(r.json.serverId, hub.serverId);
    assert.equal(r.json.serverName, 'Test PC');
    assert.equal(r.json.protocolVersion, 1);
    // A code works once.
    const again = await api(base, '/pair', { method: 'POST', body: { code: fresh.code, deviceId: 'ipad-2', deviceName: 'x' } });
    assert.equal(again.status, 403);

    const token = r.json.token;
    assert.deepEqual(hub.devices().map((d) => d.deviceName), ['Storm iPad']);
    // Tokens are stored as hashes only.
    const state = fs.readFileSync(path.join(hub.store.dir, 'state.json'), 'utf8');
    assert.ok(!state.includes(token));

    assert.equal((await api(base, '/projects')).status, 401);
    assert.equal((await api(base, '/projects', { token: 'f'.repeat(64) })).status, 401);
    const list = await api(base, '/projects', { token });
    assert.equal(list.status, 200);
    assert.deepEqual(list.json, []);

    // Removing the device stops its token working.
    hub.removeDevice('ipad-1');
    assert.equal((await api(base, '/projects', { token })).status, 401);
  } finally {
    await hub.stop();
  }
});

test('pairing codes run out after 2 minutes', async () => {
  const { hub, base } = await startHub();
  try {
    const info = hub.startPairing();
    hub.pairing.expiresAt = Date.now() - 1;
    const r = await api(base, '/pair', { method: 'POST', body: { code: info.code, deviceId: 'ipad-1', deviceName: 'iPad' } });
    assert.equal(r.status, 403);
  } finally {
    await hub.stop();
  }
});

test('blobs: hash checked, GET and HEAD', async () => {
  const { hub, base } = await startHub();
  try {
    const token = await pairDevice(hub, base, 'ipad-1', 'iPad');
    const data = crypto.randomBytes(5000);
    const sha = crypto.createHash('sha256').update(data).digest('hex');
    assert.equal((await api(base, `/blobs/${sha}`, { method: 'HEAD', token })).status, 404);
    assert.equal((await api(base, `/blobs/${sha}`, { method: 'PUT', raw: data })).status, 401);
    const bad = await api(base, `/blobs/${'0'.repeat(64)}`, { method: 'PUT', token, raw: data });
    assert.equal(bad.status, 400);
    assert.equal((await api(base, '/blobs/notahash', { method: 'PUT', token, raw: data })).status, 400);
    const put = await api(base, `/blobs/${sha}`, { method: 'PUT', token, raw: data });
    assert.equal(put.status, 201);
    assert.equal((await api(base, `/blobs/${sha}`, { method: 'PUT', token, raw: data })).status, 200);
    const head = await api(base, `/blobs/${sha}`, { method: 'HEAD', token });
    assert.equal(head.status, 200);
    assert.equal(head.headers.get('content-length'), '5000');
    const res = await fetch(`${base}/blobs/${sha}`, { headers: { Authorization: `Bearer ${token}` } });
    assert.equal(res.status, 200);
    assert.ok(Buffer.from(await res.arrayBuffer()).equals(data));
    // Too-big bodies are refused.
    const big = await fetch(`${base}/blobs/${sha}`, {
      method: 'PUT',
      headers: { Authorization: `Bearer ${token}`, 'Content-Length': String(60 * 1024 * 1024) },
      body: Buffer.alloc(10),
      duplex: 'half',
    }).catch((e) => ({ status: 'error', e }));
    assert.ok(big.status === 413 || big.status === 'error');
  } finally {
    await hub.stop();
  }
});

test('websocket: hello, push, ack, ops between two clients, live, presence, ping', async () => {
  const docsDir = tmpDir('docs');
  const { hub, base, port, dataDir } = await startHub({ docsDir });
  hub.files.delay = 20;
  try {
    const tokenA = await pairDevice(hub, base, 'ipad-a', 'iPad A');
    const tokenB = await pairDevice(hub, base, 'iphone-b', 'iPhone B');
    assert.equal(hub.devices().length, 2);

    // Bad tokens can't open the socket.
    const bad = connect(port, 'nope'.repeat(10));
    await assert.rejects(bad.open);

    const a = connect(port, tokenA);
    const b = connect(port, tokenB, true);
    await Promise.all([a.open, b.open]);
    a.send({ type: 'hello', deviceId: 'ipad-a', deviceName: 'iPad A', since: {} });
    b.send({ type: 'hello', deviceId: 'iphone-b', deviceName: 'iPhone B', since: {} });
    const wa = await a.next(ofType('welcome'));
    assert.equal(wa.serverId, hub.serverId);
    assert.deepEqual(wa.projects, []);
    await b.next(ofType('welcome'));
    assert.ok(hub.devices().every((d) => d.online));

    // A makes a project.
    const project = buildProject();
    const clockA = new Hlc.HLC('ipad-a');
    const ops = R.makeOps(Objects.diff({}, Objects.toObjects(project)), clockA);
    b.send({ type: 'subscribe', p: project.id, since: 0 });
    const empty = await b.next(ofType('ops', (m) => m.p === project.id));
    assert.deepEqual(empty.ops, []);
    assert.equal(empty.seq, 0);

    a.send({ type: 'push', p: project.id, ops: [...ops, { t: 'broken' }], ref: 'r1' });
    const ack = await a.next(ofType('ack'));
    assert.equal(ack.ref, 'r1');
    assert.equal(ack.seq, ops.length);
    const skipped = await a.next(ofType('error'));
    assert.equal(skipped.skipped, 1);
    const got = await b.next(ofType('ops', (m) => m.p === project.id));
    assert.equal(got.ops.length, ops.length);
    assert.equal(got.seq, ops.length);
    const listB = await b.next(ofType('projects'));
    assert.equal(listB.projects[0].name, project.name);
    assert.equal(listB.projects[0].seq, ops.length);
    // The pusher doesn't get its own ops back.
    assert.ok(!a.inbox.some((m) => m.type === 'ops'));

    // B builds the same project from the ops.
    const repB = new R.Replica();
    repB.apply(got.ops);
    assert.deepEqual(canonical({ ...repB.toProject(project.id), modified: project.modified }), canonical(project));

    // REST gives the project as project.json.
    const rest = await api(base, `/projects/${project.id}`, { token: tokenB });
    assert.equal(rest.status, 200);
    assert.deepEqual(canonical({ ...Model.readProject(rest.json), modified: project.modified }), canonical(project));
    assert.equal((await api(base, '/projects/..%2Fevil', { token: tokenB })).status, 400);
    assert.equal((await api(base, '/projects/nothere', { token: tokenB })).status, 404);

    // B edits: only changed fields go out, and A gets them.
    let edited = repB.toProject(project.id);
    edited = Edits.addStroke(edited, edited.frames[0].id, edited.layers[0].id, lineStroke(0, 0, 50, 50));
    edited = { ...edited, name: 'Edited on iPhone' };
    const clockB = new Hlc.HLC('iphone-b');
    for (const op of got.ops) clockB.observe(op.t);
    const editOps = R.makeOps(Objects.diff(repB.objects(), Objects.toObjects(edited)), clockB);
    assert.equal(editOps.length, 7); // the new stroke ($type, frame, layer, key, brush, pts) and the name
    a.send({ type: 'subscribe', p: project.id, since: ops.length });
    const caughtUp = await a.next(ofType('ops', (m) => m.p === project.id));
    assert.deepEqual(caughtUp.ops, []);
    b.send({ type: 'push', p: project.id, ops: editOps, ref: 'r2' });
    const ack2 = await b.next(ofType('ack', (m) => m.ref === 'r2'));
    assert.equal(ack2.seq, ops.length + editOps.length);
    const toA = await a.next(ofType('ops', (m) => m.p === project.id && m.ops.length > 0));
    assert.equal(toA.ops.length, editOps.length);
    const renamed = await a.next(ofType('projects', (m) => m.projects[0].name !== project.name));
    assert.equal(renamed.projects[0].name, 'Edited on iPhone');

    // Pushing the same ops again changes nothing and goes to nobody.
    b.send({ type: 'push', p: project.id, ops: editOps, ref: 'r3' });
    const ack3 = await b.next(ofType('ack', (m) => m.ref === 'r3'));
    assert.equal(ack3.seq, ack2.seq);

    // Live strokes and presence are passed along with who sent them.
    b.send({ type: 'live', p: project.id, frame: 'f', layer: 'l', stroke: { id: 's', pts: [1, 2, 0.5, 1.5, 0, 0] }, done: false });
    const live = await a.next(ofType('live'));
    assert.equal(live.deviceId, 'iphone-b');
    assert.deepEqual(live.stroke.pts, [1, 2, 0.5, 1.5, 0, 0]);
    a.send({ type: 'presence', deviceId: 'ipad-a', deviceName: 'iPad A', p: project.id, frame: 'f1' });
    const pres = await b.next(ofType('presence'));
    assert.equal(pres.deviceName, 'iPad A');
    assert.equal(pres.frame, 'f1');
    a.send({ type: 'ping' });
    await a.next(ofType('pong'));

    // A device coming back asks for what it missed with hello.since.
    const c = connect(port, tokenA);
    await c.open;
    c.send({ type: 'hello', deviceId: 'ipad-a', deviceName: 'iPad A', since: { [project.id]: ops.length } });
    await c.next(ofType('welcome'));
    const missed = await c.next(ofType('ops'));
    assert.equal(missed.ops.length, editOps.length);
    c.close();

    // Storage keeps only winners: rename 50 times, the log grows by one field.
    const before = hub.store.log(project.id).fields.get(project.id).size;
    const many = [];
    for (let i = 0; i < 50; i++) many.push({ t: clockB.tick(), a: 'iphone-b', o: project.id, k: 'name', v: `Name ${i}` });
    b.send({ type: 'push', p: project.id, ops: many, ref: 'r4' });
    await b.next(ofType('ack', (m) => m.ref === 'r4'));
    assert.equal(hub.store.log(project.id).fields.get(project.id).size, before);
    assert.equal(hub.store.log(project.id).name, 'Name 49');

    // Files: the hub writes Documents/Gale/<Name>.gale/project.json.
    await new Promise((r) => setTimeout(r, 120));
    const folder = path.join(docsDir, 'Name 49.gale');
    assert.ok(fs.existsSync(path.join(folder, 'project.json')), fs.readdirSync(docsDir).join(','));
    const onDisk = JSON.parse(fs.readFileSync(path.join(folder, 'project.json'), 'utf8'));
    assert.equal(onDisk.id, project.id);
    assert.equal(onDisk.format, 'gale/1');

    // Deleting moves the folder to Deleted and hides the project.
    b.send({ type: 'push', p: project.id, ops: [{ t: clockB.tick(), a: 'iphone-b', o: project.id, k: '$del', v: true }], ref: 'r5' });
    await b.next(ofType('ack', (m) => m.ref === 'r5'));
    const gone = await a.next(ofType('projects', (m) => m.projects.length === 0));
    assert.deepEqual(gone.projects, []);
    await new Promise((r) => setTimeout(r, 120));
    assert.ok(!fs.existsSync(folder));
    assert.ok(fs.existsSync(path.join(docsDir, 'Deleted', 'Name 49.gale', 'project.json')));

    // Removing a device closes its socket.
    const closed = new Promise((r) => a.ws.once('close', (code) => r(code)));
    hub.removeDevice('ipad-a');
    assert.equal(await closed, 4001);
    b.close();

    // Everything survives a restart.
    await hub.stop();
    const again = new GaleHub({ dataDir, port: 0, host: '127.0.0.1', serverName: 'Test PC' });
    await again.start();
    try {
      assert.equal(again.serverId, hub.serverId);
      const log = again.store.log(project.id);
      assert.equal(log.seq, hub.store.log(project.id).seq);
      assert.equal(log.deleted, true);
      assert.deepEqual(again.devices().map((d) => d.deviceId), ['iphone-b']);
      const r = await api(`http://127.0.0.1:${again.port}/api/v1`, '/projects', { token: tokenB });
      assert.equal(r.status, 200);
      assert.equal((await api(`http://127.0.0.1:${again.port}/api/v1`, '/projects', { token: tokenA })).status, 401);
    } finally {
      await again.stop();
    }
  } finally {
    await hub.stop().catch(() => {});
  }
});

test('local editor token works but is not a paired device', async () => {
  const { hub, base, port } = await startHub();
  try {
    const token = hub.createLocalToken('desktop-x', 'This computer');
    assert.equal((await api(base, '/projects', { token })).status, 200);
    const c = connect(port, token);
    await c.open;
    c.send({ type: 'hello', deviceId: 'desktop-x', deviceName: 'This computer', since: {} });
    await c.next(ofType('welcome'));
    assert.deepEqual(hub.devices(), []);
    c.close();
  } finally {
    await hub.stop();
  }
});
