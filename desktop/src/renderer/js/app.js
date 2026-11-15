'use strict';
// Starts everything and switches between the three screens.
(function () {
  const Gale = window.Gale;
  const { $, el, banner } = Gale.ui;

  function showScreen(id) {
    for (const s of ['home', 'editor', 'pair']) $(s).hidden = s !== id;
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
    const openProject = (id) => {
      Gale.editor.open(client, id, goHome);
      showScreen('editor');
      Gale.editor.requestRender();
    };
    const openPair = () => {
      showScreen('pair');
      Gale.pair.open();
    };

    Gale.editor.init();
    Gale.editor.attach(client);
    Gale.home.init(client, openProject, openPair);
    Gale.pair.init(() => {
      Gale.pair.close();
      goHome();
    });

    // If the drawing you have open gets deleted somewhere else, go back home.
    const seen = new Set();
    client.on('projects', (list) => {
      const ids = new Set(list.map((p) => p.id));
      const open = Gale.editor.isOpen ? Gale.editor.projectId : null;
      const wasThere = open && seen.has(open);
      seen.clear();
      for (const id of ids) seen.add(id);
      if (open && wasThere && !ids.has(open)) {
        Gale.editor.close();
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
