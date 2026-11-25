'use strict';
// Pixel Storytime: a pixel-art editor (grid, palette, frames, onion skin) plus a storyboard that chains
// scenes with captions and speech bubbles, a retro player, and GIF / sprite sheet / PNG export.
// Same story format and sync objects as the iPad app, so edits show up on both.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { Model, Color, Pixel, PixelStory, PixelGif } = window.GaleShared;
  const { el, $, toast, modal, askText, confirmBox, isTyping } = Gale.ui;

  const SETTINGS_KEY = 'gale.pixel.settings';
  const MAX_ZOOM = 64;
  const MAX_HOLD = 60;
  const TOOL_KEYS = { b: 'pencil', e: 'eraser', g: 'fill', l: 'line', r: 'rect', c: 'circle', i: 'picker', m: 'move' };
  const TOOL_ICONS = {
    pencil: '<path d="M4 20l1.5-5L16 4.5l3.5 3.5L9 18.5z"/><path d="M14 6.5l3.5 3.5"/>',
    eraser: '<path d="M4 16l9-9 6 6-6 6H8z"/><path d="M9 11l6 6"/>',
    fill: '<path d="M5 12l7-7 7 7-7 7z"/><path d="M19 15c1 2 2 3 2 4a2 2 0 01-4 0c0-1 1-2 2-4z"/>',
    line: '<path d="M5 19L19 5"/><rect x="3" y="17" width="4" height="4"/><rect x="17" y="3" width="4" height="4"/>',
    rect: '<rect x="4" y="6" width="16" height="12"/>',
    circle: '<circle cx="12" cy="12" r="8"/>',
    picker: '<path d="M14 4l6 6-2 2-6-6z"/><path d="M12 8l-7 7v4h4l7-7"/>',
    move: '<path d="M12 3v18M3 12h18"/><path d="M9 6l3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3"/>',
  };
  const GRID_SIZES = [
    ['Tiny', 16, 16],
    ['Classic', 32, 32],
    ['Wide', 64, 36],
    ['Tall', 36, 64],
    ['Detailed', 64, 64],
    ['Huge', 128, 128],
  ];

  const X = {
    client: null,
    session: null,
    onClose: null,
    active: false,
    sceneId: null,
    frameId: null,
    s: 0,
    f: 0,
    settings: null,
    view: { z: 8, ox: 0, oy: 0, fitted: false },
    drawing: null,
    panning: null,
    spaceDown: false,
    hover: null,
    playing: null,
    raf: 0,
    off: null,
    thumbs: new WeakMap(),
    people: new Map(),
    board: null,
    player: null,
  };

  // ---------- settings ----------

  function loadSettings() {
    let s = {};
    try {
      s = JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}') || {};
    } catch (_) {
      s = {};
    }
    const num = (v, fb, lo, hi) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, Math.round(v))) : fb);
    const o = s.onion && typeof s.onion === 'object' ? s.onion : {};
    X.settings = {
      tool: Pixel.TOOLS.includes(s.tool) ? s.tool : 'pencil',
      color: num(s.color, 1, 1, Pixel.MAX_COLORS - 1),
      size: num(s.size, 1, 1, 4),
      mirrorX: !!s.mirrorX,
      mirrorY: !!s.mirrorY,
      filled: !!s.filled,
      grid: s.grid !== false,
      onion: {
        on: !!o.on,
        before: num(o.before, 1, 0, 3),
        after: num(o.after, 1, 0, 3),
        opacity: typeof o.opacity === 'number' && Number.isFinite(o.opacity) ? Math.min(0.9, Math.max(0.1, o.opacity)) : 0.5,
      },
    };
  }

  function saveSettings() {
    try {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(X.settings));
    } catch (_) { /* fine */ }
  }

  // ---------- the story ----------

  const project = () => (X.session ? X.session.project : null);
  const story = () => {
    const p = project();
    return p && p.pixel ? p.pixel : null;
  };
  const scene = () => {
    const st = story();
    return st ? st.scenes[X.s] : null;
  };
  const frame = () => {
    const sc = scene();
    return sc ? sc.frames[X.f] : null;
  };

  /** Edits a copy of the story with `mutate` (return false to skip) and saves it. */
  function commitStory(mutate, { canvas = false, undoable = true } = {}) {
    const p = project();
    if (!p || !p.pixel || !X.session.loaded) return false;
    const st = Pixel.editableCopy(p.pixel);
    if (mutate(st) === false) return false;
    Pixel.normalize(st);
    const next = { ...p, pixel: st, modified: Model.formatDate(Date.now()) };
    if (canvas) next.canvas = Pixel.pixelCanvas(st);
    return X.session.commit(next, { undoable });
  }

  function findScene(st, id) {
    return st.scenes.find((sc) => sc.id === id) || null;
  }

  function commitCells(sceneId, frameId, cells) {
    return commitStory((st) => {
      const sc = findScene(st, sceneId);
      const fr = sc && sc.frames.find((f) => f.id === frameId);
      if (!fr) return false;
      fr.cells = cells;
      return true;
    });
  }

  function commitScene(sceneId, change) {
    return commitStory((st) => {
      const sc = findScene(st, sceneId);
      if (!sc) return false;
      return change(sc, st) !== false;
    });
  }

  // ---------- open / close ----------

  function open(client, projectId, onClose) {
    close();
    X.client = client;
    X.onClose = onClose;
    X.session = new Gale.ProjectSession(client, projectId);
    X.session.onChange(onSessionChange);
    X.s = 0;
    X.f = 0;
    X.sceneId = null;
    X.frameId = null;
    X.view.fitted = false;
    X.people.clear();
    X.active = true;
    $('px-msg').textContent = 'Opening…';
    $('px-msg').hidden = false;
    $('px-frames').textContent = '';
    $('px-scenes').textContent = '';
    $('px-name').textContent = '';
    refreshConn();
    playIntro();
  }

  function close() {
    stopPlaying();
    closeBoard();
    closePlayer();
    if (X.session) {
      X.session.close();
      X.session = null;
    }
    if (X.client) X.client.setPresence(null, null);
    X.active = false;
    X.drawing = null;
    X.panning = null;
  }

  /** The "power on" sweep when the pixel screen opens. */
  function playIntro() {
    const s = $('pixel');
    s.classList.remove('px-boot');
    void s.offsetWidth;
    s.classList.add('px-boot');
  }

  function onSessionChange(info) {
    const p = project();
    if (!p) return;
    if (!p.pixel) {
      // Not a pixel story (it never was, or another device changed it): use the drawing editor.
      if (info.first && Gale.openProject) Gale.openProject(X.session.id, X.onClose, 'drawing');
      return;
    }
    const st = p.pixel;
    if (info.first) $('px-msg').hidden = true;
    // Keep the same scene and frame when things move around.
    let si = st.scenes.findIndex((sc) => sc.id === X.sceneId);
    if (si < 0) si = Math.min(X.s, st.scenes.length - 1);
    X.s = Math.max(0, si);
    const sc = st.scenes[X.s];
    let fi = sc.frames.findIndex((f) => f.id === X.frameId);
    if (fi < 0) fi = Math.min(X.f, sc.frames.length - 1);
    X.f = Math.max(0, fi);
    X.sceneId = sc.id;
    X.frameId = sc.frames[X.f].id;
    if (X.settings.color >= st.palette.length) X.settings.color = st.palette.length - 1;
    if (!X.view.fitted) requestAnimationFrame(fit);
    setPresence();
    refreshAll();
    if (X.board && !X.board.drag) renderBoard();
  }

  function setPresence() {
    if (X.session && X.frameId) X.client.setPresence(X.session.id, X.frameId);
  }

  function select(s, f) {
    const st = story();
    if (!st) return;
    X.s = Math.min(Math.max(0, s), st.scenes.length - 1);
    const sc = st.scenes[X.s];
    X.f = Math.min(Math.max(0, f), sc.frames.length - 1);
    X.sceneId = sc.id;
    X.frameId = sc.frames[X.f].id;
    setPresence();
    refreshAll();
  }

  // ---------- view ----------

  const stageEl = () => $('px-stage');
  const viewCanvas = () => $('px-view');

  function fit() {
    const st = story();
    if (!st) return;
    const r = stageEl().getBoundingClientRect();
    if (r.width < 10 || r.height < 10) return;
    const z = Math.max(1, Math.min(MAX_ZOOM, Math.floor(Math.min((r.width - 48) / st.width, (r.height - 48) / st.height))));
    X.view.z = z;
    X.view.ox = Math.round((r.width - st.width * z) / 2);
    X.view.oy = Math.round((r.height - st.height * z) / 2);
    X.view.fitted = true;
    refreshZoom();
    requestRender();
  }

  function zoomAt(dir, sx, sy) {
    const v = X.view;
    const z = Math.max(1, Math.min(MAX_ZOOM, dir > 0 ? Math.max(v.z + 1, Math.round(v.z * 1.25)) : Math.min(v.z - 1, Math.round(v.z / 1.25))));
    if (z === v.z) return;
    // Keep the cell under the pointer in place.
    const cx = (sx - v.ox) / v.z;
    const cy = (sy - v.oy) / v.z;
    v.z = z;
    v.ox = Math.round(sx - cx * z);
    v.oy = Math.round(sy - cy * z);
    refreshZoom();
    requestRender();
  }

  function refreshZoom() {
    $('px-zoom').textContent = `${X.view.z}×`;
  }

  function cellAt(e) {
    const r = viewCanvas().getBoundingClientRect();
    return {
      x: Math.floor((e.clientX - r.left - X.view.ox) / X.view.z),
      y: Math.floor((e.clientY - r.top - X.view.oy) / X.view.z),
    };
  }

  // ---------- drawing on screen ----------

  function requestRender() {
    if (!X.raf) X.raf = requestAnimationFrame(renderNow);
  }

  /** An RGBA picture from the shared code into a canvas (made or reused). */
  function toCanvas(img, canvas) {
    const c = canvas || document.createElement('canvas');
    if (c.width !== img.width) c.width = img.width;
    if (c.height !== img.height) c.height = img.height;
    const data = new Uint8ClampedArray(img.data.buffer, img.data.byteOffset, img.data.length);
    c.getContext('2d').putImageData(new ImageData(data, img.width, img.height), 0, 0);
    return c;
  }

  /** The story with the frame being drawn swapped for the stroke in progress. */
  function storyForScreen() {
    const st = story();
    const d = X.drawing;
    if (!st || !d) return st;
    return {
      ...st,
      scenes: st.scenes.map((sc) => (sc.id !== d.sceneId ? sc : {
        ...sc,
        frames: sc.frames.map((f) => (f.id !== d.frameId ? f : { ...f, cells: d.grid.cells })),
      })),
    };
  }

  function renderNow() {
    X.raf = 0;
    if (!X.active) return;
    const canvas = viewCanvas();
    const stage = stageEl();
    const W = stage.clientWidth;
    const H = stage.clientHeight;
    const dpr = window.devicePixelRatio || 1;
    const bw = Math.max(1, Math.round(W * dpr));
    const bh = Math.max(1, Math.round(H * dpr));
    if (canvas.width !== bw || canvas.height !== bh) {
      canvas.width = bw;
      canvas.height = bh;
    }
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    const st = storyForScreen();
    if (!st) return;
    const { z, ox, oy } = X.view;
    const w = st.width * z;
    const h = st.height * z;

    // Checkerboard shows where the paper is see-through.
    ctx.fillStyle = '#2a2a3a';
    ctx.fillRect(ox, oy, w, h);
    ctx.fillStyle = '#34344a';
    const check = Math.max(4, z);
    for (let y = 0; y * check < h; y++) {
      for (let x = (y % 2); x * check < w; x += 2) ctx.fillRect(ox + x * check, oy + y * check, Math.min(check, w - x * check), Math.min(check, h - y * check));
    }

    const onion = X.playing ? { on: false } : X.settings.onion;
    const img = Pixel.editorFrame(st, X.s, X.f, onion);
    X.off = toCanvas(img, X.off);
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(X.off, ox, oy, w, h);

    if (X.settings.grid && z >= 6 && !X.playing) {
      ctx.strokeStyle = z >= 14 ? 'rgba(255,255,255,0.13)' : 'rgba(255,255,255,0.08)';
      ctx.lineWidth = 1 / dpr;
      ctx.beginPath();
      for (let x = 1; x < st.width; x++) {
        ctx.moveTo(ox + x * z + 0.5 / dpr, oy);
        ctx.lineTo(ox + x * z + 0.5 / dpr, oy + h);
      }
      for (let y = 1; y < st.height; y++) {
        ctx.moveTo(ox, oy + y * z + 0.5 / dpr);
        ctx.lineTo(ox + w, oy + y * z + 0.5 / dpr);
      }
      ctx.stroke();
    }

    // Mirror lines.
    ctx.strokeStyle = 'rgba(34,211,238,0.7)';
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 4]);
    if (X.settings.mirrorX) {
      ctx.beginPath();
      ctx.moveTo(ox + w / 2, oy - 8);
      ctx.lineTo(ox + w / 2, oy + h + 8);
      ctx.stroke();
    }
    if (X.settings.mirrorY) {
      ctx.beginPath();
      ctx.moveTo(ox - 8, oy + h / 2);
      ctx.lineTo(ox + w + 8, oy + h / 2);
      ctx.stroke();
    }
    ctx.setLineDash([]);

    // The cell(s) under the pointer.
    const hv = X.hover;
    if (hv && !X.playing && !X.panning && hv.x >= 0 && hv.y >= 0 && hv.x < st.width && hv.y < st.height) {
      const t = X.settings.tool;
      const size = t === 'pencil' || t === 'eraser' ? X.settings.size : 1;
      const start = -Math.trunc((size - 1) / 2);
      ctx.strokeStyle = '#fff';
      ctx.lineWidth = 1.5;
      ctx.strokeRect(ox + (hv.x + start) * z + 0.75, oy + (hv.y + start) * z + 0.75, size * z - 1.5, size * z - 1.5);
      ctx.strokeStyle = '#000';
      ctx.lineWidth = 1;
      ctx.strokeRect(ox + (hv.x + start) * z - 0.5, oy + (hv.y + start) * z - 0.5, size * z + 1, size * z + 1);
    }

    ctx.strokeStyle = '#7c3aed';
    ctx.lineWidth = 2;
    ctx.strokeRect(ox - 1, oy - 1, w + 2, h + 2);
  }

  // ---------- tools ----------

  function sameCells(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  function pickColorAt(c) {
    const st = story();
    const fr = frame();
    if (!st || !fr || c.x < 0 || c.y < 0 || c.x >= st.width || c.y >= st.height) return;
    const v = fr.cells[c.y * st.width + c.x];
    if (v === 0) {
      toast('That spot is see-through', 1200);
      return;
    }
    setColor(v);
    if (X.settings.tool === 'picker') setTool('pencil');
  }

  /** Puts the stroke so far into the working grid. */
  function applyTool(d, c) {
    const st = story();
    const { size, mirrorX, mirrorY, filled } = X.settings;
    switch (d.tool) {
      case 'pencil':
      case 'eraser':
        d.grid.drawLine(d.last, c, d.color, size, mirrorX, mirrorY);
        break;
      case 'line':
        d.grid = new Pixel.Grid(st.width, st.height, d.base.cells);
        d.grid.drawLine(d.start, c, d.color, size, mirrorX, mirrorY);
        break;
      case 'rect':
      case 'circle': {
        d.grid = new Pixel.Grid(st.width, st.height, d.base.cells);
        let end = c;
        if (d.shift) {
          // Shift keeps it a square or a round circle.
          const n = Math.max(Math.abs(c.x - d.start.x), Math.abs(c.y - d.start.y));
          end = { x: d.start.x + Math.sign(c.x - d.start.x || 1) * n, y: d.start.y + Math.sign(c.y - d.start.y || 1) * n };
        }
        if (d.tool === 'rect') d.grid.drawRect(d.start, end, d.color, filled);
        else d.grid.drawEllipse(d.start, end, d.color, filled);
        break;
      }
      case 'move':
        d.grid = d.base.shifted(c.x - d.start.x, c.y - d.start.y, true);
        break;
      default:
        break;
    }
    d.last = c;
  }

  function onPointerDown(e) {
    if (!X.active || !story() || X.drawing || X.panning) return;
    if (X.playing) stopPlaying();
    const canvas = viewCanvas();
    if (e.button === 1 || X.spaceDown) {
      e.preventDefault();
      canvas.setPointerCapture(e.pointerId);
      X.panning = { id: e.pointerId, x: e.clientX, y: e.clientY, ox: X.view.ox, oy: X.view.oy };
      stageEl().classList.add('panning');
      return;
    }
    if (e.button !== 0 && e.button !== 2) return;
    const st = story();
    const fr = frame();
    const c = cellAt(e);
    let tool = X.settings.tool;
    if (e.altKey || tool === 'picker') {
      pickColorAt(c);
      return;
    }
    if (e.button === 2) tool = 'eraser';
    const color = tool === 'eraser' ? 0 : X.settings.color;
    if (tool === 'fill') {
      if (c.x < 0 || c.y < 0 || c.x >= st.width || c.y >= st.height) return;
      const g = new Pixel.Grid(st.width, st.height, fr.cells);
      if (g.floodFill(c.x, c.y, e.button === 2 ? 0 : color) > 0) commitCells(X.sceneId, X.frameId, g.cells);
      return;
    }
    canvas.setPointerCapture(e.pointerId);
    const base = new Pixel.Grid(st.width, st.height, fr.cells);
    X.drawing = {
      id: e.pointerId,
      tool,
      color,
      shift: e.shiftKey,
      sceneId: X.sceneId,
      frameId: X.frameId,
      start: c,
      last: c,
      base,
      grid: new Pixel.Grid(st.width, st.height, base.cells),
    };
    applyTool(X.drawing, c);
    X.hover = c;
    requestRender();
  }

  function onPointerMove(e) {
    if (X.panning && e.pointerId === X.panning.id) {
      X.view.ox = X.panning.ox + Math.round(e.clientX - X.panning.x);
      X.view.oy = X.panning.oy + Math.round(e.clientY - X.panning.y);
      requestRender();
      return;
    }
    const c = cellAt(e);
    const moved = !X.hover || X.hover.x !== c.x || X.hover.y !== c.y;
    X.hover = c;
    const d = X.drawing;
    if (d && e.pointerId === d.id) {
      d.shift = e.shiftKey;
      if (c.x !== d.last.x || c.y !== d.last.y) applyTool(d, c);
      requestRender();
      return;
    }
    if (moved) {
      refreshCursorLabel();
      requestRender();
    }
  }

  function finishDrawing(cancelled) {
    const d = X.drawing;
    X.drawing = null;
    if (!d) return;
    if (!cancelled && !sameCells(d.grid.cells, d.base.cells)) commitCells(d.sceneId, d.frameId, d.grid.cells);
    requestRender();
  }

  function onPointerUp(e) {
    if (X.panning && e.pointerId === X.panning.id) {
      X.panning = null;
      stageEl().classList.remove('panning');
      return;
    }
    if (X.drawing && e.pointerId === X.drawing.id) finishDrawing(false);
  }

  function onPointerCancel(e) {
    if (X.panning && e.pointerId === X.panning.id) {
      X.panning = null;
      stageEl().classList.remove('panning');
    }
    if (X.drawing && e.pointerId === X.drawing.id) finishDrawing(true);
  }

  function onWheel(e) {
    e.preventDefault();
    const r = viewCanvas().getBoundingClientRect();
    if (e.ctrlKey || e.metaKey || Math.abs(e.deltaY) >= Math.abs(e.deltaX)) {
      if (!e.ctrlKey && !e.metaKey && e.shiftKey) {
        X.view.ox -= Math.round(e.deltaY);
        requestRender();
        return;
      }
      zoomAt(e.deltaY < 0 ? 1 : -1, e.clientX - r.left, e.clientY - r.top);
    } else {
      X.view.ox -= Math.round(e.deltaX);
      requestRender();
    }
  }

  function refreshCursorLabel() {
    const st = story();
    const hv = X.hover;
    const inside = st && hv && hv.x >= 0 && hv.y >= 0 && hv.x < st.width && hv.y < st.height;
    $('px-cursor').textContent = inside ? `${hv.x}, ${hv.y}` : '';
  }

  // ---------- tools panel ----------

  function setTool(id) {
    X.settings.tool = id;
    saveSettings();
    renderTools();
    requestRender();
  }

  function renderTools() {
    const nav = $('px-tools');
    nav.textContent = '';
    const keyOf = (id) => Object.keys(TOOL_KEYS).find((k) => TOOL_KEYS[k] === id);
    for (const id of Pixel.TOOLS) {
      const b = el('button', {
        class: `tool${X.settings.tool === id ? ' on' : ''}`,
        title: `${Pixel.TOOL_TITLES[id]} (${keyOf(id).toUpperCase()})`,
        onclick: () => setTool(id),
      });
      b.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="square" stroke-linejoin="miter">${TOOL_ICONS[id]}</svg>`;
      b.appendChild(el('span', { text: Pixel.TOOL_TITLES[id] === 'Color picker' ? 'Picker' : Pixel.TOOL_TITLES[id] }));
      nav.appendChild(b);
    }
    nav.appendChild(el('div', { class: 'tool-sep' }));
    const sizes = el('div', { class: 'px-sizes', title: 'Pen size ([ and ])' });
    for (let n = 1; n <= 4; n++) {
      const b = el('button', { class: `px-size${X.settings.size === n ? ' on' : ''}`, title: `${n}×${n}`, onclick: () => setSize(n) });
      b.appendChild(el('i', { style: `width:${n * 4}px;height:${n * 4}px` }));
      sizes.appendChild(b);
    }
    nav.appendChild(sizes);
    const toggle = (key, label, title) => el('button', {
      class: `px-toggle${X.settings[key] ? ' on' : ''}`,
      title,
      text: label,
      onclick: () => {
        X.settings[key] = !X.settings[key];
        saveSettings();
        renderTools();
        requestRender();
      },
    });
    nav.appendChild(toggle('mirrorX', '⇆ Mirror', 'Draw on both sides (left and right)'));
    nav.appendChild(toggle('mirrorY', '⇅ Mirror', 'Draw on both halves (top and bottom)'));
    nav.appendChild(toggle('filled', '■ Filled', 'Boxes and circles come out filled'));
    nav.appendChild(el('div', { class: 'tool-sep' }));
    const act = (label, title, fn) => el('button', { class: 'px-toggle', title, text: label, onclick: fn });
    nav.appendChild(act('↔ Flip', 'Flip this frame left to right', () => transformFrame((g) => g.flippedHorizontally())));
    nav.appendChild(act('↕ Flip', 'Flip this frame upside down', () => transformFrame((g) => g.flippedVertically())));
    nav.appendChild(act('✕ Clear', 'Clear this frame', clearFrame));
  }

  function setSize(n) {
    X.settings.size = Math.max(1, Math.min(4, n));
    saveSettings();
    renderTools();
    requestRender();
  }

  function transformFrame(fn) {
    const st = story();
    const fr = frame();
    if (!st || !fr) return;
    const g = fn(new Pixel.Grid(st.width, st.height, fr.cells));
    if (!sameCells(g.cells, fr.cells)) commitCells(X.sceneId, X.frameId, g.cells);
  }

  async function clearFrame() {
    const st = story();
    const fr = frame();
    if (!st || !fr || !fr.cells.some((v) => v !== 0)) return;
    commitCells(X.sceneId, X.frameId, new Uint8Array(st.width * st.height));
    toast('Cleared (Ctrl+Z brings it back)', 1600);
  }

  // ---------- palette ----------

  function setColor(i) {
    const st = story();
    if (!st) return;
    X.settings.color = Math.max(1, Math.min(st.palette.length - 1, i));
    if (X.settings.tool === 'eraser' || X.settings.tool === 'picker' || X.settings.tool === 'move') X.settings.tool = 'pencil';
    saveSettings();
    renderTools();
    refreshPalette();
  }

  function refreshPalette() {
    const st = story();
    const box = $('px-palette');
    box.textContent = '';
    if (!st) return;
    st.palette.forEach((hex, i) => {
      if (i === 0) return;
      const b = el('button', {
        class: `px-swatch${X.settings.color === i ? ' on' : ''}`,
        style: `background:${Color.toCss(hex)}`,
        title: i <= 9 ? `Color ${i} (press ${i}) · double-click to change it` : `Color ${i} · double-click to change it`,
        onclick: () => setColor(i),
        ondblclick: () => editColor(i),
      });
      box.appendChild(b);
    });
    const add = el('button', { class: 'px-swatch add', title: 'Add a color', text: '+', onclick: addColor });
    add.disabled = st.palette.length >= Pixel.MAX_COLORS;
    box.appendChild(add);
    $('px-palette-name').textContent = st.paletteName || 'My colors';
    const cur = st.palette[X.settings.color];
    $('px-current').style.background = cur ? Color.toCss(cur) : 'transparent';
  }

  /** Opens the system color box for palette color `i`; saves once a color is picked. */
  function editColor(i) {
    const st = story();
    if (!st || i <= 0 || i >= st.palette.length) return;
    const input = $('px-color-input');
    input.value = Color.toInputValue(st.palette[i]);
    input.onchange = () => {
      const hex = Color.normalize(input.value);
      commitStory((s) => {
        if (i >= s.palette.length || s.palette[i] === hex) return false;
        s.palette[i] = hex;
        s.paletteName = '';
        return true;
      });
    };
    input.click();
  }

  function addColor() {
    const st = story();
    if (!st || st.palette.length >= Pixel.MAX_COLORS) return;
    const input = $('px-color-input');
    input.value = Color.toInputValue(st.palette[X.settings.color] || '#000000FF');
    input.onchange = () => {
      const hex = Color.normalize(input.value);
      const at = story() ? story().palette.length : 0;
      const ok = commitStory((s) => {
        if (s.palette.length >= Pixel.MAX_COLORS) return false;
        s.palette.push(hex);
        s.paletteName = '';
        return true;
      });
      if (ok) setColor(at);
    };
    input.click();
  }

  // ---------- scenes (side list) ----------

  function frameThumb(st, sc, f, maxSide) {
    // Cached per cells array (cells never change in place), palette and background.
    const key = `${st.palette.join()}|${sc.background}|${st.paper}|${maxSide}`;
    let byKey = X.thumbs.get(f.cells);
    if (!byKey) {
      byKey = new Map();
      X.thumbs.set(f.cells, byKey);
    }
    let src = byKey.get(key);
    if (!src) {
      const img = Pixel.renderFrame(f.cells, st.width, st.height, Pixel.colors(st), Pixel.background(st, sc));
      const k = Math.max(1, Math.floor(maxSide / Math.max(st.width, st.height)));
      src = toCanvas(Pixel.scaled(img, k));
      byKey.clear();
      byKey.set(key, src);
    }
    const c = document.createElement('canvas');
    c.width = src.width;
    c.height = src.height;
    c.getContext('2d').drawImage(src, 0, 0);
    return c;
  }

  function refreshScenes() {
    const st = story();
    const box = $('px-scenes');
    box.textContent = '';
    if (!st) return;
    st.scenes.forEach((sc, i) => {
      const row = el('div', { class: `px-scene${i === X.s ? ' on' : ''}`, title: 'Open this scene', onclick: () => select(i, 0) },
        frameThumb(st, sc, sc.frames[0], 40),
        el('div', { class: 'px-scene-text' },
          el('div', { class: 'px-scene-name', text: `${i + 1}. ${sc.name}` }),
          el('div', { class: 'px-scene-sub', text: `${sc.frames.length} frame${sc.frames.length === 1 ? '' : 's'} · ${Pixel.TRANSITION_TITLES[sc.transition]}` })));
      box.appendChild(row);
    });
  }

  function addScene() {
    const st = story();
    if (!st) return;
    const sc = Pixel.newScene(`Scene ${st.scenes.length + 1}`, st.width, st.height, { fps: scene() ? scene().fps : 8, transition: 'fade' });
    let at = 0;
    const ok = commitStory((s) => {
      const after = s.scenes.findIndex((x) => x.id === X.sceneId);
      at = Pixel.insertScene(s, sc, after < 0 ? null : after);
    });
    if (ok) {
      X.sceneId = sc.id;
      X.frameId = sc.frames[0].id;
      select(at, 0);
    }
  }

  function copyScene(index) {
    const st = story();
    const src = st && st.scenes[index];
    if (!src) return;
    const copy = Pixel.withFreshIds({ ...st, scenes: [src] }).scenes[0];
    copy.name = `${src.name} copy`.slice(0, 80);
    commitStory((s) => {
      Pixel.insertScene(s, copy, index);
    });
  }

  async function deleteScene(index) {
    const st = story();
    const sc = st && st.scenes[index];
    if (!sc) return;
    if (st.scenes.length === 1) {
      toast('A story needs at least one scene', 1800);
      return;
    }
    const ok = await confirmBox(`Delete "${sc.name}"?`, 'Its frames, caption and bubbles go too. Ctrl+Z brings it back.', { okText: 'Delete', danger: true });
    if (!ok) return;
    commitStory((s) => {
      const i = s.scenes.findIndex((x) => x.id === sc.id);
      if (i < 0) return false;
      s.scenes.splice(i, 1);
      return true;
    });
  }

  function moveSceneBy(index, dir) {
    const st = story();
    if (!st) return;
    const to = index + dir;
    if (to < 0 || to >= st.scenes.length) return;
    const id = st.scenes[index].id;
    commitStory((s) => {
      const i = s.scenes.findIndex((x) => x.id === id);
      if (i < 0) return false;
      Pixel.moveScene(s, i, Math.max(0, Math.min(s.scenes.length - 1, i + dir)));
      return true;
    });
  }

  // ---------- frames (timeline) ----------

  function refreshTimeline() {
    const st = story();
    const sc = scene();
    const box = $('px-frames');
    box.textContent = '';
    if (!st || !sc) return;
    const here = new Set([...X.people.values()].map((x) => x.frame));
    sc.frames.forEach((f, i) => {
      const card = el('div', { class: `frame px-frame${i === X.f ? ' on' : ''}`, title: `Frame ${i + 1}`, onclick: () => select(X.s, i) },
        frameThumb(st, sc, f, 64),
        el('span', { class: 'num', text: String(i + 1) }),
        f.hold > 1 ? el('span', { class: 'hold-badge', text: `×${f.hold}` }) : null,
        here.has(f.id) ? el('span', { class: 'here', title: 'Someone else is on this frame' }) : null);
      box.appendChild(card);
    });
    const on = box.children[X.f];
    if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    $('px-hold').textContent = String(frame() ? frame().hold : 1);
    $('px-fps').value = String(sc.fps);
    $('px-pos').textContent = `Scene ${X.s + 1} of ${st.scenes.length} · frame ${X.f + 1} of ${sc.frames.length}`;
    $('px-fr-del').disabled = sc.frames.length <= 1;
    $('px-fr-left').disabled = X.f === 0;
    $('px-fr-right').disabled = X.f >= sc.frames.length - 1;
  }

  function addFrame(copy) {
    const st = story();
    const fr = frame();
    if (!st || !fr) return;
    const nf = Pixel.blankFrame(st.width, st.height);
    if (copy) {
      nf.cells = fr.cells;
      nf.hold = fr.hold;
    }
    let at = 0;
    const ok = commitStory((s) => {
      const si = s.scenes.findIndex((x) => x.id === X.sceneId);
      if (si < 0) return false;
      const fi = s.scenes[si].frames.findIndex((x) => x.id === X.frameId);
      at = Pixel.insertFrame(s, nf, si, fi < 0 ? null : fi);
      return true;
    });
    if (ok) {
      X.frameId = nf.id;
      select(X.s, at);
    }
  }

  async function deleteFrame() {
    const sc = scene();
    const fr = frame();
    if (!sc || !fr || sc.frames.length <= 1) return;
    commitScene(X.sceneId, (s) => {
      const i = s.frames.findIndex((x) => x.id === fr.id);
      if (i < 0) return false;
      s.frames.splice(i, 1);
      return true;
    });
  }

  function moveFrameBy(dir) {
    const sc = scene();
    if (!sc) return;
    const to = X.f + dir;
    if (to < 0 || to >= sc.frames.length) return;
    const id = X.frameId;
    commitStory((s) => {
      const si = s.scenes.findIndex((x) => x.id === X.sceneId);
      if (si < 0) return false;
      const fi = s.scenes[si].frames.findIndex((x) => x.id === id);
      if (fi < 0) return false;
      Pixel.moveFrame(s, si, fi, Math.max(0, Math.min(s.scenes[si].frames.length - 1, fi + dir)));
      return true;
    });
  }

  function changeHold(delta) {
    const id = X.frameId;
    commitScene(X.sceneId, (s) => {
      const f = s.frames.find((x) => x.id === id);
      if (!f) return false;
      const hold = Math.max(1, Math.min(MAX_HOLD, f.hold + delta));
      if (hold === f.hold) return false;
      f.hold = hold;
      return true;
    });
  }

  // ---------- playing the scene in the editor ----------

  function togglePlay() {
    if (X.playing) stopPlaying();
    else startPlaying();
  }

  function startPlaying() {
    const sc = scene();
    if (!sc) return;
    // Start from the selected frame.
    let ticks = 0;
    for (let i = 0; i < X.f; i++) ticks += sc.frames[i].hold;
    X.playing = { start: performance.now() - (ticks / sc.fps) * 1000, raf: 0 };
    $('px-play').textContent = '■ Stop';
    $('px-play').classList.add('on');
    const tick = () => {
      if (!X.playing) return;
      const s = scene();
      if (!s) return stopPlaying();
      const local = (performance.now() - X.playing.start) / 1000;
      const fi = PixelStory.Timing.frameIndex(s, local);
      if (fi !== X.f) {
        X.f = fi;
        X.frameId = s.frames[fi].id;
        markTimelineFrame();
        requestRender();
      }
      X.playing.raf = requestAnimationFrame(tick);
    };
    requestRender();
    X.playing.raf = requestAnimationFrame(tick);
  }

  function stopPlaying() {
    if (!X.playing) return;
    cancelAnimationFrame(X.playing.raf);
    X.playing = null;
    $('px-play').textContent = '▶ Play scene';
    $('px-play').classList.remove('on');
    setPresence();
    if (X.active) refreshTimeline();
    requestRender();
  }

  function markTimelineFrame() {
    const box = $('px-frames');
    [...box.children].forEach((c, i) => c.classList.toggle('on', i === X.f));
    const sc = scene();
    const st = story();
    if (sc && st) $('px-pos').textContent = `Scene ${X.s + 1} of ${st.scenes.length} · frame ${X.f + 1} of ${sc.frames.length}`;
  }

  // ---------- panels ----------

  function refreshAll() {
    const p = project();
    if (!p || !p.pixel) return;
    $('px-name').textContent = p.name;
    $('px-size').textContent = `${p.pixel.width}×${p.pixel.height}`;
    refreshUndo();
    refreshPalette();
    refreshScenes();
    refreshTimeline();
    refreshPeople();
    $('px-onion').classList.toggle('on', X.settings.onion.on);
    $('px-grid').classList.toggle('on', X.settings.grid);
    requestRender();
  }

  function refreshUndo() {
    $('px-undo').disabled = !(X.session && X.session.canUndo);
    $('px-redo').disabled = !(X.session && X.session.canRedo);
  }

  function refreshConn() {
    const c = $('px-conn');
    const ok = X.client && X.client.connected;
    c.className = `conn ${ok ? 'ok' : 'bad'}`;
    c.textContent = ok ? 'Saved' : 'Reconnecting…';
    if (ok && X.client.pending.size) c.textContent = 'Saving…';
  }

  function refreshPeople() {
    const box = $('px-people');
    box.textContent = '';
    for (const person of X.people.values()) box.appendChild(el('span', { class: 'person', title: 'Also here', text: person.name }));
  }

  function onPresence(msg) {
    if (!msg.deviceId || (X.client && msg.deviceId === X.client.deviceId)) return;
    if (!X.session || msg.p !== X.session.id || msg.gone) X.people.delete(msg.deviceId);
    else X.people.set(msg.deviceId, { name: msg.deviceName || 'Device', frame: msg.frame });
    if (X.active) {
      refreshPeople();
      refreshTimeline();
    }
  }

  async function renameProject() {
    const p = project();
    if (!p) return;
    const name = await askText('Rename story', p.name, { okText: 'Rename', maxLength: 80 });
    const now = project();
    if (name && now && name !== now.name) X.session.commit({ ...now, name, modified: Model.formatDate(Date.now()) });
  }

  // ---------- grid size, palette and paper ----------

  async function storySettings() {
    const st = story();
    if (!st) return;
    const result = await modal((close) => {
      const w = el('input', { type: 'number', min: String(Pixel.MIN_SIDE), max: String(Pixel.MAX_SIDE), step: '1', value: String(st.width) });
      const h = el('input', { type: 'number', min: String(Pixel.MIN_SIDE), max: String(Pixel.MAX_SIDE), step: '1', value: String(st.height) });
      const pal = el('select', {},
        el('option', { value: '', text: st.paletteName ? `Keep ${st.paletteName}` : 'Keep my colors', selected: true }),
        Pixel.PALETTES.filter((p) => p.name !== st.paletteName).map((p) => el('option', { value: p.name, text: `${p.name} (${p.colors.length} colors)` })));
      const paper = el('input', { type: 'color', value: Color.toInputValue(st.paper), title: 'Paper color' });
      const clearPaper = el('input', { type: 'checkbox' });
      clearPaper.checked = (Color.parse(st.paper) || { a: 1 }).a === 0;
      const ok = () => close({
        width: Math.round(Number(w.value)),
        height: Math.round(Number(h.value)),
        palette: pal.value,
        paper: clearPaper.checked ? '#FFFFFF00' : Color.normalize(paper.value),
      });
      return [
        el('h2', { text: 'Grid & colors' }),
        el('div', { class: 'two' },
          el('div', { class: 'field' }, `Width (${Pixel.MIN_SIDE}–${Pixel.MAX_SIDE})`, w),
          el('div', { class: 'field' }, `Height (${Pixel.MIN_SIDE}–${Pixel.MAX_SIDE})`, h)),
        el('p', { text: 'Your art stays at the top left. Making the grid smaller cuts off the right and bottom.' }),
        el('div', { class: 'field' }, 'Palette (every color moves to the closest new one)', pal),
        el('div', { class: 'two' },
          el('div', { class: 'field' }, 'Paper', paper),
          el('label', { class: 'check' }, clearPaper, 'See-through paper')),
        el('div', { class: 'buttons' },
          el('button', { class: 'btn', text: 'Cancel', onclick: () => close(null) }),
          el('button', { class: 'btn primary', text: 'Save', onclick: ok })),
      ];
    });
    if (!result) return;
    if (!Number.isFinite(result.width) || !Number.isFinite(result.height)) {
      toast('Type a width and a height', 1800);
      return;
    }
    const target = result.palette ? Pixel.paletteNamed(result.palette) : null;
    commitStory((s) => {
      Pixel.resize(s, result.width, result.height);
      if (target) Pixel.switchPalette(s, target);
      s.paper = result.paper;
      return true;
    }, { canvas: true });
    X.view.fitted = false;
    requestAnimationFrame(fit);
  }

  // ---------- onion skin ----------

  function toggleOnion() {
    X.settings.onion = { ...X.settings.onion, on: !X.settings.onion.on };
    saveSettings();
    $('px-onion').classList.toggle('on', X.settings.onion.on);
    requestRender();
  }

  async function onionSettings() {
    const o = X.settings.onion;
    const r = await modal((close) => {
      const before = el('input', { type: 'number', min: '0', max: '3', step: '1', value: String(o.before) });
      const after = el('input', { type: 'number', min: '0', max: '3', step: '1', value: String(o.after) });
      const op = el('input', { type: 'range', min: '10', max: '90', step: '5', value: String(Math.round(o.opacity * 100)) });
      return [
        el('h2', { text: 'Onion skin' }),
        el('p', { text: 'See faded frames around this one: red before, blue after.' }),
        el('div', { class: 'two' }, el('div', { class: 'field' }, 'Frames before', before), el('div', { class: 'field' }, 'Frames after', after)),
        el('div', { class: 'field' }, 'How strong', op),
        el('div', { class: 'buttons' },
          el('button', { class: 'btn', text: 'Cancel', onclick: () => close(null) }),
          el('button', { class: 'btn primary', text: 'Save', onclick: () => close({ before: Number(before.value), after: Number(after.value), opacity: Number(op.value) / 100 }) })),
      ];
    });
    if (!r) return;
    const clamp = (v, lo, hi, fb) => (Number.isFinite(v) ? Math.min(hi, Math.max(lo, Math.round(v))) : fb);
    X.settings.onion = {
      on: true,
      before: clamp(r.before, 0, 3, 1),
      after: clamp(r.after, 0, 3, 1),
      opacity: Math.min(0.9, Math.max(0.1, r.opacity || 0.5)),
    };
    saveSettings();
    $('px-onion').classList.add('on');
    requestRender();
  }

  // ---------- storyboard ----------

  function openBoard() {
    if (!story()) return;
    stopPlaying();
    if (!X.board) {
      const root = el('div', { class: 'px-board', role: 'dialog' });
      X.board = { root, drag: null, preview: null, renderer: null };
      $('pixel').appendChild(root);
    }
    renderBoard(true);
  }

  function closeBoard() {
    if (!X.board) return;
    X.board.root.remove();
    X.board = null;
    if (X.active) refreshAll();
  }

  function renderBoard(first) {
    const B = X.board;
    const st = story();
    if (!B || !st) return;
    // Keep typing where it was when the board redraws because of a sync.
    const focused = document.activeElement && B.root.contains(document.activeElement) ? document.activeElement.dataset.field : null;
    const sc = scene();
    const root = B.root;
    root.textContent = '';
    root.appendChild(el('header', { class: 'px-board-top' },
      el('h2', { class: 'px-title', text: 'Storyboard' }),
      el('span', { class: 'px-board-sub', text: `${st.scenes.length} scene${st.scenes.length === 1 ? '' : 's'} · about ${Math.max(1, Math.round(new PixelStory.Timing(st).total))} seconds` }),
      el('span', { class: 'px-grow' }),
      el('button', { class: 'btn', text: '+ Scene', onclick: addScene }),
      el('button', { class: 'btn primary', text: '▶ Play story', onclick: openPlayer }),
      el('button', { class: 'btn', text: 'Done', onclick: closeBoard })));

    const strip = el('div', { class: `px-strip${first ? ' px-deal' : ''}` });
    st.scenes.forEach((s, i) => {
      const card = el('div', { class: `px-card${i === X.s ? ' on' : ''}`, style: `--i:${i}`, onclick: () => { select(i, 0); renderBoard(); } },
        el('div', { class: 'px-card-pic' }, frameThumb(st, s, s.frames[0], 120)),
        el('div', { class: 'px-card-num', text: String(i + 1) }),
        el('div', { class: 'px-card-name', text: s.name }),
        el('div', { class: 'px-card-meta' },
          el('span', { class: 'px-chip', text: i === 0 ? 'Start' : Pixel.TRANSITION_TITLES[s.transition] }),
          s.caption.trim() ? el('span', { class: 'px-chip', text: '💬 caption' }) : null,
          s.bubbles.length ? el('span', { class: 'px-chip', text: `${s.bubbles.length} bubble${s.bubbles.length === 1 ? '' : 's'}` }) : null),
        el('div', { class: 'px-card-actions', onclick: (e) => e.stopPropagation() },
          el('button', { class: 'btn small icon', title: 'Move earlier', text: '◀', disabled: i === 0, onclick: () => moveSceneBy(i, -1) }),
          el('button', { class: 'btn small icon', title: 'Move later', text: '▶', disabled: i === st.scenes.length - 1, onclick: () => moveSceneBy(i, 1) }),
          el('button', { class: 'btn small', text: 'Copy', onclick: () => copyScene(i) }),
          el('button', { class: 'btn small danger', text: 'Delete', disabled: st.scenes.length === 1, onclick: () => deleteScene(i) })));
      strip.appendChild(card);
      if (i < st.scenes.length - 1) strip.appendChild(el('div', { class: 'px-arrow', text: '➜' }));
    });
    root.appendChild(strip);
    if (sc) root.appendChild(sceneEditor(st, sc));
    if (focused) {
      const again = root.querySelector(`[data-field="${focused}"]`);
      if (again) again.focus();
    }
  }

  function sceneEditor(st, sc) {
    const id = sc.id;
    const B = X.board;
    const field = (label, input) => el('div', { class: 'px-field' }, el('span', { text: label }), input);
    const name = el('input', { type: 'text', value: sc.name, maxlength: '80', 'data-field': 'name' });
    name.addEventListener('change', () => {
      const v = name.value.trim() || 'Scene';
      commitScene(id, (s) => (s.name === v ? false : void (s.name = v)));
    });
    const caption = el('textarea', { rows: '3', maxlength: '300', 'data-field': 'caption', placeholder: 'What the narrator says (shows at the bottom, typed out letter by letter)' });
    caption.value = sc.caption;
    caption.addEventListener('change', () => {
      const v = caption.value;
      commitScene(id, (s) => (s.caption === v ? false : void (s.caption = v)));
    });
    const trans = el('div', { class: 'px-choices' }, Pixel.TRANSITIONS.map((t) => el('button', {
      class: `btn small${sc.transition === t ? ' on' : ''}`,
      text: Pixel.TRANSITION_TITLES[t],
      title: 'How this scene comes in',
      onclick: () => commitScene(id, (s) => (s.transition === t ? false : void (s.transition = t))),
    })));
    const numInput = (key, lo, hi) => {
      const input = el('input', { type: 'number', min: String(lo), max: String(hi), step: '1', value: String(sc[key]), 'data-field': key });
      input.addEventListener('change', () => {
        const v = Math.round(Number(input.value));
        if (!Number.isFinite(v)) return;
        const c = Math.max(lo, Math.min(hi, v));
        input.value = String(c);
        commitScene(id, (s) => (s[key] === c ? false : void (s[key] = c)));
      });
      return input;
    };
    const bgs = el('div', { class: 'px-bgs' },
      el('button', { class: `px-swatch paper${sc.background === 0 ? ' on' : ''}`, title: 'Paper', style: `background:${Color.toCss(st.paper)}`, onclick: () => commitScene(id, (s) => (s.background === 0 ? false : void (s.background = 0))) }),
      st.palette.slice(1).map((hex, k) => el('button', {
        class: `px-swatch${sc.background === k + 1 ? ' on' : ''}`,
        style: `background:${Color.toCss(hex)}`,
        title: 'Background color',
        onclick: () => commitScene(id, (s) => (s.background === k + 1 ? false : void (s.background = k + 1))),
      })));

    const bubbles = el('div', { class: 'px-bubbles' });
    sc.bubbles.forEach((b, k) => {
      const text = el('input', { type: 'text', value: b.text, maxlength: '120', placeholder: 'What they say', 'data-field': `bubble-${b.id}` });
      text.addEventListener('change', () => {
        const v = text.value;
        commitScene(id, (s) => {
          const x = s.bubbles.find((q) => q.id === b.id);
          if (!x || x.text === v) return false;
          x.text = v;
          return true;
        });
      });
      const style = el('select', { 'data-field': `bubble-style-${b.id}` }, Pixel.BUBBLE_STYLES.map((t) => el('option', { value: t, text: Pixel.BUBBLE_TITLES[t], selected: b.style === t })));
      style.addEventListener('change', () => commitScene(id, (s) => {
        const x = s.bubbles.find((q) => q.id === b.id);
        if (!x || x.style === style.value) return false;
        x.style = style.value;
        return true;
      }));
      bubbles.appendChild(el('div', { class: 'px-bubble-row' },
        el('span', { class: 'px-bubble-num', text: String(k + 1) }),
        text, style,
        el('button', {
          class: 'btn small icon danger',
          title: 'Delete bubble',
          text: '✕',
          onclick: () => commitScene(id, (s) => {
            const i = s.bubbles.findIndex((q) => q.id === b.id);
            if (i < 0) return false;
            s.bubbles.splice(i, 1);
            return true;
          }),
        })));
    });
    const addBubble = el('button', {
      class: 'btn small',
      text: '+ Speech bubble',
      disabled: sc.bubbles.length >= 6,
      onclick: () => commitScene(id, (s) => {
        const n = s.bubbles.length;
        s.bubbles.push(Pixel.newBubble('Hi!', { x: n % 2 ? 0.7 : 0.3, y: 0.18 + (n % 3) * 0.12, tailX: n % 2 ? 0.62 : 0.38, tailY: 0.5 }));
        return true;
      }),
    });

    // Preview with draggable bubbles (the round handle moves the bubble, the small one aims its tail).
    const renderer = new PixelStory.Renderer(st, 480);
    B.renderer = renderer;
    const span = renderer.timing.spans[X.s];
    const pic = toCanvas(renderer.sceneImage(X.s, span ? span.duration : 0));
    pic.className = 'px-preview-pic';
    const holder = el('div', { class: 'px-preview' }, pic);
    const L = renderer.layout;
    pic.style.aspectRatio = `${L.width} / ${L.height}`;
    const handles = el('div', { class: 'px-handles', style: `width:${(L.artWidth / L.width) * 100}%;height:${(L.artHeight / L.height) * 100}%` });
    sc.bubbles.forEach((b, k) => {
      const mk = (cls, kx, ky, title) => {
        const hnd = el('div', { class: `px-handle ${cls}`, title, style: `left:${b[kx] * 100}%;top:${b[ky] * 100}%` }, cls === 'body' ? String(k + 1) : '');
        hnd.addEventListener('pointerdown', (e) => {
          e.preventDefault();
          hnd.setPointerCapture(e.pointerId);
          B.drag = { id: e.pointerId, bubble: b.id, kx, ky, hnd, x: b[kx], y: b[ky] };
        });
        hnd.addEventListener('pointermove', (e) => {
          const d = B.drag;
          if (!d || d.id !== e.pointerId) return;
          const r = handles.getBoundingClientRect();
          d.x = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
          d.y = Math.min(1, Math.max(0, (e.clientY - r.top) / r.height));
          hnd.style.left = `${d.x * 100}%`;
          hnd.style.top = `${d.y * 100}%`;
          drawPreviewWith(pic, st, sc, d);
        });
        const end = (e) => {
          const d = B.drag;
          if (!d || d.id !== e.pointerId) return;
          B.drag = null;
          const x = Math.round(d.x * 1000) / 1000;
          const y = Math.round(d.y * 1000) / 1000;
          commitScene(id, (s) => {
            const q = s.bubbles.find((z) => z.id === d.bubble);
            if (!q || (q[d.kx] === x && q[d.ky] === y)) return false;
            q[d.kx] = x;
            q[d.ky] = y;
            return true;
          });
        };
        hnd.addEventListener('pointerup', end);
        hnd.addEventListener('pointercancel', end);
        return hnd;
      };
      handles.appendChild(mk('tail', 'tailX', 'tailY', 'Drag to point the tail'));
      handles.appendChild(mk('body', 'x', 'y', 'Drag to move the bubble'));
    });
    holder.appendChild(handles);

    return el('div', { class: 'px-scene-editor' },
      el('div', { class: 'px-preview-wrap' },
        holder,
        el('div', { class: 'px-preview-tip', text: sc.bubbles.length ? 'Drag the numbered dots to move bubbles; the small dots aim their tails.' : 'Add a speech bubble to make someone talk.' })),
      el('div', { class: 'px-form' },
        field('Scene name', name),
        field('Caption', caption),
        field('Comes in with', trans),
        el('div', { class: 'px-two' },
          field('Speed (frames a second)', numInput('fps', 1, 30)),
          field('Plays the animation', el('span', { class: 'px-inline' }, numInput('loops', 1, 20), ' times'))),
        field('Background', bgs),
        el('div', { class: 'px-field' }, el('span', { text: 'Speech bubbles' }), bubbles, addBubble),
        el('div', { class: 'px-form-actions' },
          el('button', { class: 'btn', text: '✏️ Draw this scene', onclick: closeBoard }))));
  }

  /** Redraws the preview with one bubble moved (while dragging, before saving). */
  function drawPreviewWith(pic, st, sc, d) {
    const moved = {
      ...st,
      scenes: st.scenes.map((s) => (s.id !== sc.id ? s : {
        ...s,
        bubbles: s.bubbles.map((b) => (b.id !== d.bubble ? b : { ...b, [d.kx]: d.x, [d.ky]: d.y })),
      })),
    };
    const r = new PixelStory.Renderer(moved, 480);
    const span = r.timing.spans[X.s];
    toCanvas(r.sceneImage(X.s, span ? span.duration : 0), pic);
  }

  // ---------- the player (a little TV) ----------

  function openPlayer() {
    const st = story();
    if (!st) return;
    stopPlaying();
    closePlayer();
    const renderer = new PixelStory.Renderer(Pixel.editableCopy(st), 480);
    const canvas = el('canvas', { class: 'px-tv-screen' });
    const label = el('span', { class: 'px-tv-label' });
    const scrub = el('input', { type: 'range', min: '0', max: String(Math.round(renderer.timing.total * 100)), step: '1', value: '0', title: 'Jump around' });
    const playBtn = el('button', { class: 'btn small', text: '❚❚ Pause' });
    const P = { renderer, canvas, t: 0, last: performance.now(), paused: false, raf: 0, shown: -1, root: null };
    const setPaused = (v) => {
      P.paused = v;
      playBtn.textContent = v ? '▶ Play' : '❚❚ Pause';
      P.last = performance.now();
    };
    playBtn.onclick = () => {
      if (P.t >= renderer.timing.total) P.t = 0;
      setPaused(!P.paused);
    };
    scrub.addEventListener('input', () => {
      P.t = Number(scrub.value) / 100;
      P.shown = -1;
    });
    const root = el('div', { class: 'px-player', role: 'dialog', onpointerdown: (e) => { if (e.target === root) closePlayer(); } },
      el('div', { class: 'px-tv' },
        el('div', { class: 'px-tv-glass' }, canvas, el('div', { class: 'px-scan' })),
        el('div', { class: 'px-tv-bar' },
          playBtn,
          el('button', { class: 'btn small', text: '⟲ Start over', onclick: () => { P.t = 0; P.shown = -1; setPaused(false); } }),
          scrub,
          label,
          el('button', { class: 'btn small', text: 'Close', onclick: closePlayer }))));
    P.root = root;
    X.player = P;
    $('pixel').appendChild(root);
    const frame = () => {
      if (X.player !== P) return;
      const now = performance.now();
      if (!P.paused) {
        P.t += (now - P.last) / 1000;
        if (P.t >= renderer.timing.total) {
          P.t = renderer.timing.total;
          setPaused(true);
        }
      }
      P.last = now;
      // About 30 pictures a second is plenty for pixel art.
      const step = Math.floor(P.t * 30);
      if (step !== P.shown) {
        P.shown = step;
        toCanvas(renderer.imageAt(P.t, false), canvas);
        const at = renderer.timing.locate(P.t, false);
        label.textContent = `${at.scene + 1}/${renderer.story.scenes.length} ${renderer.story.scenes[at.scene].name}`;
        scrub.value = String(Math.round(P.t * 100));
      }
      P.raf = requestAnimationFrame(frame);
    };
    P.raf = requestAnimationFrame(frame);
  }

  function closePlayer() {
    const P = X.player;
    if (!P) return;
    cancelAnimationFrame(P.raf);
    P.root.remove();
    X.player = null;
  }

  // ---------- export ----------

  const breathe = () => new Promise((r) => setTimeout(r, 0));

  function progressBox(title) {
    const bar = el('div');
    const state = { cancelled: false, close: null };
    modal((close) => {
      state.close = close;
      return [
        el('h2', { text: title }),
        el('div', { class: 'progress' }, bar),
        el('div', { class: 'buttons' }, el('button', { class: 'btn', text: 'Stop', onclick: () => { state.cancelled = true; close(null); } })),
      ];
    }, { dismiss: false });
    return {
      get cancelled() { return state.cancelled; },
      set(done, total) { bar.style.width = `${Math.round((done / Math.max(1, total)) * 100)}%`; },
      close() { if (!state.cancelled && state.close) state.close(null); },
    };
  }

  async function pngBytes(img) {
    const c = toCanvas(img);
    const blob = await new Promise((r) => c.toBlob(r, 'image/png'));
    return new Uint8Array(await blob.arrayBuffer());
  }

  const baseName = () => Gale.exporter.safeFileName(project() ? project().name : 'Pixel Story');

  async function exportGif(maxSide) {
    const st = Pixel.editableCopy(story());
    const r = new PixelStory.Renderer(st, maxSide);
    const box = progressBox('Making your GIF');
    let frames = null;
    try {
      const it = r.frameSteps(25);
      let n = 0;
      for (;;) {
        const step = it.next();
        if (step.done) {
          frames = step.value;
          break;
        }
        if (box.cancelled) return;
        if (++n % 8 === 0) {
          box.set(step.value.done, step.value.count * 1.15);
          await breathe();
        }
      }
      const gif = new PixelGif.GifWriter(r.layout.width, r.layout.height, 0);
      for (let i = 0; i < frames.length; i++) {
        if (box.cancelled) return;
        gif.add(frames[i].image, frames[i].centiseconds);
        if (i % 10 === 0) {
          box.set(1 + (i / frames.length) * 0.15, 1.15);
          await breathe();
        }
      }
      frames = gif.finish();
    } finally {
      box.close();
    }
    const where = await window.galeAPI.saveFile({ name: `${baseName()}.gif`, data: frames, kind: 'gif' });
    if (where) toast('GIF saved');
  }

  async function exportSheet(scale, transparent) {
    const st = story();
    const sc = scene();
    if (!st || !sc) return;
    const folder = await window.galeAPI.pickFolder();
    if (!folder) return;
    const { image, layout } = PixelStory.spriteSheet(st, X.s, scale, null, transparent);
    const name = `${baseName()} ${Gale.exporter.safeFileName(sc.name)}`.slice(0, 100).trim() + ' sheet';
    await window.galeAPI.writeInFolder({ id: folder.id, name: `${name}.png`, data: await pngBytes(image) });
    const json = PixelStory.spriteSheetJSON(st, X.s, layout, `${name}.png`);
    await window.galeAPI.writeInFolder({ id: folder.id, name: `${name}.json`, data: new TextEncoder().encode(json) });
    toast(`Saved ${sc.frames.length} frame${sc.frames.length === 1 ? '' : 's'} as a sprite sheet`, 2600);
  }

  async function exportFrame(scale) {
    const st = story();
    const sc = scene();
    const fr = frame();
    if (!st || !sc || !fr) return;
    const img = Pixel.scaled(Pixel.renderFrame(fr.cells, st.width, st.height, Pixel.colors(st), Pixel.background(st, sc)), scale);
    const where = await window.galeAPI.saveFile({ name: `${baseName()} frame ${X.f + 1}.png`, data: await pngBytes(img), kind: 'png' });
    if (where) toast('Picture saved');
  }

  async function showExport() {
    const st = story();
    if (!st) return;
    stopPlaying();
    const side = Math.max(st.width, st.height);
    const choice = await modal((close) => {
      let kind = 'gif';
      let gifSide = 540;
      let sheetScale = side <= 32 ? 4 : side <= 64 ? 2 : 1;
      let pngScale = Math.max(1, Math.min(16, Math.floor(512 / side)));
      let transparent = true;
      const group = (items, get, set) => {
        const btns = items.map(([v, label]) => el('button', { class: `btn${get() === v ? ' on' : ''}`, text: label }));
        btns.forEach((b, i) => b.addEventListener('click', () => {
          set(items[i][0]);
          btns.forEach((x) => x.classList.toggle('on', x === b));
        }));
        return el('div', { class: 'choices' }, btns);
      };
      const layoutAt = (ms) => PixelStory.layoutFor(st, ms);
      const gifRow = el('div', { class: 'field' }, 'Size', group([360, 540, 720].map((ms) => {
        const l = layoutAt(ms);
        return [ms, `${l.width} × ${l.height}`];
      }), () => gifSide, (v) => { gifSide = v; }));
      const tp = el('input', { type: 'checkbox' });
      tp.checked = true;
      tp.addEventListener('change', () => { transparent = tp.checked; });
      const sheetRow = el('div', {},
        el('div', { class: 'field' }, `Each frame is ${st.width} × ${st.height} pixels, made bigger by`, group([1, 2, 4, 8].map((k) => [k, `${k}×`]), () => sheetScale, (v) => { sheetScale = v; })),
        el('label', { class: 'check' }, tp, 'See-through background (best for games)'),
        el('p', { text: 'Saves a .png sheet and a .json file that says where each frame is and how long it shows.' }));
      const pngRow = el('div', { class: 'field' }, 'Size', group([1, 2, 4, 8, 16].filter((k) => st.width * k <= 4096 && st.height * k <= 4096).map((k) => [k, `${st.width * k} × ${st.height * k}`]), () => pngScale, (v) => { pngScale = v; }));
      const rows = { gif: gifRow, sheet: sheetRow, png: pngRow };
      const show = () => { for (const [k, r] of Object.entries(rows)) r.hidden = k !== kind; };
      show();
      return [
        el('h2', { class: 'px-title', text: 'Export' }),
        el('div', { class: 'field' }, 'What to make', group([
          ['gif', '🎞 Whole story as a GIF'],
          ['sheet', '🧩 Sprite sheet (this scene)'],
          ['png', '🖼 This frame as a PNG'],
        ], () => kind, (v) => { kind = v; show(); })),
        gifRow, sheetRow, pngRow,
        el('div', { class: 'buttons' },
          el('button', { class: 'btn', text: 'Cancel', onclick: () => close(null) }),
          el('button', { class: 'btn primary', text: 'Export', onclick: () => close({ kind, gifSide, sheetScale, pngScale, transparent }) })),
      ];
    });
    if (!choice) return;
    try {
      if (choice.kind === 'gif') await exportGif(choice.gifSide);
      else if (choice.kind === 'sheet') await exportSheet(choice.sheetScale, choice.transparent);
      else await exportFrame(choice.pngScale);
    } catch (err) {
      console.error(err);
      toast(`Export didn't work: ${err.message}`, 4000);
    }
  }

  // ---------- new story (from the home screen) ----------

  /** Asks for a name, grid size and palette. Resolves with a new pixel project, or null. */
  async function askNewStory() {
    const r = await modal((close) => {
      let size = GRID_SIZES[1];
      let pal = Pixel.PALETTES[0];
      const name = el('input', { type: 'text', value: 'Pixel Story', maxlength: '80' });
      const sizeBtns = GRID_SIZES.map((s) => {
        const b = el('button', { class: `px-size-pick${s === size ? ' on' : ''}`, title: `${s[1]} × ${s[2]} pixels` },
          el('i', { style: `width:${Math.round(s[1] / 3)}px;height:${Math.round(s[2] / 3)}px` }),
          el('b', { text: s[0] }),
          el('small', { text: `${s[1]}×${s[2]}` }));
        b.addEventListener('click', () => {
          size = s;
          sizeBtns.forEach((x) => x.classList.toggle('on', x === b));
        });
        return b;
      });
      const palBtns = Pixel.PALETTES.map((p) => {
        const b = el('button', { class: `px-pal-pick${p === pal ? ' on' : ''}` },
          el('span', { class: 'px-pal-name', text: p.name }),
          el('span', { class: 'px-pal-colors' }, p.colors.slice(0, 16).map((c) => el('i', { style: `background:${Color.toCss(c)}` }))));
        b.addEventListener('click', () => {
          pal = p;
          palBtns.forEach((x) => x.classList.toggle('on', x === b));
        });
        return b;
      });
      const ok = () => close({ name: name.value.trim() || 'Pixel Story', width: size[1], height: size[2], paletteName: pal.name });
      name.addEventListener('keydown', (e) => { if (e.key === 'Enter') ok(); });
      return [
        el('div', { class: 'px-new-title' }, el('span', { text: 'PIXEL STORYTIME' }), el('span', { class: 'px-blink', text: '_' })),
        el('p', { text: 'Draw little pixel scenes, add captions and speech bubbles, then play them like a story.' }),
        el('div', { class: 'field' }, 'Name', name),
        el('div', { class: 'field' }, 'Grid size', el('div', { class: 'px-size-picks' }, sizeBtns)),
        el('div', { class: 'field' }, 'Colors', el('div', { class: 'px-pal-picks' }, palBtns)),
        el('div', { class: 'buttons' },
          el('button', { class: 'btn', text: 'Cancel', onclick: () => close(null) }),
          el('button', { class: 'btn primary', text: '▶ Start', onclick: ok })),
      ];
    });
    if (!r) return null;
    return Model.newPixelProject(r);
  }

  // ---------- keyboard ----------

  function onKeyDown(e) {
    if (!X.active || document.querySelector('.modal-back')) return;
    if (X.player) {
      if (e.key === 'Escape') { e.preventDefault(); closePlayer(); }
      return;
    }
    if (X.board) {
      if (e.key === 'Escape' && !isTyping(e)) { e.preventDefault(); closeBoard(); }
      return;
    }
    if (isTyping(e)) return;
    const ctrl = e.ctrlKey || e.metaKey;
    const k = e.key.toLowerCase();
    if (ctrl && k === 'z' && !e.shiftKey) { e.preventDefault(); undo(); return; }
    if (ctrl && (k === 'y' || (k === 'z' && e.shiftKey))) { e.preventDefault(); redo(); return; }
    if (ctrl) return;
    const st = story();
    const sc = scene();
    if (!st || !sc) return;
    switch (e.key) {
      case ' ':
        if (!X.spaceDown) {
          X.spaceDown = true;
          stageEl().classList.add('pan');
        }
        e.preventDefault();
        return;
      case 'Enter': e.preventDefault(); togglePlay(); return;
      case 'ArrowLeft': case ',': e.preventDefault(); select(X.s, X.f > 0 ? X.f - 1 : sc.frames.length - 1); return;
      case 'ArrowRight': case '.': e.preventDefault(); select(X.s, X.f < sc.frames.length - 1 ? X.f + 1 : 0); return;
      case 'ArrowUp': e.preventDefault(); select(X.s - 1, 0); return;
      case 'ArrowDown': e.preventDefault(); select(X.s + 1, 0); return;
      case '[': setSize(X.settings.size - 1); return;
      case ']': setSize(X.settings.size + 1); return;
      case '0': fit(); return;
      case '=': case '+': { const r = stageEl().getBoundingClientRect(); zoomAt(1, r.width / 2, r.height / 2); return; }
      case '-': { const r = stageEl().getBoundingClientRect(); zoomAt(-1, r.width / 2, r.height / 2); return; }
      default: break;
    }
    if (/^[1-9]$/.test(e.key)) {
      const i = Number(e.key);
      if (i < st.palette.length) setColor(i);
      return;
    }
    if (TOOL_KEYS[k] && !e.altKey) { setTool(TOOL_KEYS[k]); return; }
    if (k === 'n') addFrame(false);
    else if (k === 'd') addFrame(true);
    else if (k === 'o') toggleOnion();
    else if (k === 'p') openPlayer();
    else if (k === 's') openBoard();
  }

  function onKeyUp(e) {
    if (e.key === ' ') {
      X.spaceDown = false;
      stageEl().classList.remove('pan');
    }
  }

  function undo() {
    if (X.session && X.session.undo()) toast('Undone', 900);
  }

  function redo() {
    if (X.session && X.session.redo()) toast('Redone', 900);
  }

  // ---------- wiring ----------

  function init() {
    loadSettings();
    renderTools();
    const canvas = viewCanvas();
    canvas.addEventListener('pointerdown', onPointerDown);
    canvas.addEventListener('pointermove', onPointerMove);
    canvas.addEventListener('pointerup', onPointerUp);
    canvas.addEventListener('pointercancel', onPointerCancel);
    canvas.addEventListener('lostpointercapture', (e) => {
      if (X.drawing && e.pointerId === X.drawing.id) finishDrawing(false);
      if (X.panning && e.pointerId === X.panning.id) {
        X.panning = null;
        stageEl().classList.remove('panning');
      }
    });
    canvas.addEventListener('pointerleave', () => {
      if (!X.drawing) {
        X.hover = null;
        refreshCursorLabel();
        requestRender();
      }
    });
    canvas.addEventListener('wheel', onWheel, { passive: false });
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    new ResizeObserver(() => requestRender()).observe(stageEl());
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    window.addEventListener('blur', () => {
      X.spaceDown = false;
      stageEl().classList.remove('pan');
    });

    $('px-back').onclick = () => {
      const done = X.onClose;
      close();
      if (done) done();
    };
    $('px-name').onclick = renameProject;
    $('px-undo').onclick = undo;
    $('px-redo').onclick = redo;
    $('px-play').onclick = togglePlay;
    $('px-onion').onclick = toggleOnion;
    $('px-onion-set').onclick = onionSettings;
    $('px-grid').onclick = () => {
      X.settings.grid = !X.settings.grid;
      saveSettings();
      $('px-grid').classList.toggle('on', X.settings.grid);
      requestRender();
    };
    $('px-fit').onclick = fit;
    $('px-board-btn').onclick = openBoard;
    $('px-story').onclick = openPlayer;
    $('px-settings').onclick = storySettings;
    $('px-export').onclick = showExport;
    $('px-scene-add').onclick = addScene;

    $('px-fr-add').onclick = () => addFrame(false);
    $('px-fr-dup').onclick = () => addFrame(true);
    $('px-fr-del').onclick = deleteFrame;
    $('px-fr-left').onclick = () => moveFrameBy(-1);
    $('px-fr-right').onclick = () => moveFrameBy(1);
    $('px-hold-dn').onclick = () => changeHold(-1);
    $('px-hold-up').onclick = () => changeHold(1);
    $('px-fps').addEventListener('change', (e) => {
      const v = Math.round(Number(e.target.value));
      const sc = scene();
      if (!sc || !Number.isFinite(v)) return;
      const fps = Math.max(1, Math.min(30, v));
      e.target.value = String(fps);
      commitScene(X.sceneId, (s) => (s.fps === fps ? false : void (s.fps = fps)));
    });
  }

  function attach(client) {
    client.on('presence', onPresence);
    client.on('status', () => X.active && refreshConn());
    client.on('saved', () => {
      if (!X.active) return;
      refreshConn();
      refreshUndo();
    });
  }

  Gale.pixelEditor = {
    init,
    attach,
    open,
    close,
    askNewStory,
    requestRender,
    get isOpen() { return X.active; },
    get projectId() { return X.session ? X.session.id : null; },
  };
})();
