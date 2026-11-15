'use strict';
// Export: a moving GIF picture, or one PNG picture per tick (for video apps).
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { Playback, Color } = window.GaleShared;
  const { el, modal, toast } = Gale.ui;
  const R = Gale.render;

  function safeFileName(name) {
    const s = Array.from(String(name || 'Gale')).map((ch) => (/[\p{L}\p{N} _-]/u.test(ch) ? ch : '-')).join('').trim();
    return (s || 'Gale').slice(0, 60);
  }

  /** The pictures to make: [{ frameIndex, time, delay (ms) }]. */
  function plan(p, perTick) {
    const hair = p.hair.some((h) => h.on);
    const tickMs = 1000 / p.fps;
    if (perTick || hair) {
      // Swaying hair moves every tick, so every tick is its own picture (at least 2 seconds' worth).
      const ticks = hair ? Playback.exportTicks(p, 1, 2) : Playback.totalTicks(p.frames);
      const out = [];
      for (let t = 0; t < ticks; t++) out.push({ frameIndex: Playback.frameIndexAtTick(t, p.frames), time: t / p.fps, delay: tickMs, hair });
      return out;
    }
    const starts = Playback.tickStarts(p.frames);
    return p.frames.map((f, i) => ({ frameIndex: i, time: starts[i] / p.fps, delay: Math.max(1, f.hold) * tickMs, hair: false }));
  }

  function draw(canvas, p, step, scale) {
    R.composeFrame(canvas, p, step.frameIndex, { scale, hair: step.hair, time: step.time });
    if (Color.parse(p.canvas.background).a < 1) {
      // GIFs can't be see-through here, so put white paper behind.
      const ctx = canvas.getContext('2d');
      ctx.globalCompositeOperation = 'destination-over';
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.globalCompositeOperation = 'source-over';
    }
  }

  function progressBox(title) {
    let bar;
    let label;
    let cancelled = false;
    let closeIt;
    modal((close) => {
      closeIt = close;
      bar = el('div');
      label = el('p', { text: 'Getting ready…' });
      return [
        el('h2', { text: title }),
        label,
        el('div', { class: 'progress' }, bar),
        el('div', { class: 'buttons' }, el('button', { class: 'btn', text: 'Stop', onclick: () => { cancelled = true; } })),
      ];
    }, { dismiss: false });
    return {
      set(done, total) {
        bar.style.width = `${Math.round((done / Math.max(1, total)) * 100)}%`;
        label.textContent = `Picture ${Math.min(done + 1, total)} of ${total}`;
      },
      get cancelled() {
        return cancelled;
      },
      close() {
        closeIt(null);
      },
    };
  }

  const breathe = () => new Promise((r) => setTimeout(r, 0));

  async function exportGif(p, scale) {
    const { GIFEncoder, quantize, applyPalette } = window.GifEnc;
    const steps = plan(p, false);
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(p.canvas.width * scale));
    canvas.height = Math.max(1, Math.round(p.canvas.height * scale));
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    const gif = GIFEncoder();
    const box = progressBox('Making your GIF');
    try {
      for (let i = 0; i < steps.length; i++) {
        if (box.cancelled) return;
        box.set(i, steps.length);
        draw(canvas, p, steps[i], scale);
        const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
        const palette = quantize(data, 256);
        const index = applyPalette(data, palette);
        gif.writeFrame(index, canvas.width, canvas.height, { palette, delay: Math.round(steps[i].delay), repeat: 0 });
        await breathe();
      }
      gif.finish();
    } finally {
      box.close();
    }
    const where = await window.galeAPI.saveFile({ name: `${safeFileName(p.name)}.gif`, data: gif.bytes(), kind: 'gif' });
    if (where) toast('GIF saved');
  }

  async function exportPngs(p, scale) {
    const folder = await window.galeAPI.pickFolder();
    if (!folder) return;
    const steps = plan(p, true);
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(p.canvas.width * scale));
    canvas.height = Math.max(1, Math.round(p.canvas.height * scale));
    const base = safeFileName(p.name);
    const box = progressBox('Saving pictures');
    try {
      for (let i = 0; i < steps.length; i++) {
        if (box.cancelled) return;
        box.set(i, steps.length);
        R.composeFrame(canvas, p, steps[i].frameIndex, { scale, hair: steps[i].hair, time: steps[i].time });
        const blob = await new Promise((r) => canvas.toBlob(r, 'image/png'));
        const data = new Uint8Array(await blob.arrayBuffer());
        await window.galeAPI.writeInFolder({ id: folder.id, name: `${base} ${String(i + 1).padStart(4, '0')}.png`, data });
      }
    } finally {
      box.close();
    }
    toast(`Saved ${steps.length} pictures`);
  }

  async function show(p) {
    const choice = await modal((close) => {
      let kind = 'gif';
      let scale = Math.max(p.canvas.width, p.canvas.height) > 1280 ? 0.5 : 1;
      const kindBtns = [
        ['gif', 'GIF (a moving picture)'],
        ['png', 'PNG pictures (one per tick, for video apps)'],
      ].map(([k, label]) => el('button', { class: `btn${k === kind ? ' on' : ''}`, text: label, 'data-k': k }));
      kindBtns.forEach((b) => b.addEventListener('click', () => {
        kind = b.dataset.k;
        kindBtns.forEach((x) => x.classList.toggle('on', x === b));
      }));
      const sizeBtns = [1, 0.5, 0.25].map((s) => el('button', {
        class: `btn${s === scale ? ' on' : ''}`,
        text: `${Math.round(p.canvas.width * s)} × ${Math.round(p.canvas.height * s)}`,
        'data-s': String(s),
      }));
      sizeBtns.forEach((b) => b.addEventListener('click', () => {
        scale = Number(b.dataset.s);
        sizeBtns.forEach((x) => x.classList.toggle('on', x === b));
      }));
      return [
        el('h2', { text: 'Export' }),
        el('div', { class: 'field' }, 'What to make', el('div', { class: 'choices' }, kindBtns)),
        el('div', { class: 'field' }, 'Size', el('div', { class: 'choices' }, sizeBtns)),
        el('div', { class: 'buttons' },
          el('button', { class: 'btn', text: 'Cancel', onclick: () => close(null) }),
          el('button', { class: 'btn primary', text: 'Export', onclick: () => close({ kind, scale }) })),
      ];
    });
    if (!choice) return;
    try {
      if (choice.kind === 'gif') await exportGif(p, choice.scale);
      else await exportPngs(p, choice.scale);
    } catch (err) {
      console.error(err);
      toast(`Export didn't work: ${err.message}`, 4000);
    }
  }

  Gale.exporter = { show, plan, safeFileName };
})();
