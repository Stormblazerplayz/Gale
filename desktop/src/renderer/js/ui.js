'use strict';
// Small helpers for the window: building elements, pop-up boxes, toasts.
(function () {
  const Gale = (window.Gale = window.Gale || {});

  function el(tag, attrs, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (k === 'style') e.style.cssText = v;
      else e.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat()) {
      if (kid == null || kid === false) continue;
      e.appendChild(typeof kid === 'string' ? document.createTextNode(kid) : kid);
    }
    return e;
  }

  const $ = (id) => document.getElementById(id);

  let toastTimer = null;
  function toast(text, ms = 2200) {
    const t = $('toast');
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, ms);
  }

  /** Shows a box. `build(close)` returns the inside. Resolves with whatever close() gets. */
  function modal(build, { dismiss = true } = {}) {
    return new Promise((resolve) => {
      const root = $('modal-root');
      let back;
      const close = (value) => {
        document.removeEventListener('keydown', onKey, true);
        back.remove();
        resolve(value);
      };
      const onKey = (e) => {
        if (e.key === 'Escape' && dismiss) {
          e.stopPropagation();
          close(null);
        }
      };
      const box = el('div', { class: 'modal', role: 'dialog' }, build(close));
      back = el('div', { class: 'modal-back' }, box);
      if (dismiss) back.addEventListener('pointerdown', (e) => { if (e.target === back) close(null); });
      root.appendChild(back);
      document.addEventListener('keydown', onKey, true);
      const first = box.querySelector('input, select, button.primary');
      if (first) setTimeout(() => { first.focus(); if (first.select) first.select(); }, 0);
    });
  }

  /** Asks for some text (Electron has no window.prompt). */
  function askText(title, value = '', { okText = 'OK', maxLength = 80 } = {}) {
    return modal((close) => {
      const input = el('input', { type: 'text', value, maxlength: String(maxLength) });
      const ok = () => {
        const v = input.value.trim();
        if (v) close(v);
        else input.focus();
      };
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') ok(); });
      return [
        el('h2', { text: title }),
        el('div', { class: 'field' }, input),
        el('div', { class: 'buttons' },
          el('button', { class: 'btn', text: 'Cancel', onclick: () => close(null) }),
          el('button', { class: 'btn primary', text: okText, onclick: ok })),
      ];
    });
  }

  function confirmBox(title, text, { okText = 'OK', danger = false } = {}) {
    return modal((close) => [
      el('h2', { text: title }),
      text ? el('p', { text }) : null,
      el('div', { class: 'buttons' },
        el('button', { class: 'btn', text: 'Cancel', onclick: () => close(false) }),
        el('button', { class: danger ? 'btn primary danger' : 'btn primary', text: okText, onclick: () => close(true) })),
    ]).then((v) => !!v);
  }

  function timeAgo(iso) {
    const ms = Date.parse(iso);
    if (!Number.isFinite(ms)) return '';
    const s = Math.max(0, (Date.now() - ms) / 1000);
    if (s < 45) return 'just now';
    if (s < 90) return 'a minute ago';
    if (s < 3600) return `${Math.round(s / 60)} minutes ago`;
    if (s < 5400) return 'an hour ago';
    if (s < 86400) return `${Math.round(s / 3600)} hours ago`;
    if (s < 172800) return 'yesterday';
    if (s < 30 * 86400) return `${Math.round(s / 86400)} days ago`;
    return new Date(ms).toLocaleDateString();
  }

  /** Adds a banner at the top. Returns a function that removes it. */
  function banner(kind, ...kids) {
    const b = el('div', { class: `banner ${kind}` }, ...kids);
    $('banners').appendChild(b);
    return () => b.remove();
  }

  const isTyping = (e) => {
    const t = e.target;
    return t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable);
  };

  Gale.ui = { el, $, toast, modal, askText, confirmBox, timeAgo, banner, isTyping };
})();
