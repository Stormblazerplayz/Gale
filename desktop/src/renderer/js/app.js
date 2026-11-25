'use strict';
// Starts everything and switches between the screens.
(function () {
  const Gale = window.Gale;
  const { $, el, banner } = Gale.ui;

  function showScreen(id) {
    for (const s of ['home', 'editor', 'pixel', 'pair']) $(s).hidden = s !== id;
  }

  async function start() {
    const info = await window.galeAPI.hubInfo();
    if (info.error) {
      const off = banner('warn', el('span', { text: info.error }), el('button', { class: 'btn small', text: 'OK', onclick: () => off() }));
    }
    const client = new Gale.HubClient(info);
    Gale.client = client;

    const goHome = () => {
      showScreen('home');
      Gale.home.render();
    };
    // Pixel stories open in the pixel editor, everything else in the drawing editor.
    // `kind` ('pixel' or 'drawing') is given when the caller already knows; otherwise the list says.
    const openProject = (id, done = goHome, kind) => {
      const summary = client.projects.find((x) => x.id === id);
      const pixel = kind ? kind === 'pixel' : !!(summary && summary.pixel);
      if (Gale.editor.isOpen) Gale.editor.close();
      if (Gale.pixelEditor.isOpen) Gale.pixelEditor.close();
      if (pixel) {
        Gale.pixelEditor.open(client, id, done);
        showScreen('pixel');
        Gale.pixelEditor.requestRender();
      } else {
        Gale.editor.open(client, id, done);
        showScreen('editor');
        Gale.editor.requestRender();
      }
    };
    // An editor that finds it opened the other kind of project hands it over with this.
    Gale.openProject = (id, done, kind) => openProject(id, done || goHome, kind);
    const openPair = () => {
      showScreen('pair');
      Gale.pair.open();
    };

    Gale.editor.init();
    Gale.editor.attach(client);
    Gale.pixelEditor.init();
    Gale.pixelEditor.attach(client);
    Gale.home.init(client, openProject, openPair);
    Gale.pair.init(() => {
      Gale.pair.close();
      goHome();
    });

    // If the drawing you have open gets deleted somewhere else, go back home.
    const seen = new Set();
    client.on('projects', (list) => {
      const ids = new Set(list.map((p) => p.id));
      const ed = Gale.editor.isOpen ? Gale.editor : Gale.pixelEditor.isOpen ? Gale.pixelEditor : null;
      const open = ed ? ed.projectId : null;
      const wasThere = open && seen.has(open);
      seen.clear();
      for (const id of ids) seen.add(id);
      if (open && wasThere && !ids.has(open)) {
        ed.close();
        goHome();
        Gale.ui.toast('That drawing was deleted on another device.', 3500);
      }
    });

    window.galeAPI.on('update:ready', (u) => {
      if (document.querySelector('.banner.update')) return;
      banner('update',
        el('span', { text: `Update ready${u && u.version ? ` (${u.version})` : ''} — restart to use it` }),
        el('button', { class: 'btn small primary', text: 'Restart', onclick: () => window.galeAPI.installUpdate() }));
    });

    client.connect();
    showScreen('home');
  }

  start().catch((err) => {
    document.body.textContent = `Gale couldn't start: ${err.message}`;
  });
})();
