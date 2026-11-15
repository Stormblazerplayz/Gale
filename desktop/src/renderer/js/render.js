'use strict';
// Draws strokes, cels and frames on canvases, the same way the iPad does
// (StrokeRenderer.swift and FrameRenderer.swift): fills first, then strokes in key order,
// each layer on its own see-through sheet so the eraser only clears its own layer.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { Model, Color, StrokeShape, Hair } = window.GaleShared;

  function rgba(c, a) {
    return `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${Math.max(0, Math.min(1, a))})`;
  }

  function parseColor(hexOrRgba) {
    if (hexOrRgba && typeof hexOrRgba === 'object') return hexOrRgba;
    return Color.parse(hexOrRgba) || { r: 0, g: 0, b: 0, a: 1 };
  }

  /**
   * Draws one stroke. opts: { tint ({r,g,b}), alpha, regions (hair), time, points (already unpacked) }.
   */
  function drawStroke(ctx, stroke, opts = {}) {
    let pts = opts.points || Model.unpackPoints(stroke.pts);
    if (!pts.length) return;
    if (opts.regions && opts.regions.length) {
      for (const r of opts.regions) pts = Hair.deform(pts, r, opts.time || 0);
    }
    const brush = stroke.brush;
    const eraser = brush.kind === 'eraser';
    const base = parseColor(brush.color);
    const color = opts.tint || base;
    const a = eraser ? 1 : StrokeShape.alpha(pts, brush) * (opts.alpha == null ? 1 : opts.alpha);
    ctx.save();
    if (eraser) ctx.globalCompositeOperation = 'destination-out';
    if (brush.kind === 'airbrush' && !eraser) {
      for (const dab of StrokeShape.airbrushDabs(pts, brush)) {
        const g = ctx.createRadialGradient(dab.center.x, dab.center.y, 0, dab.center.x, dab.center.y, dab.radius);
        g.addColorStop(0, rgba(color, 1));
        g.addColorStop(1, rgba(color, 0));
        ctx.globalAlpha = Math.max(0, Math.min(1, a * (0.3 + 0.7 * dab.pressure)));
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(dab.center.x, dab.center.y, dab.radius, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
      return;
    }
    const outline = StrokeShape.outline(pts, brush);
    if (outline.length < 3) {
      ctx.restore();
      return;
    }
    ctx.beginPath();
    ctx.moveTo(outline[0].x, outline[0].y);
    for (let i = 1; i < outline.length; i++) ctx.lineTo(outline[i].x, outline[i].y);
    ctx.closePath();
    ctx.fillStyle = eraser ? '#000' : rgba(color, a);
    // Nonzero so a stroke that crosses itself stays solid.
    ctx.fill('nonzero');
    ctx.restore();
  }

  function drawFill(ctx, fill, opts = {}) {
    const p = fill.path;
    if (!p || p.length < 6) return;
    const c = parseColor(fill.color);
    const tint = opts.tint || c;
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(p[0], p[1]);
    for (let i = 2; i + 1 < p.length; i += 2) ctx.lineTo(p[i], p[i + 1]);
    ctx.closePath();
    ctx.fillStyle = rgba(tint, c.a * (opts.alpha == null ? 1 : opts.alpha));
    ctx.fill('evenodd');
    ctx.restore();
  }

  function drawCel(ctx, cel, opts = {}) {
    if (!cel) return;
    for (const f of cel.fills) drawFill(ctx, f, opts);
    for (const s of cel.strokes) drawStroke(ctx, s, opts);
  }

  const scratchCanvases = new Map();
  function scratch(w, h, slot = 'a') {
    let c = scratchCanvases.get(slot);
    if (!c) {
      c = document.createElement('canvas');
      scratchCanvases.set(slot, c);
    }
    if (c.width !== w || c.height !== h) {
      c.width = w;
      c.height = h;
    }
    return c;
  }

  function celEmpty(cel) {
    return !cel || (cel.strokes.length === 0 && cel.fills.length === 0);
  }

  /**
   * Draws a whole frame into `target` (a canvas sized canvas width x height times `scale`).
   * opts: { scale, background, hair, time, tint, clear }
   */
  function composeFrame(target, project, frameIndex, opts = {}) {
    const scale = opts.scale || 1;
    const W = target.width;
    const H = target.height;
    const ctx = target.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';
    ctx.filter = 'none';
    if (opts.clear !== false) ctx.clearRect(0, 0, W, H);
    if (opts.background !== false) {
      ctx.fillStyle = Color.toCss(project.canvas.background);
      ctx.fillRect(0, 0, W, H);
    }
    const frame = project.frames[frameIndex];
    if (!frame) return;
    const sheet = scratch(W, H, 'compose');
    const lctx = sheet.getContext('2d');
    for (const layer of project.layers) {
      if (!layer.visible) continue;
      const cel = frame.cels[layer.id];
      if (celEmpty(cel)) continue;
      lctx.setTransform(1, 0, 0, 1, 0, 0);
      lctx.clearRect(0, 0, W, H);
      lctx.setTransform(scale, 0, 0, scale, 0, 0);
      const regions = opts.hair ? Hair.regionsFor(project, layer.id) : null;
      drawCel(lctx, cel, { tint: opts.tint, regions, time: opts.time || 0 });
      ctx.globalAlpha = Math.max(0, Math.min(1, layer.opacity));
      ctx.drawImage(sheet, 0, 0);
      ctx.globalAlpha = 1;
    }
  }

  /** Full-size pictures of single cels, kept until that cel changes. */
  class CelCache {
    constructor(limit = 28) {
      this.limit = limit;
      this.map = new Map();
    }

    clear() {
      this.map.clear();
    }

    /** Canvas pixels per project pixel (big canvases are drawn a bit smaller to save memory). */
    static quality(project) {
      return Math.min(1, 4096 / Math.max(project.canvas.width, project.canvas.height));
    }

    get(session, project, frame, layerId) {
      const key = `${frame.id}|${layerId}`;
      const q = CelCache.quality(project);
      const w = Math.max(1, Math.round(project.canvas.width * q));
      const h = Math.max(1, Math.round(project.canvas.height * q));
      const version = `${session.celVersion(frame.id, layerId)}|${w}x${h}`;
      let entry = this.map.get(key);
      if (entry && entry.version === version) {
        this.map.delete(key);
        this.map.set(key, entry);
        return entry.canvas;
      }
      const canvas = entry ? entry.canvas : document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext('2d');
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, w, h);
      ctx.setTransform(q, 0, 0, q, 0, 0);
      drawCel(ctx, frame.cels[layerId]);
      entry = { canvas, version };
      this.map.delete(key);
      this.map.set(key, entry);
      while (this.map.size > this.limit) this.map.delete(this.map.keys().next().value);
      return canvas;
    }
  }

  /** A signature of everything that changes how a frame looks (for caches). */
  function frameSignature(session, project, frame) {
    let s = `${frame.id}:${project.canvas.width}x${project.canvas.height}:${project.canvas.background}`;
    for (const l of project.layers) {
      s += `|${l.id}:${l.visible ? 1 : 0}:${l.opacity}:${session.celVersion(frame.id, l.id)}`;
    }
    return s;
  }

  Gale.render = { drawStroke, drawFill, drawCel, composeFrame, CelCache, frameSignature, scratch, rgba, parseColor, celEmpty };
})();
