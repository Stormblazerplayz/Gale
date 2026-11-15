'use strict';
// The home screen: your drawings (stored in the hub), and making, renaming, copying and deleting them.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { Model, Objects, Replica: Rp, Hlc } = window.GaleShared;
  const { el, $, toast, modal, askText, confirmBox, timeAgo } = Gale.ui;
  const R = Gale.render;

  const H = { client: null, clock: null, onOpen: null, covers: new Map(), queue: [], busy: false };

  /** Makes sure our next edit to a project wins over its newest saved change (even from a clock that runs ahead). */
  function catchUp(summary) {
    const ms = Model.parseDate(summary && summary.modified);
    if (ms != null) H.clock.observe(Hlc.format(ms + 999, 99998, 'x'));
  }

  function pushProject(p) {
    const ops = Rp.makeOps(Objects.diff({}, Objects.toObjects(p)), H.clock);
    H.client.push(p.id, ops);
  }

  function pushField(summary, k, v) {
    catchUp(summary);
    H.client.push(summary.id, [{ t: H.clock.tick(), a: H.clock.actor, o: summary.id, k, v }]);
  }

  async function newDrawing() {
    const sizes = [
      ['Wide', 1920, 1080],
      ['Tall', 1080, 1920],
      ['Square', 1080, 1080],
      ['Small', 1280, 720],
    ];
    const result = await modal((close) => {
      let pick = sizes[0];
      const name = el('input', { type: 'text', value: 'Untitled', maxlength: '80' });
      const fps = el('select', {}, [6, 8, 12, 15, 24, 30].map((n) => el('option', { value: String(n), text: `${n} frames a second`, selected: n === 12 })));
      const bg = el('input', { type: 'color', value: '#ffffff', title: 'Paper color' });
      const btns = sizes.map((s) => el('button', { class: `btn${s === pick ? ' on' : ''}`, text: `${s[0]} ${s[1]}×${s[2]}` }));
      btns.forEach((b, i) => b.addEventListener('click', () => {
        pick = sizes[i];
        btns.forEach((x) => x.classList.toggle('on', x === b));
      }));
      const ok = () => close({ name: name.value.trim() || 'Untitled', width: pick[1], height: pick[2], fps: Number(fps.value), background: bg.value });
      name.addEventListener('keydown', (e) => { if (e.key === 'Enter') ok(); });
      return [
        el('h2', { text: 'New drawing' }),
        el('div', { class: 'field' }, 'Name', name),
        el('div', { class: 'field' }, 'Size', el('div', { class: 'choices' }, btns)),
        el('div', { class: 'two' }, el('div', { class: 'field' }, 'Speed', fps), el('div', { class: 'field' }, 'Paper', bg)),
        el('div', { class: 'buttons' },
          el('button', { class: 'btn', text: 'Cancel', onclick: () => close(null) }),
          el('button', { class: 'btn primary', text: 'Make it', onclick: ok })),
      ];
    });
    if (!result) return;
    const p = Model.newProject(result);
    pushProject(p);
    H.onOpen(p.id);
  }

  async function importProject() {
    const res = await window.galeAPI.importGale();
    if (!res) return;
    if (res.error) {
      toast(res.error, 4000);
      return;
    }
    let p = Model.readProject(res.project);
    if (H.client.projects.some((x) => x.id === p.id)) p = Model.withFreshIds(p, p.name);
    pushProject(p);
    toast(`Opened "${p.name}"`);
    H.onOpen(p.id);
  }

  async function rename(summary) {
    const name = await askText('Rename drawing', summary.name, { okText: 'Rename', maxLength: 80 });
    if (name && name !== summary.name) pushField(summary, 'name', name);
  }

  async function remove(summary) {
    const ok = await confirmBox(`Delete "${summary.name}"?`, 'It goes away on every paired device too. Its folder moves to Documents/Gale/Deleted.', { okText: 'Delete', danger: true });
    if (ok) pushField(summary, '$del', true);
  }

  async function duplicate(summary) {
    try {
      const json = await H.client.fetchProject(summary.id);
      const p = Model.withFreshIds(Model.readProject(json), `${summary.name} copy`);
      pushProject(p);
      toast(`Made "${p.name}"`);
    } catch (err) {
      toast(err.message, 4000);
    }
  }

  // ---------- covers (small picture of the first frame) ----------

  function queueCover(summary, holder) {
    const key = `${summary.id}:${summary.seq}`;
    const have = H.covers.get(summary.id);
    if (have && have.key === key) {
      holder.appendChild(have.canvas);
      return;
    }
    H.queue.push({ summary, holder, key });
    pumpCovers();
  }

  async function pumpCovers() {
    if (H.busy) return;
    H.busy = true;
    while (H.queue.length) {
      const { summary, holder, key } = H.queue.shift();
      if (!holder.isConnected) continue;
      try {
        const p = Model.readProject(await H.client.fetchProject(summary.id));
        const scale = Math.min(460 / p.canvas.width, 288 / p.canvas.height);
        const c = document.createElement('canvas');
        c.width = Math.max(1, Math.round(p.canvas.width * scale));
        c.height = Math.max(1, Math.round(p.canvas.height * scale));
        R.composeFrame(c, p, 0, { scale });
        H.covers.set(summary.id, { key, canvas: c });
        if (holder.isConnected) {
          holder.textContent = '';
          holder.appendChild(c);
        }
      } catch (_) {
        /* the drawing may have just been deleted */
      }
    }
    H.busy = false;
  }

  function render() {
    const grid = $('project-grid');
    const list = H.client ? H.client.projects : [];
    grid.textContent = '';
    H.queue = [];
    $('home-empty').hidden = list.length > 0;
    grid.hidden = list.length === 0;
    for (const s of list) {
      const thumb = el('div', { class: 'thumb' });
      const card = el('div', { class: 'card', title: 'Open', onclick: () => H.onOpen(s.id) },
        thumb,
        el('div', { class: 'info' }, el('div', { class: 'name', text: s.name }), el('div', { class: 'when', text: `Changed ${timeAgo(s.modified)}` })),
        el('div', { class: 'actions', onclick: (e) => e.stopPropagation() },
          el('button', { class: 'btn small', text: 'Rename', onclick: () => rename(s) }),
          el('button', { class: 'btn small', text: 'Copy', onclick: () => duplicate(s) }),
          el('button', { class: 'btn small', text: 'Files', title: 'Show its folder', onclick: () => window.galeAPI.showProject(s.id) }),
          el('button', { class: 'btn small danger', text: 'Delete', onclick: () => remove(s) })));
      grid.appendChild(card);
      queueCover(s, thumb);
    }
  }

  function setStatus(connected) {
    $('home-status').textContent = connected ? '' : 'Starting up…';
  }

  function init(client, onOpen, onPair) {
    H.client = client;
    H.clock = new Hlc.HLC(client.deviceId);
    H.onOpen = onOpen;
    client.on('projects', render);
    client.on('status', setStatus);
    setStatus(false);
    $('home-new').onclick = newDrawing;
    $('home-import').onclick = importProject;
    $('home-files').onclick = () => window.galeAPI.openDocs();
    $('home-pair').onclick = onPair;
    render();
  }

  Gale.home = { init, render };
})();
