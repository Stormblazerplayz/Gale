'use strict';
// The stabilizer bits of the brush panel: a before and after of your last line, and the stabilizer test
// (trace four shapes, Gale measures how much your hand shakes and picks the smoothing for you).
// Same guides and numbers as the iPad app.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { Stabilizer, Calibration } = window.GaleShared;
  const { el, modal } = Gale.ui;

  const ACCENT = '#7c3aed';
  const SKY = '#22d3ee';
  const MUTED = '#9b9bb2';

  /** Makes a canvas sharp on high-resolution screens. Returns its 2D context in CSS pixels. */
  function sharpContext(canvas) {
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth || Number(canvas.getAttribute('width')) || 200;
    const h = canvas.clientHeight || Number(canvas.getAttribute('height')) || 100;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    return { ctx, w, h };
  }

  /** How to fit a line's bounds into a box, keeping its shape. */
  function fitOf(pts, x, y, w, h, pad) {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const p of pts) {
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    const bw = Math.max(1, maxX - minX), bh = Math.max(1, maxY - minY);
    const s = Math.min((w - pad * 2) / bw, (h - pad * 2) / bh);
    const ox = x + (w - bw * s) / 2 - minX * s;
    const oy = y + (h - bh * s) / 2 - minY * s;
    return (p) => [p.x * s + ox, p.y * s + oy];
  }

  function strokeLine(ctx, pts, map, color, width) {
    if (pts.length < 2) return;
    ctx.beginPath();
    pts.forEach((p, i) => {
      const [x, y] = map(p);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.stroke();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  /**
   * Draws your line as you drew it (left) next to how Gale smooths it (right).
   * `raw` is in screen pixels. With no line yet it says how to get one.
   */
  function drawBeforeAfter(canvas, raw, amount, adaptive, emptyText) {
    const { ctx, w, h } = sharpContext(canvas);
    const gap = 8;
    const pw = (w - gap) / 2;
    for (const x of [0, pw + gap]) {
      roundRect(ctx, x, 0, pw, h, 10);
      ctx.fillStyle = '#ffffff0d';
      ctx.fill();
    }
    ctx.font = '600 10px system-ui, sans-serif';
    ctx.fillStyle = MUTED;
    if (!raw || raw.length < 2) {
      ctx.textAlign = 'center';
      ctx.font = '11px system-ui, sans-serif';
      const words = (emptyText || 'Draw a line to see it here, before and after smoothing.').split(' ');
      // Wrap the hint across the whole width.
      const lines = [];
      let line = '';
      for (const word of words) {
        const next = line ? `${line} ${word}` : word;
        if (ctx.measureText(next).width > w - 24 && line) {
          lines.push(line);
          line = word;
        } else line = next;
      }
      if (line) lines.push(line);
      lines.forEach((l, i) => ctx.fillText(l, w / 2, h / 2 + (i - (lines.length - 1) / 2) * 14 + 4));
      ctx.textAlign = 'left';
      return;
    }
    ctx.fillText('BEFORE', 8, 14);
    ctx.fillText('AFTER', pw + gap + 8, 14);
    const smooth = Stabilizer.finish(raw, amount, 1, adaptive);
    strokeLine(ctx, raw, fitOf(raw, 0, 8, pw, h - 8, 12), MUTED, 2);
    strokeLine(ctx, smooth, fitOf(raw, pw + gap, 8, pw, h - 8, 12), ACCENT, 2.5);
  }

  /** Points along a guide, in pixels for a pad `height` tall. */
  const guideAt = (g, height) => g.points.map((p) => ({ x: p.x * height, y: p.y * height }));

  /**
   * Opens the stabilizer test. `adaptive` is the "Keep corners sharp" setting.
   * Resolves with { result, amount } when you pick a smoothing, or null if you close it.
   */
  function openTest({ adaptive }) {
    return modal((close) => {
      const guides = Calibration.GUIDES;
      let step = 0;
      let lines = [];
      let ink = [];
      let drawing = null;
      let alive = true;
      const done = (v) => {
        alive = false;
        close(v);
      };

      const root = el('div', { class: 'calib' });
      const stepDots = el('div', { class: 'calib-dots' });
      const title = el('h3', { class: 'calib-title' });
      const tip = el('p', { class: 'calib-tip' });
      const pad = el('canvas', { class: 'calib-pad', width: '640', height: '400', 'aria-label': 'Tracing area' });
      const note = el('p', { class: 'calib-note' });
      const early = el('button', { class: 'btn small ghost', text: 'Skip the rest and see my result', hidden: true, onclick: () => showResult() });
      const tracing = el('div', { class: 'calib-tracing' }, stepDots, title, tip, pad, note, early);
      root.append(
        el('div', { class: 'calib-head' },
          el('h2', { text: 'Stabilizer test' }),
          el('button', { class: 'btn small ghost', text: 'Close', onclick: () => done(null) })),
        tracing,
      );

      function showStep() {
        stepDots.textContent = '';
        guides.forEach((_, i) => stepDots.appendChild(el('span', { class: i < step ? 'done' : i === step ? 'now' : '' })));
        title.textContent = `${step + 1} of ${guides.length}: ${guides[step].title}`;
        tip.textContent = guides[step].tip;
        note.textContent = 'Trace on top of the dotted shape, at your normal speed. Mouse, pen or touch all work.';
        note.classList.remove('warn');
        early.hidden = lines.length < Calibration.MIN_LINES;
        ink = [];
      }

      // Pointer: catch the raw touches of one line, in pad pixels.
      const local = (e) => {
        const r = pad.getBoundingClientRect();
        const pressure = e.pointerType === 'mouse' ? 0.5 : e.pressure > 0 ? e.pressure : 0.5;
        return { x: e.clientX - r.left, y: e.clientY - r.top, pressure, time: e.timeStamp / 1000 };
      };
      pad.addEventListener('pointerdown', (e) => {
        if (drawing !== null) return;
        e.preventDefault();
        pad.setPointerCapture(e.pointerId);
        drawing = e.pointerId;
        ink = [local(e)];
      });
      pad.addEventListener('pointermove', (e) => {
        if (e.pointerId !== drawing) return;
        const evs = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
        for (const ev of evs.length ? evs : [e]) ink.push(local(ev));
      });
      const up = (e, cancelled) => {
        if (e.pointerId !== drawing) return;
        drawing = null;
        if (cancelled) {
          ink = [];
          return;
        }
        finished(ink.slice());
      };
      pad.addEventListener('pointerup', (e) => up(e, false));
      pad.addEventListener('pointercancel', (e) => up(e, true));

      function finished(pts) {
        if (!Calibration.lineShake(pts)) {
          note.textContent = 'That line was too short to measure. Trace the whole shape in one go.';
          note.classList.add('warn');
          ink = [];
          return;
        }
        lines.push(pts);
        if (step + 1 < guides.length) {
          step += 1;
          showStep();
        } else showResult();
      }

      // The pad: dotted guide, a glowing dot that shows the way, and your ink.
      function frame(now) {
        if (!alive || !pad.isConnected) return;
        if (tracing.hidden) {
          requestAnimationFrame(frame);
          return;
        }
        const { ctx, w, h } = sharpContext(pad);
        roundRect(ctx, 0.5, 0.5, w - 1, h - 1, 16);
        ctx.fillStyle = '#ffffff08';
        ctx.fill();
        ctx.strokeStyle = '#7c3aed40';
        ctx.lineWidth = 1;
        ctx.stroke();
        const height = Math.min(h, w / Calibration.ASPECT);
        const ox = (w - height * Calibration.ASPECT) / 2, oy = (h - height) / 2;
        const g = guideAt(guides[step], height).map((p) => ({ x: p.x + ox, y: p.y + oy }));
        const id = (p) => [p.x, p.y];
        ctx.setLineDash([0.1, 16]);
        strokeLine(ctx, g, id, '#9b9bb266', 10);
        ctx.setLineDash([]);
        // Start marker.
        ctx.beginPath();
        ctx.arc(g[0].x, g[0].y, 9, 0, Math.PI * 2);
        ctx.strokeStyle = ACCENT;
        ctx.lineWidth = 2;
        ctx.stroke();
        // The pacer runs along the guide every couple of seconds, with a short trail.
        const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        const t = reduce ? 0 : Math.min(1, ((now / 1000) % 2.6) / 2.2);
        const at = Math.round(t * (g.length - 1));
        const from = Math.max(0, Math.round((t - 0.18) * (g.length - 1)));
        const grad = ctx.createLinearGradient(g[from].x, g[from].y, g[at].x, g[at].y);
        grad.addColorStop(0, SKY + '00');
        grad.addColorStop(1, ACCENT + 'aa');
        strokeLine(ctx, g.slice(from, at + 1), id, grad, 8);
        ctx.beginPath();
        ctx.arc(g[at].x, g[at].y, 15, 0, Math.PI * 2);
        ctx.fillStyle = ACCENT + '40';
        ctx.fill();
        ctx.beginPath();
        ctx.arc(g[at].x, g[at].y, 6, 0, Math.PI * 2);
        ctx.fillStyle = ACCENT;
        ctx.fill();
        strokeLine(ctx, ink, id, ACCENT, 4);
        requestAnimationFrame(frame);
      }

      function showResult() {
        const r = Calibration.measure(lines);
        if (!r) {
          note.textContent = `Gale needs at least ${Calibration.MIN_LINES} full shapes to measure. Keep going.`;
          note.classList.add('warn');
          return;
        }
        tracing.hidden = true;
        let amount = r.amount;
        const showcase = lines.length > 2 ? lines[2] : lines.reduce((a, b) => (b.length > a.length ? b : a), []);
        const ring = el('div', { class: 'calib-ring' });
        ring.innerHTML = '<svg viewBox="0 0 120 120"><defs><linearGradient id="calib-grad" x1="0" y1="0" x2="1" y2="1">'
          + `<stop offset="0" stop-color="${SKY}"/><stop offset="1" stop-color="${ACCENT}"/></linearGradient></defs>`
          + '<circle cx="60" cy="60" r="50" class="track"/><circle cx="60" cy="60" r="50" class="fill"/></svg>';
        ring.appendChild(el('div', { class: 'calib-score' }, el('b', { text: String(r.steadiness) }), el('span', { text: 'steady' })));
        const fill = ring.querySelector('.fill');
        const C = 2 * Math.PI * 50;
        fill.style.strokeDasharray = `${C}`;
        fill.style.strokeDashoffset = `${C}`;
        requestAnimationFrame(() => requestAnimationFrame(() => { fill.style.strokeDashoffset = `${C * (1 - r.steadiness / 100)}`; }));

        const preview = el('canvas', { class: 'calib-ba', width: '600', height: '150' });
        const out = el('output', { text: Stabilizer.label(amount) });
        const slider = el('input', { type: 'range', min: '0', max: '100', step: '1', value: String(Math.round(amount * 100)) });
        const useBtn = el('button', { class: 'btn primary', text: `Use ${Stabilizer.label(amount)}`, onclick: () => done({ result: { ...r, amount }, amount }) });
        const back = el('button', { class: 'btn small ghost', text: `Back to the recommended ${Stabilizer.label(r.amount)}`, hidden: true, onclick: () => setAmount(r.amount) });
        const setAmount = (a) => {
          amount = a;
          slider.value = String(Math.round(a * 100));
          out.textContent = Stabilizer.label(a);
          useBtn.textContent = `Use ${Stabilizer.label(a)}`;
          back.hidden = Math.abs(a - r.amount) < 0.005;
          drawBeforeAfter(preview, showcase, a, adaptive);
        };
        slider.addEventListener('input', () => setAmount(Number(slider.value) / 100));

        const resultView = el('div', { class: 'calib-result' },
          el('div', { class: 'calib-summary' }, ring,
            el('div', {},
              el('h3', { text: r.level }),
              el('p', { text: `Gale recommends ${Stabilizer.label(r.amount)} smoothing for your hand.` }),
              adaptive ? el('p', { class: 'calib-corners', text: '▲ Corners stay sharp' }) : null)),
          el('div', { class: 'calib-card' },
            el('h4', { text: 'Your line, before and after' }),
            preview,
            el('label', { class: 'slider' }, el('span', { text: 'Try it' }), slider, out),
            back),
          el('div', { class: 'buttons' },
            el('button', { class: 'btn', text: 'Try again', onclick: restart }),
            useBtn));
        root.appendChild(resultView);
        requestAnimationFrame(() => drawBeforeAfter(preview, showcase, amount, adaptive));

        function restart() {
          resultView.remove();
          lines = [];
          step = 0;
          tracing.hidden = false;
          showStep();
        }
      }

      showStep();
      requestAnimationFrame(frame);
      return root;
    });
  }

  Gale.stabilizer = { drawBeforeAfter, openTest };
})();
