'use strict';
// "Pair a device": the QR code, the 6 numbers, this computer's addresses and the paired devices.
(function () {
  const Gale = (window.Gale = window.Gale || {});
  const { el, $, toast, confirmBox, timeAgo } = Gale.ui;

  const P = { visible: false, info: null, timer: 0, starting: false };

  async function newCode() {
    if (P.starting) return;
    P.starting = true;
    try {
      show(await window.galeAPI.pairStart());
    } finally {
      P.starting = false;
    }
  }

  function show(info) {
    P.info = info;
    $('pair-error').hidden = !info.hubError;
    $('pair-error').textContent = info.hubError || '';
    if (info.qr) $('pair-qr').src = info.qr;
    $('pair-code').textContent = info.code ? `${info.code.slice(0, 3)} ${info.code.slice(3)}` : '— — —';
    $('pair-name').textContent = info.serverName;
    const ips = $('pair-ips');
    ips.textContent = '';
    if (!info.ips.length) ips.appendChild(el('li', { text: 'No network found. Connect this computer to Wi-Fi.' }));
    for (const ip of info.ips) {
      const what = ip.kind === 'tailscale' ? 'Tailscale (works away from home)' : ip.kind === 'lan' ? 'Home network' : 'Network';
      ips.appendChild(el('li', {}, el('b', { text: ip.address }), ` · ${what} (${ip.name})`));
    }
    tick();
  }

  function tick() {
    const info = P.info;
    const t = $('pair-timer');
    if (!info) return;
    if (!info.code || !info.expiresAt) {
      // Used up (too many wrong tries). Making a new one is up to you, so guessing can't go on forever.
      t.textContent = 'This code can\'t be used any more. Press "Make a new code".';
      $('pair-code').textContent = '— — —';
      $('pair-qr').style.opacity = '0.12';
      return;
    }
    const left = Math.max(0, Math.round((info.expiresAt - Date.now()) / 1000));
    if (left <= 0) {
      if (P.visible) newCode();
      return;
    }
    $('pair-qr').style.opacity = '1';
    const tries = info.triesLeft < 5 ? ` · ${info.triesLeft} ${info.triesLeft === 1 ? 'try' : 'tries'} left` : '';
    t.textContent = `Works for ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')} more${tries}`;
  }

  async function showDevices(list) {
    const devices = list || (await window.galeAPI.devices());
    const ul = $('device-list');
    ul.textContent = '';
    if (!devices.length) {
      ul.appendChild(el('li', { class: 'none', text: 'No devices yet. Scan the code with your iPad or iPhone to add one.' }));
      return;
    }
    for (const d of devices) {
      ul.appendChild(el('li', {},
        el('span', { class: `dot${d.online ? ' on' : ''}`, title: d.online ? 'Connected now' : 'Not connected' }),
        el('div', { class: 'dname' }, el('div', { text: d.deviceName }), el('div', { class: 'dsub', text: d.online ? 'Connected now' : `Last seen ${timeAgo(d.lastSeen)}` })),
        el('button', {
          class: 'btn small danger',
          text: 'Remove',
          onclick: async () => {
            if (await confirmBox(`Remove ${d.deviceName}?`, 'It stops syncing with this computer until you pair it again.', { okText: 'Remove', danger: true })) {
              await window.galeAPI.removeDevice(d.deviceId);
              showDevices();
            }
          },
        })));
    }
  }

  function open() {
    P.visible = true;
    newCode();
    showDevices();
    clearInterval(P.timer);
    P.timer = setInterval(tick, 1000);
  }

  function close() {
    P.visible = false;
    clearInterval(P.timer);
    window.galeAPI.pairStop();
  }

  function init(onBack) {
    $('pair-back').onclick = onBack;
    $('pair-new').onclick = newCode;
    window.galeAPI.on('pair:changed', (info) => {
      if (!P.visible || !P.info || P.starting) return;
      if (info.code && info.code === P.info.code) {
        P.info.triesLeft = info.triesLeft;
      } else if (!info.code) {
        P.info = { ...P.info, code: null, expiresAt: null };
      }
      tick();
    });
    window.galeAPI.on('pair:paired', (d) => {
      toast(`${d.deviceName} is paired!`, 3000);
      if (P.visible) newCode();
    });
    window.galeAPI.on('devices:changed', (list) => {
      if (P.visible) showDevices(list);
    });
  }

  Gale.pair = { init, open, close };
})();
