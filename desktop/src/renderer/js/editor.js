'use strict';
// The drawing screen: canvas, tools, brush, layers, timeline, onion skin, playback, undo.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { Model, Color, Edits, Onion, Playback, Stabilizer } = window.GaleShared;
  const { el, $, toast, modal, askText, confirmBox, isTyping } = Gale.ui;
  const R = Gale.render;

  const SETTINGS_KEY = 'gale.editor.settings';
  /** Bump when the smoothing math changes so much that an old saved amount would feel wrong. */
  const SMOOTHING_VERSION = 2;
  const PALETTE = ['#000000FF', '#FFFFFFFF', '#6B7280FF', '#EF4444FF', '#F97316FF', '#FACC15FF', '#22C55EFF', '#14B8A6FF',
    '#22D3EEFF', '#3B82F6FF', '#7C3AEDFF', '#EC4899FF', '#92400EFF', '#FDE68AFF'];
  const TOOLS = [
    { id: 'pen', title: 'Pen', svg: '<path d="M4 20l4-1 11-11-3-3L5 16z"/><path d="M14 6l3 3"/>' },
    { id: 'pencil', title: 'Pencil', svg: '<path d="M4 20l1.5-5L16 4.5l3.5 3.5L9 18.5z"/><path d="M4 20l3-1"/><path d="M14 6.5l3.5 3.5"/>' },
    { id: 'marker', title: 'Marker', svg: '<path d="M7 14l7-10 6 4-7 10z"/><path d="M7 14l-2 6 6-2"/>' },
    { id: 'brush', title: 'Ink Brush', svg: '<path d="M20 4c-4 2-8 6-10 10"/><path d="M10 14c-3 0-5 2-5 6 3 0 6-1 6-4"/>' },
    { id: 'airbrush', title: 'Airbrush', svg: '<circle cx="8" cy="8" r="1"/><circle cx="12" cy="6" r="1"/><circle cx="6" cy="12" r="1"/><circle cx="11" cy="11" r="1.5"/><circle cx="15" cy="9" r="1"/><circle cx="9" cy="16" r="1"/><circle cx="14" cy="14" r="1"/><circle cx="18" cy="13" r="1"/><circle cx="13" cy="18" r="1"/>' },
    { id: 'eraser', title: 'Eraser', svg: '<path d="M4 16l9-9 6 6-6 6H8z"/><path d="M9 11l6 6"/><path d="M13 19h7"/>' },
    { sep: true },
    { id: 'hand', title: 'Move', svg: '<path d="M8 12V6a1.5 1.5 0 013 0v5"/><path d="M11 11V4.5a1.5 1.5 0 013 0V11"/><path d="M14 11V6a1.5 1.5 0 013 0v7c0 4-2 7-6 7-3 0-4.5-1.5-6-4l-2-3.5a1.5 1.5 0 012.5-1.5L8 13"/>' },
  ];

  const E = {
    client: null,
    session: null,
    frameIndex: 0,
    frameId: null,
    layerId: null,
    tool: 'pen',
    view: { scale: 1, ox: 0, oy: 0 },
    drawing: null,
    panning: null,
    spaceDown: false,
    playing: false,
    play: null,
    remoteLive: new Map(),
    people: new Map(),
    celCache: new R.CelCache(),
    ghosts: new Map(),
    thumbs: new Map(),
    raf: 0,
    preview: null,
    settings: null,
    active: false,
    onClose: null,
  };

  // ---------- settings ----------

  function loadSettings() {
    let s = {};
    try {
      s = JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}') || {};
    } catch (_) {
      s = {};
    }
    const num = (v, fb, lo, hi) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : fb);
    E.settings = {
      brushKind: Model.BRUSH_KINDS.includes(s.brushKind) && s.brushKind !== 'eraser' ? s.brushKind : 'pen',
      color: Color.normalize(s.color, '#000000FF'),
      size: num(s.size, 8, 1, 200),
      opacity: num(s.opacity, 1, 0.05, 1),
      eraserSize: num(s.eraserSize, 30, 1, 200),
      // The old tuning started at a strong 0.55 that rounded off faces: move everyone to the light default once.
      smoothing: (s.smoothingVersion || 1) < SMOOTHING_VERSION ? Stabilizer.DEFAULT_AMOUNT : num(s.smoothing, Stabilizer.DEFAULT_AMOUNT, 0, 1),
      smoothingVersion: SMOOTHING_VERSION,
      onion: Onion.settings(s.onion),
      recent: Array.isArray(s.recent) ? s.recent.filter((c) => Color.parse(c)).slice(0, 12) : [],
    };
    E.tool = E.settings.brushKind;
  }

  function saveSettings() {
    try {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(E.settings));
    } catch (_) { /* fine */ }
  }

  const project = () => (E.session ? E.session.project : null);

  function currentBrush(forceEraser) {
    const s = E.settings;
    if (forceEraser || E.tool === 'eraser') return { kind: 'eraser', color: '#000000FF', size: s.eraserSize, opacity: 1 };
    return { kind: E.tool === 'hand' ? s.brushKind : E.tool, color: s.color, size: s.size, opacity: s.opacity };
  }

  // ---------- open / close ----------

  function open(client, projectId, onClose) {
    close();
    E.client = client;
    E.onClose = onClose;
    E.session = new Gale.ProjectSession(client, projectId);
    E.session.onChange(onSessionChange);
    E.frameIndex = 0;
    E.frameId = null;
    E.layerId = null;
    E.celCache.clear();
    E.ghosts.clear();
    E.thumbs.clear();
    E.remoteLive.clear();
    E.people.clear();
    E.active = true;
    $('stage-msg').textContent = 'Opening…';
    $('stage-msg').hidden = false;
    $('frames').textContent = '';
    $('layer-list').textContent = '';
    $('ed-name').textContent = '';
    refreshConn();
  }

  function close() {
    stopPlaying();
    if (E.session) {
      E.session.close();
      E.session = null;
    }
    if (E.client) E.client.setPresence(null, null);
    E.active = false;
    E.drawing = null;
  }

  function onSessionChange(info) {
    const p = project();
    if (!p) return;
    if (info.first) {
      $('stage-msg').hidden = true;
      E.layerId = p.layers[p.layers.length - 1].id;
      E.frameIndex = 0;
      E.frameId = p.frames[0].id;
      requestAnimationFrame(fit);
    }
    // Keep the same frame and layer selected when things move around.
    let fi = p.frames.findIndex((f) => f.id === E.frameId);
    if (fi < 0) fi = Math.min(E.frameIndex, p.frames.length - 1);
    E.frameIndex = Math.max(0, fi);
    E.frameId = p.frames[E.frameIndex].id;
    if (!p.layers.some((l) => l.id === E.layerId)) E.layerId = p.layers[p.layers.length - 1].id;
    // A finished remote stroke that is now saved doesn't need its live copy any more.
    for (const [id, live] of E.remoteLive) {
      if (live.done && live.stroke && E.session.replica.objs[live.stroke.id]) E.remoteLive.delete(id);
    }
    if (info.first || !info.remote || info.ops.some((op) => op.o === p.id)) setPresence();
    refreshAll();
  }

  function setPresence() {
    if (E.session && E.frameId) E.client.setPresence(E.session.id, E.frameId);
  }

  // ---------- commits ----------

  function commit(next, opts) {
    if (!E.session || !E.session.loaded) return false;
    next.modified = Model.formatDate(Date.now());
    return E.session.commit(next, opts);
  }

  function undo() {
    if (E.session && E.session.undo()) toast('Undone', 900);
  }

  function redo() {
    if (E.session && E.session.redo()) toast('Redone', 900);
  }

  // ---------- view ----------

  const stage = () => $('stage');
  const viewCanvas = () => $('view');

  function fit() {
    const p = project();
    if (!p) return;
    const r = stage().getBoundingClientRect();
    const pad = 32;
    const s = Math.max(0.02, Math.min((r.width - pad * 2) / p.canvas.width, (r.height - pad * 2) / p.canvas.height));
    E.view.scale = s;
    E.view.ox = (r.width - p.canvas.width * s) / 2;
    E.view.oy = (r.height - p.canvas.height * s) / 2;
    requestRender();
  }

  function zoomAt(factor, sx, sy) {
    const v = E.view;
    const ns = Math.max(0.02, Math.min(32, v.scale * factor));
    const k = ns / v.scale;
    v.ox = sx - (sx - v.ox) * k;
    v.oy = sy - (sy - v.oy) * k;
    v.scale = ns;
    requestRender();
  }

  function toCanvas(clientX, clientY) {
    const r = viewCanvas().getBoundingClientRect();
    return { x: (clientX - r.left - E.view.ox) / E.view.scale, y: (clientY - r.top - E.view.oy) / E.view.scale };
  }

  function requestRender() {
    if (!E.raf) E.raf = requestAnimationFrame(renderNow);
  }

  function checker(ctx, w, h) {
    const size = 16;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = '#e4e4ea';
    for (let y = 0; y < h; y += size) {
      for (let x = (y / size) % 2 ? size : 0; x < w; x += size * 2) ctx.fillRect(x, y, size, size);
    }
  }

  function ghostCanvas(p, fi, side, tint) {
    const frame = p.frames[fi];
    const sig = R.frameSignature(E.session, p, frame) + side;
    const key = `${frame.id}|${side}`;
    let g = E.ghosts.get(key);
    if (g && g.sig === sig) return g.canvas;
    const q = R.CelCache.quality(p) * 0.5;
    const c = (g && g.canvas) || document.createElement('canvas');
    c.width = Math.max(1, Math.round(p.canvas.width * q));
    c.height = Math.max(1, Math.round(p.canvas.height * q));
    R.composeFrame(c, p, fi, { scale: q, background: false, tint });
    g = { sig, canvas: c };
    E.ghosts.set(key, g);
    if (E.ghosts.size > 24) E.ghosts.delete(E.ghosts.keys().next().value);
    return c;
  }

  function liveStrokesFor(frameId, layerId) {
    const out = [];
    const now = performance.now();
    for (const [id, live] of E.remoteLive) {
      if (now - live.at > 4000) {
        E.remoteLive.delete(id);
        continue;
      }
      if (live.frame === frameId && live.layer === layerId && live.stroke) out.push(live.stroke);
    }
    const d = E.drawing;
    if (d && d.frameId === frameId && d.layerId === layerId && d.points.length) out.push({ brush: d.brush, points: d.points });
    return out;
  }

  function renderNow() {
    E.raf = 0;
    const canvas = viewCanvas();
    const p = project();
    const dpr = window.devicePixelRatio || 1;
    const r = stage().getBoundingClientRect();
    const W = Math.max(1, Math.round(r.width * dpr));
    const H = Math.max(1, Math.round(r.height * dpr));
    if (canvas.width !== W || canvas.height !== H) {
      canvas.width = W;
      canvas.height = H;
    }
    const ctx = canvas.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.filter = 'none';
    ctx.clearRect(0, 0, W, H);
    if (!p) return;
    const v = E.view;
    const cw = p.canvas.width;
    const ch = p.canvas.height;
    ctx.setTransform(dpr * v.scale, 0, 0, dpr * v.scale, dpr * v.ox, dpr * v.oy);
    ctx.imageSmoothingQuality = 'high';

    // Paper.
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.45)';
    ctx.shadowBlur = 24 * dpr;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, cw, ch);
    ctx.restore();
    const bg = Color.parse(p.canvas.background);
    if (bg.a < 1) checker(ctx, cw, ch);
    ctx.fillStyle = Color.toCss(p.canvas.background);
    ctx.fillRect(0, 0, cw, ch);

    let fi = E.frameIndex;
    let time = 0;
    if (E.playing) {
      const tick = E.play.startTick + Math.floor(((performance.now() - E.play.t0) / 1000) * p.fps + 1e-9);
      fi = Playback.frameIndexAtTick(tick, p.frames);
      time = tick / Math.max(1, p.fps);
      if (fi !== E.play.shown) {
        E.play.shown = fi;
        markTimelineFrame(fi);
      }
    }
    const frame = p.frames[fi];
    if (!frame) return;

    // Onion skin: frames before in blue, after in orange, frosted.
    if (!E.playing && E.settings.onion.on) {
      for (const g of Onion.ghosts(fi, p.frames.length, E.settings.onion)) {
        const c = ghostCanvas(p, g.frameIndex, g.side, g.tint);
        ctx.save();
        ctx.globalAlpha = g.opacity;
        if (g.blur > 0) ctx.filter = `blur(${(g.blur * dpr).toFixed(2)}px) saturate(0.85) brightness(1.08)`;
        ctx.drawImage(c, 0, 0, cw, ch);
        ctx.restore();
      }
    }

    const hairOn = E.playing && p.hair.some((h) => h.on);
    if (hairOn) {
      const q = R.CelCache.quality(p);
      const c = R.scratch(Math.round(cw * q), Math.round(ch * q), 'play');
      R.composeFrame(c, p, fi, { scale: q, background: false, hair: true, time });
      ctx.drawImage(c, 0, 0, cw, ch);
    } else {
      for (const layer of p.layers) {
        if (!layer.visible) continue;
        let src = E.celCache.get(E.session, p, frame, layer.id);
        const extras = E.playing ? [] : liveStrokesFor(frame.id, layer.id);
        if (extras.length) {
          const q = R.CelCache.quality(p);
          const sc = R.scratch(src.width, src.height, 'live');
          const sctx = sc.getContext('2d');
          sctx.setTransform(1, 0, 0, 1, 0, 0);
          sctx.globalCompositeOperation = 'source-over';
          sctx.clearRect(0, 0, sc.width, sc.height);
          sctx.drawImage(src, 0, 0);
          sctx.setTransform(q, 0, 0, q, 0, 0);
          for (const s of extras) R.drawStroke(sctx, s, { points: s.points });
          src = sc;
        }
        const opacity = E.preview && E.preview.layerId === layer.id ? E.preview.opacity : layer.opacity;
        ctx.globalAlpha = Math.max(0, Math.min(1, opacity));
        ctx.drawImage(src, 0, 0, cw, ch);
        ctx.globalAlpha = 1;
      }
    }

    ctx.lineWidth = 1 / v.scale;
    ctx.strokeStyle = 'rgba(255,255,255,0.12)';
    ctx.strokeRect(0, 0, cw, ch);
    $('ed-zoom').textContent = `${Math.round(v.scale * 100)}%`;
    if (E.playing) requestRender();
  }

  // ---------- drawing input ----------

  function penPoint(e, t0) {
    const c = toCanvas(e.clientX, e.clientY);
    let pressure = 0.5;
    if (e.pointerType === 'pen' || e.pointerType === 'touch') pressure = e.pressure > 0 ? e.pressure : 0.5;
    let altitude = Math.PI / 2;
    let azimuth = 0;
    if (typeof e.altitudeAngle === 'number' && e.pointerType === 'pen') {
      altitude = e.altitudeAngle;
      azimuth = e.azimuthAngle || 0;
    } else if (e.pointerType === 'pen' && (e.tiltX || e.tiltY)) {
      const tx = Math.tan((e.tiltX * Math.PI) / 180);
      const ty = Math.tan((e.tiltY * Math.PI) / 180);
      altitude = Math.atan(1 / Math.max(1e-6, Math.sqrt(tx * tx + ty * ty)));
      azimuth = Math.atan2(ty, tx);
    }
    return { x: c.x, y: c.y, pressure: Math.min(1, Math.max(0, pressure)), altitude, azimuth, time: Math.max(0, (e.timeStamp - t0) / 1000) };
  }

  function sendLive(done) {
    const d = E.drawing;
    if (!d) return;
    const now = performance.now();
    if (!done && now - d.lastLive < 33) return;
    d.lastLive = now;
    E.client.live({
      p: E.session.id,
      frame: d.frameId,
      layer: d.layerId,
      stroke: { id: d.strokeId, key: 'a0', brush: d.brush, pts: Model.packPoints(d.points) },
      done,
    });
  }

  function onPointerDown(e) {
    const p = project();
    if (!p || !E.session.loaded) return;
    const panWanted = e.button === 1 || E.tool === 'hand' || E.spaceDown;
    if (panWanted) {
      E.panning = { id: e.pointerId, x: e.clientX, y: e.clientY, ox: E.view.ox, oy: E.view.oy };
      viewCanvas().setPointerCapture(e.pointerId);
      stage().classList.add('panning');
      e.preventDefault();
      return;
    }
    const penEraser = e.pointerType === 'pen' && (e.button === 5 || (e.buttons & 32) !== 0);
    if (e.button !== 0 && !penEraser) return;
    if (E.drawing) return;
    const layer = p.layers.find((l) => l.id === E.layerId);
    if (!layer) return;
    if (layer.locked) {
      toast('This layer is locked. Unlock it to draw on it.');
      return;
    }
    if (!layer.visible) {
      toast('This layer is hidden. Show it to draw on it.');
      return;
    }
    if (E.playing) stopPlaying();
    e.preventDefault();
    viewCanvas().setPointerCapture(e.pointerId);
    const t0 = e.timeStamp;
    const scale = 1 / E.view.scale;
    const stab = new Stabilizer.StrokeStabilizer(E.settings.smoothing, scale);
    const brush = currentBrush(penEraser);
    const raw = stab.begin(penPoint(e, t0));
    E.drawing = {
      id: e.pointerId,
      t0,
      stab,
      brush,
      scale,
      raw,
      points: raw.slice(),
      strokeId: Model.makeId(),
      frameId: E.frameId,
      layerId: E.layerId,
      lastLive: 0,
    };
    sendLive(false);
    requestRender();
  }

  function onPointerMove(e) {
    if (E.panning && e.pointerId === E.panning.id) {
      E.view.ox = E.panning.ox + (e.clientX - E.panning.x);
      E.view.oy = E.panning.oy + (e.clientY - E.panning.y);
      requestRender();
      return;
    }
    const d = E.drawing;
    if (!d || e.pointerId !== d.id) return;
    const events = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
    for (const ev of events.length ? events : [e]) {
      for (const q of d.stab.add(penPoint(ev, d.t0))) d.raw.push(q);
    }
    // Same finishing step while drawing and when you lift, so the line never jumps.
    d.points = Stabilizer.shape(d.raw, E.settings.smoothing, d.scale);
    sendLive(false);
    requestRender();
  }

  function finishStroke(e, cancelled) {
    const d = E.drawing;
    if (!d || (e && e.pointerId !== d.id)) return;
    E.drawing = null;
    if (cancelled) {
      E.client.live({ p: E.session.id, frame: d.frameId, layer: d.layerId, stroke: { id: d.strokeId, key: 'a0', brush: d.brush, pts: [] }, done: true });
      requestRender();
      return;
    }
    for (const q of d.stab.end()) d.raw.push(q);
    const pts = Stabilizer.shape(d.raw, E.settings.smoothing, d.scale);
    const stroke = { id: d.strokeId, key: 'a0', brush: d.brush, pts: Model.packPoints(pts) };
    E.drawing = { ...d, points: pts };
    sendLive(true);
    E.drawing = null;
    const p = project();
    if (p && p.frames.some((f) => f.id === d.frameId)) commit(Edits.addStroke(p, d.frameId, d.layerId, stroke));
    if (d.brush.kind !== 'eraser') rememberColor(d.brush.color);
    requestRender();
  }

  function onPointerUp(e) {
    if (E.panning && e.pointerId === E.panning.id) {
      E.panning = null;
      stage().classList.remove('panning');
      return;
    }
    finishStroke(e, false);
  }

  function onPointerCancel(e) {
    if (E.panning && e.pointerId === E.panning.id) {
      E.panning = null;
      stage().classList.remove('panning');
      return;
    }
    finishStroke(e, true);
  }

  function onWheel(e) {
    if (!project()) return;
    e.preventDefault();
    const r = viewCanvas().getBoundingClientRect();
    if (e.shiftKey && !e.ctrlKey) {
      E.view.ox -= e.deltaY;
      requestRender();
      return;
    }
    const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015));
    zoomAt(factor, e.clientX - r.left, e.clientY - r.top);
  }

  // ---------- live from other devices ----------

  function onLive(msg) {
    if (!E.session || msg.p !== E.session.id || !msg.deviceId) return;
    if (!msg.stroke || typeof msg.stroke !== 'object' || typeof msg.frame !== 'string' || typeof msg.layer !== 'string') return;
    const s = Model.readStroke(msg.stroke);
    const key = `${msg.deviceId}|${s.id}`;
    if (msg.done && (!s.pts.length || E.session.replica.objs[s.id])) {
      E.remoteLive.delete(key);
    } else {
      E.remoteLive.set(key, {
        frame: msg.frame,
        layer: msg.layer,
        done: !!msg.done,
        at: performance.now(),
        stroke: { id: s.id, brush: s.brush, points: Model.unpackPoints(s.pts) },
      });
    }
    requestRender();
  }

  function onPresence(msg) {
    if (!msg.deviceId || (E.client && msg.deviceId === E.client.deviceId)) return;
    if (!E.session || msg.p !== E.session.id || msg.gone) E.people.delete(msg.deviceId);
    else E.people.set(msg.deviceId, { name: msg.deviceName || 'Device', frame: msg.frame });
    if (E.active) {
      refreshPeople();
      refreshTimeline();
    }
  }

  // ---------- panels ----------

  function refreshAll() {
    const p = project();
    if (!p) return;
    $('ed-name').textContent = p.name;
    $('ed-name').title = 'Rename';
    refreshUndo();
    refreshLayers();
    refreshTimeline();
    refreshPeople();
    requestRender();
  }

  function refreshUndo() {
    $('ed-undo').disabled = !(E.session && E.session.canUndo);
    $('ed-redo').disabled = !(E.session && E.session.canRedo);
  }

  function refreshConn() {
    const c = $('ed-conn');
    const ok = E.client && E.client.connected;
    c.className = `conn ${ok ? 'ok' : 'bad'}`;
    c.textContent = ok ? 'Saved' : 'Reconnecting…';
    if (ok && E.client.pending.size) c.textContent = 'Saving…';
  }

  function refreshPeople() {
    const box = $('ed-people');
    box.textContent = '';
    const p = project();
    for (const person of E.people.values()) {
      const idx = p ? p.frames.findIndex((f) => f.id === person.frame) : -1;
      box.appendChild(el('span', { class: 'person', title: 'Also drawing here', text: idx >= 0 ? `${person.name} · frame ${idx + 1}` : person.name }));
    }
  }

  function renderTools() {
    const nav = $('ed-tools');
    nav.textContent = '';
    for (const t of TOOLS) {
      if (t.sep) {
        nav.appendChild(el('div', { class: 'tool-sep' }));
        continue;
      }
      const b = el('button', { class: `tool${E.tool === t.id ? ' on' : ''}`, title: t.title, onclick: () => setTool(t.id) });
      b.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${t.svg}</svg>`;
      b.appendChild(el('span', { text: t.title }));
      nav.appendChild(b);
    }
  }

  function setTool(id) {
    E.tool = id;
    if (id !== 'eraser' && id !== 'hand') E.settings.brushKind = id;
    saveSettings();
    renderTools();
    refreshBrush();
    stage().classList.toggle('pan', id === 'hand');
  }

  function refreshBrush() {
    const s = E.settings;
    $('br-color').value = Color.toInputValue(s.color);
    const size = E.tool === 'eraser' ? s.eraserSize : s.size;
    $('br-size').value = String(Math.round(size));
    $('br-size-out').textContent = String(Math.round(size));
    $('br-opacity').value = String(Math.round(s.opacity * 100));
    $('br-opacity-out').textContent = `${Math.round(s.opacity * 100)}%`;
    $('br-opacity').disabled = E.tool === 'eraser';
    $('br-smooth').value = String(Math.round(s.smoothing * 100));
    $('br-smooth-out').textContent = Stabilizer.label(s.smoothing);
    const sw = $('br-swatches');
    sw.textContent = '';
    for (const c of PALETTE) sw.appendChild(el('button', { class: 'swatch', title: c.slice(0, 7), style: `background:${Color.toCss(c)}`, onclick: () => pickColor(c) }));
    const rc = $('br-recent');
    rc.textContent = '';
    for (const c of s.recent) rc.appendChild(el('button', { class: 'swatch', title: c.slice(0, 7), style: `background:${Color.toCss(c)}`, onclick: () => pickColor(c) }));
    const onion = $('ed-onion');
    onion.classList.toggle('on', s.onion.on);
  }

  function pickColor(c) {
    E.settings.color = Color.normalize(c);
    if (E.tool === 'eraser' || E.tool === 'hand') setTool(E.settings.brushKind);
    saveSettings();
    refreshBrush();
  }

  function rememberColor(c) {
    const s = E.settings;
    s.recent = [c, ...s.recent.filter((x) => x !== c)].slice(0, 12);
    saveSettings();
    const rc = $('br-recent');
    rc.textContent = '';
    for (const x of s.recent) rc.appendChild(el('button', { class: 'swatch', title: x.slice(0, 7), style: `background:${Color.toCss(x)}`, onclick: () => pickColor(x) }));
  }

  function currentLayer() {
    const p = project();
    return p && p.layers.find((l) => l.id === E.layerId);
  }

  function refreshLayers() {
    const p = project();
    const list = $('layer-list');
    list.textContent = '';
    if (!p) return;
    for (let i = p.layers.length - 1; i >= 0; i--) {
      const l = p.layers[i];
      const row = el('div', { class: `layer${l.id === E.layerId ? ' on' : ''}`, onclick: () => selectLayer(l.id), ondblclick: () => renameLayer(l.id) },
        el('button', { class: `lbtn${l.visible ? '' : ' off'}`, title: l.visible ? 'Hide layer' : 'Show layer', text: '👁', onclick: (e) => { e.stopPropagation(); toggleLayer(l.id, 'visible'); } }),
        el('button', { class: `lbtn${l.locked ? '' : ' off'}`, title: l.locked ? 'Unlock layer' : 'Lock layer', text: l.locked ? '🔒' : '🔓', onclick: (e) => { e.stopPropagation(); toggleLayer(l.id, 'locked'); } }),
        el('span', { class: 'lname', text: l.name }));
      list.appendChild(row);
    }
    const cur = currentLayer();
    const op = cur ? Math.round(cur.opacity * 100) : 100;
    if (!E.preview) {
      $('layer-opacity').value = String(op);
      $('layer-opacity-out').textContent = `${op}%`;
    }
    const idx = p.layers.findIndex((l) => l.id === E.layerId);
    $('layer-up').disabled = idx < 0 || idx >= p.layers.length - 1;
    $('layer-down').disabled = idx <= 0;
    $('layer-del').disabled = p.layers.length <= 1;
  }

  function selectLayer(id) {
    E.layerId = id;
    refreshLayers();
  }

  function toggleLayer(id, field) {
    const p = project();
    const l = p.layers.find((x) => x.id === id);
    if (!l) return;
    commit(Edits.updateLayer(p, id, { [field]: !l[field] }));
  }

  async function renameLayer(id) {
    const p = project();
    const l = p && p.layers.find((x) => x.id === id);
    if (!l) return;
    const name = await askText('Rename layer', l.name, { okText: 'Rename', maxLength: 60 });
    if (name && project()) commit(Edits.updateLayer(project(), id, { name }));
  }

  function addLayer() {
    const p = project();
    const idx = p.layers.findIndex((l) => l.id === E.layerId);
    const { project: next, layer } = Edits.addLayer(p, `Layer ${p.layers.length + 1}`, idx);
    E.layerId = layer.id;
    commit(next);
  }

  async function deleteLayer() {
    const p = project();
    const l = currentLayer();
    if (!l || p.layers.length <= 1) return;
    const hasDrawing = p.frames.some((f) => !R.celEmpty(f.cels[l.id]));
    if (hasDrawing && !(await confirmBox(`Delete "${l.name}"?`, 'Its drawings on every frame go too. You can undo this.', { okText: 'Delete', danger: true }))) return;
    const idx = p.layers.findIndex((x) => x.id === l.id);
    const next = Edits.deleteLayer(project(), l.id);
    E.layerId = next.layers[Math.max(0, Math.min(idx - 1, next.layers.length - 1))].id;
    commit(next);
  }

  function moveLayer(dir) {
    const p = project();
    const i = p.layers.findIndex((l) => l.id === E.layerId);
    if (i < 0) return;
    commit(Edits.moveLayer(p, i, i + dir));
  }

  // ---------- timeline ----------

  function thumbSize(p) {
    const h = 64;
    const w = Math.max(36, Math.min(130, Math.round((h * p.canvas.width) / p.canvas.height)));
    return { w, h: Math.round((w * p.canvas.height) / p.canvas.width) };
  }

  let thumbTimer = 0;
  function refreshTimeline() {
    const p = project();
    const box = $('frames');
    if (!p) return;
    const { w, h } = thumbSize(p);
    const here = new Set([...E.people.values()].map((x) => x.frame));
    const items = box.children;
    // Reuse elements when the count matches, so scrolling stays put.
    while (items.length > p.frames.length) box.lastChild.remove();
    for (let i = 0; i < p.frames.length; i++) {
      const f = p.frames[i];
      let item = items[i];
      if (!item) {
        const c = el('canvas', { width: String(w), height: String(h) });
        item = el('div', { class: 'frame' }, c, el('span', { class: 'num' }), el('span', { class: 'hold-badge' }), el('span', { class: 'here' }));
        item.addEventListener('click', () => selectFrame(Number(item.dataset.index)));
        box.appendChild(item);
      }
      item.dataset.index = String(i);
      item.dataset.id = f.id;
      item.classList.toggle('on', i === E.frameIndex);
      item.querySelector('.num').textContent = String(i + 1);
      const badge = item.querySelector('.hold-badge');
      badge.textContent = `×${f.hold}`;
      badge.hidden = f.hold <= 1;
      item.querySelector('.here').hidden = !here.has(f.id);
      item.title = f.hold > 1 ? `Frame ${i + 1}, stays for ${f.hold} ticks` : `Frame ${i + 1}`;
      const c = item.querySelector('canvas');
      if (c.width !== w || c.height !== h) {
        c.width = w;
        c.height = h;
        delete c.dataset.sig;
      }
    }
    const cur = items[E.frameIndex];
    if (cur) cur.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    $('fr-hold').textContent = String(p.frames[E.frameIndex].hold);
    $('fr-hold-dn').disabled = p.frames[E.frameIndex].hold <= 1;
    $('fr-left').disabled = E.frameIndex <= 0;
    $('fr-right').disabled = E.frameIndex >= p.frames.length - 1;
    $('fr-pos').textContent = `Frame ${E.frameIndex + 1} of ${p.frames.length} · ${(Playback.totalTicks(p.frames) / p.fps).toFixed(2)} s`;
    if (document.activeElement !== $('fps')) $('fps').value = String(p.fps);
    clearTimeout(thumbTimer);
    thumbTimer = setTimeout(drawThumbs, 120);
  }

  function drawThumbs() {
    const p = project();
    if (!p) return;
    const items = $('frames').children;
    const started = performance.now();
    for (let i = 0; i < p.frames.length && i < items.length; i++) {
      const c = items[i].querySelector('canvas');
      const sig = R.frameSignature(E.session, p, p.frames[i]);
      if (c.dataset.sig === sig) continue;
      R.composeFrame(c, p, i, { scale: c.width / p.canvas.width });
      c.dataset.sig = sig;
      // Big animations: draw the rest a moment later so the window stays quick.
      if (performance.now() - started > 40) {
        thumbTimer = setTimeout(drawThumbs, 16);
        return;
      }
    }
  }

  function markTimelineFrame(fi) {
    for (const item of $('frames').children) item.classList.toggle('on', Number(item.dataset.index) === fi);
  }

  function selectFrame(i) {
    const p = project();
    if (!p || i < 0 || i >= p.frames.length) return;
    if (E.playing) stopPlaying();
    E.frameIndex = i;
    E.frameId = p.frames[i].id;
    setPresence();
    refreshTimeline();
    requestRender();
  }

  function goFrame(i) {
    selectFrame(i);
  }

  function addFrame() {
    const r = Edits.insertFrame(project(), Model.newFrame(), E.frameIndex);
    E.frameIndex = r.index;
    E.frameId = r.project.frames[r.index].id;
    commit(r.project);
    setPresence();
  }

  function duplicateFrame() {
    const r = Edits.duplicateFrame(project(), E.frameIndex);
    E.frameIndex = r.index;
    E.frameId = r.project.frames[r.index].id;
    commit(r.project);
    setPresence();
  }

  async function deleteFrame() {
    const p = project();
    if (p.frames.length <= 1) {
      if (!(await confirmBox('Clear this frame?', 'It\'s the only frame, so its drawing is wiped instead. You can undo this.', { okText: 'Clear', danger: true }))) return;
      commit(Edits.deleteFrame(project(), 0));
      return;
    }
    const i = E.frameIndex;
    const next = Edits.deleteFrame(p, i);
    E.frameIndex = Math.min(i, next.frames.length - 1);
    E.frameId = next.frames[E.frameIndex].id;
    commit(next);
    setPresence();
  }

  function moveFrame(dir) {
    const p = project();
    const i = E.frameIndex;
    if (i + dir < 0 || i + dir >= p.frames.length) return;
    commit(Edits.moveFrame(p, i, i + dir));
  }

  function changeHold(delta) {
    const p = project();
    const f = p.frames[E.frameIndex];
    commit(Edits.setHold(p, E.frameIndex, f.hold + delta));
  }

  // ---------- playback ----------

  function togglePlay() {
    if (E.playing) stopPlaying();
    else startPlaying();
  }

  function startPlaying() {
    const p = project();
    if (!p || E.drawing) return;
    E.playing = true;
    E.play = { t0: performance.now(), startTick: Playback.tickStarts(p.frames)[E.frameIndex] || 0, shown: E.frameIndex };
    $('ed-play').textContent = '■ Stop';
    $('ed-play').classList.add('on');
    requestRender();
  }

  function stopPlaying() {
    if (!E.playing) return;
    const shown = E.play ? E.play.shown : E.frameIndex;
    E.playing = false;
    E.play = null;
    $('ed-play').textContent = '▶ Play';
    $('ed-play').classList.remove('on');
    const p = project();
    if (p && shown >= 0 && shown < p.frames.length) {
      E.frameIndex = shown;
      E.frameId = p.frames[shown].id;
      setPresence();
    }
    refreshTimeline();
    requestRender();
  }

  // ---------- onion skin settings ----------

  function onionSettings() {
    const o = { ...E.settings.onion };
    const apply = () => {
      E.settings.onion = Onion.settings(o);
      saveSettings();
      refreshBrush();
      requestRender();
    };
    const num = (label, key, min, max, step = 1, percent = false) => {
      const out = el('output');
      const show = () => { out.textContent = percent ? `${Math.round(o[key] * 100)}%` : String(o[key]); };
      const input = el('input', {
        type: 'range', min: String(min), max: String(max), step: String(step), value: String(o[key]),
        oninput: (e) => {
          o[key] = Number(e.target.value);
          show();
          apply();
        },
      });
      show();
      return el('label', { class: 'slider' }, el('span', { text: label }), input, out);
    };
    const check = (label, key) => el('label', { class: 'check' },
      el('input', { type: 'checkbox', checked: o[key], onchange: (e) => { o[key] = e.target.checked; apply(); } }), label);
    modal((close) => [
      el('h2', { text: 'Onion skin' }),
      el('p', { text: 'See nearby frames faintly while you draw. Frames before are blue, frames after are orange.' }),
      check('Show onion skin', 'on'),
      num('Frames before', 'before', 0, 5),
      num('Frames after', 'after', 0, 5),
      num('Strength', 'opacity', 0.05, 1, 0.05, true),
      check('Frosted (soft and blurry, so it doesn\'t get in the way)', 'frosted'),
      num('Blur', 'blur', 0, 12, 0.5),
      check('Wrap around at the ends (good for loops)', 'wrap'),
      el('div', { class: 'buttons' }, el('button', { class: 'btn primary', text: 'Done', onclick: () => close(true) })),
    ]);
  }

  // ---------- naming ----------

  async function renameProject() {
    const p = project();
    if (!p) return;
    const name = await askText('Rename drawing', p.name, { okText: 'Rename', maxLength: 80 });
    if (name && project()) commit(Edits.setProject(project(), { name }));
  }

  // ---------- keyboard ----------

  function onKeyDown(e) {
    if (!E.active || isTyping(e) || document.querySelector('.modal-back')) return;
    const ctrl = e.ctrlKey || e.metaKey;
    const k = e.key.toLowerCase();
    if (ctrl && k === 'z' && !e.shiftKey) { e.preventDefault(); undo(); return; }
    if (ctrl && (k === 'y' || (k === 'z' && e.shiftKey))) { e.preventDefault(); redo(); return; }
    if (ctrl) return;
    const p = project();
    if (!p) return;
    switch (e.key) {
      case ' ':
        if (!E.spaceDown) {
          E.spaceDown = true;
          stage().classList.add('pan');
        }
        e.preventDefault();
        break;
      case 'Enter': e.preventDefault(); togglePlay(); break;
      case 'ArrowLeft': case ',': e.preventDefault(); goFrame(Math.max(0, E.frameIndex - 1)); break;
      case 'ArrowRight': case '.': e.preventDefault(); goFrame(Math.min(p.frames.length - 1, E.frameIndex + 1)); break;
      case '[': changeSize(-1); break;
      case ']': changeSize(1); break;
      case '0': fit(); break;
      case '=': case '+': { const r = stage().getBoundingClientRect(); zoomAt(1.25, r.width / 2, r.height / 2); break; }
      case '-': { const r = stage().getBoundingClientRect(); zoomAt(0.8, r.width / 2, r.height / 2); break; }
      default:
        if (k === 'b') setTool(E.settings.brushKind);
        else if (k === 'e') setTool('eraser');
        else if (k === 'h') setTool('hand');
        else if (k === 'n') addFrame();
        else if (k === 'd') duplicateFrame();
        else if (k === 'o') toggleOnion();
    }
  }

  function onKeyUp(e) {
    if (e.key === ' ') {
      E.spaceDown = false;
      if (E.tool !== 'hand') stage().classList.remove('pan');
    }
  }

  function changeSize(dir) {
    const s = E.settings;
    const key = E.tool === 'eraser' ? 'eraserSize' : 'size';
    const v = s[key];
    s[key] = Math.max(1, Math.min(200, Math.round(dir > 0 ? v * 1.15 + 1 : v / 1.15 - 0.5)));
    saveSettings();
    refreshBrush();
  }

  function toggleOnion() {
    E.settings.onion = { ...E.settings.onion, on: !E.settings.onion.on };
    saveSettings();
    refreshBrush();
    requestRender();
  }

  // ---------- wiring ----------

  function init() {
    loadSettings();
    renderTools();
    refreshBrush();
    const canvas = viewCanvas();
    canvas.addEventListener('pointerdown', onPointerDown);
    canvas.addEventListener('pointermove', onPointerMove);
    canvas.addEventListener('pointerup', onPointerUp);
    canvas.addEventListener('pointercancel', onPointerCancel);
    canvas.addEventListener('lostpointercapture', (e) => {
      if (E.drawing && e.pointerId === E.drawing.id) finishStroke(e, false);
    });
    canvas.addEventListener('wheel', onWheel, { passive: false });
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    new ResizeObserver(() => requestRender()).observe(stage());
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    window.addEventListener('blur', () => {
      E.spaceDown = false;
      if (E.tool !== 'hand') stage().classList.remove('pan');
    });

    $('ed-back').onclick = () => {
      const done = E.onClose;
      close();
      if (done) done();
    };
    $('ed-name').onclick = renameProject;
    $('ed-undo').onclick = undo;
    $('ed-redo').onclick = redo;
    $('ed-play').onclick = togglePlay;
    $('ed-onion').onclick = toggleOnion;
    $('ed-onion-set').onclick = onionSettings;
    $('ed-fit').onclick = fit;
    $('ed-export').onclick = () => {
      if (project()) Gale.exporter.show(project(), E.session);
    };

    $('br-color').addEventListener('input', (e) => {
      E.settings.color = Color.normalize(e.target.value);
      if (E.tool === 'eraser' || E.tool === 'hand') setTool(E.settings.brushKind);
      saveSettings();
    });
    $('br-color').addEventListener('change', (e) => rememberColor(Color.normalize(e.target.value)));
    $('br-size').addEventListener('input', (e) => {
      const v = Number(e.target.value);
      if (E.tool === 'eraser') E.settings.eraserSize = v;
      else E.settings.size = v;
      $('br-size-out').textContent = String(v);
      saveSettings();
    });
    $('br-opacity').addEventListener('input', (e) => {
      E.settings.opacity = Number(e.target.value) / 100;
      $('br-opacity-out').textContent = `${e.target.value}%`;
      saveSettings();
    });
    $('br-smooth').addEventListener('input', (e) => {
      E.settings.smoothing = Number(e.target.value) / 100;
      $('br-smooth-out').textContent = Stabilizer.label(E.settings.smoothing);
      saveSettings();
    });

    $('layer-opacity').addEventListener('input', (e) => {
      if (!E.layerId) return;
      E.preview = { layerId: E.layerId, opacity: Number(e.target.value) / 100 };
      $('layer-opacity-out').textContent = `${e.target.value}%`;
      requestRender();
    });
    $('layer-opacity').addEventListener('change', (e) => {
      const p = project();
      E.preview = null;
      if (p && E.layerId) commit(Edits.updateLayer(p, E.layerId, { opacity: Number(e.target.value) / 100 }));
      requestRender();
    });
    $('layer-add').onclick = addLayer;
    $('layer-del').onclick = deleteLayer;
    $('layer-up').onclick = () => moveLayer(1);
    $('layer-down').onclick = () => moveLayer(-1);
    $('layer-rename').onclick = () => E.layerId && renameLayer(E.layerId);

    $('fr-add').onclick = addFrame;
    $('fr-dup').onclick = duplicateFrame;
    $('fr-del').onclick = deleteFrame;
    $('fr-left').onclick = () => moveFrame(-1);
    $('fr-right').onclick = () => moveFrame(1);
    $('fr-hold-dn').onclick = () => changeHold(-1);
    $('fr-hold-up').onclick = () => changeHold(1);
    $('fps').addEventListener('change', (e) => {
      const p = project();
      const v = Math.round(Number(e.target.value));
      if (!p || !Number.isFinite(v)) return;
      const fps = Math.max(1, Math.min(60, v));
      e.target.value = String(fps);
      if (fps !== p.fps) commit(Edits.setProject(p, { fps }));
    });
  }

  function attach(client) {
    client.on('live', onLive);
    client.on('presence', onPresence);
    client.on('status', () => E.active && refreshConn());
    client.on('saved', () => {
      if (!E.active) return;
      refreshConn();
      refreshUndo();
    });
  }

  Gale.editor = { init, attach, open, close, requestRender, get isOpen() { return E.active; }, get projectId() { return E.session ? E.session.id : null; } };
})();
