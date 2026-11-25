'use strict';
// A tiny fake browser for smoke-testing the renderer scripts in Node (no packages needed).

class ClassList {
  constructor(elm) {
    this.e = elm;
  }
  get list() {
    return this.e.className.split(/\s+/).filter(Boolean);
  }
  add(...c) {
    const l = this.list;
    for (const x of c) if (!l.includes(x)) l.push(x);
    this.e.className = l.join(' ');
  }
  remove(...c) {
    this.e.className = this.list.filter((x) => !c.includes(x)).join(' ');
  }
  contains(c) {
    return this.list.includes(c);
  }
  toggle(c, on) {
    const has = this.contains(c);
    const want = on === undefined ? !has : !!on;
    if (want) this.add(c);
    else this.remove(c);
    return want;
  }
}

class Node {
  constructor(doc) {
    this.ownerDocument = doc;
    this.parentNode = null;
    this.children = [];
    this.childNodes = [];
  }
}

class TextNode extends Node {
  constructor(doc, text) {
    super(doc);
    this.nodeType = 3;
    this.data = String(text);
  }
  get textContent() {
    return this.data;
  }
}

class Element extends Node {
  constructor(doc, tag) {
    super(doc);
    this.nodeType = 1;
    this.tagName = tag.toUpperCase();
    this.className = '';
    this.attrs = {};
    this.listeners = {};
    this.style = { cssText: '' };
    this.dataset = {};
    this.hidden = false;
    this.disabled = false;
    this.value = '';
    this.checked = false;
    this.innerHTML = '';
    this.classList = new ClassList(this);
    this.width = 300;
    this.height = 150;
  }
  get id() {
    return this.attrs.id || '';
  }
  setAttribute(k, v) {
    this.attrs[k] = String(v);
    if (k === 'class') this.className = String(v);
    if (k.startsWith('data-')) this.dataset[k.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = String(v);
    if (k === 'value') this.value = String(v);
    if (k === 'disabled') this.disabled = true;
    if (k === 'selected') this.selected = true;
    if (k === 'hidden') this.hidden = true;
  }
  getAttribute(k) {
    return this.attrs[k] == null ? null : this.attrs[k];
  }
  appendChild(c) {
    if (c.parentNode) c.parentNode.removeChild(c);
    c.parentNode = this;
    this.childNodes.push(c);
    if (c.nodeType === 1) this.children.push(c);
    if (this.tagName === 'SELECT' && c.tagName === 'OPTION' && (c.selected || this.children.length === 1)) this.value = c.value;
    return c;
  }
  removeChild(c) {
    this.childNodes = this.childNodes.filter((x) => x !== c);
    this.children = this.children.filter((x) => x !== c);
    c.parentNode = null;
    return c;
  }
  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }
  get textContent() {
    return this.childNodes.map((c) => c.textContent).join('');
  }
  set textContent(v) {
    for (const c of this.childNodes) c.parentNode = null;
    this.childNodes = [];
    this.children = [];
    if (v !== '' && v != null) this.appendChild(new TextNode(this.ownerDocument, v));
  }
  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn);
  }
  dispatch(type, props = {}) {
    const ev = { type, target: this, currentTarget: this, preventDefault() {}, stopPropagation() {}, button: 0, ...props };
    for (const fn of (this.listeners[type] || []).slice()) fn(ev);
    const on = this[`on${type}`];
    if (typeof on === 'function') on.call(this, ev);
    return ev;
  }
  click() {
    if (!this.disabled) this.dispatch('click');
  }
  focus() {
    this.ownerDocument.activeElement = this;
  }
  select() {}
  get isConnected() {
    let n = this;
    while (n.parentNode) n = n.parentNode;
    return n === this.ownerDocument.body || n === this.ownerDocument.root;
  }
  contains(x) {
    while (x) {
      if (x === this) return true;
      x = x.parentNode;
    }
    return false;
  }
  getBoundingClientRect() {
    return { left: 0, top: 0, width: this.clientWidth, height: this.clientHeight, right: this.clientWidth, bottom: this.clientHeight };
  }
  get clientWidth() {
    return 800;
  }
  get clientHeight() {
    return 600;
  }
  get offsetWidth() {
    return 800;
  }
  setPointerCapture() {}
  scrollIntoView() {}
  all() {
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
  matches(sel) {
    const m = /^\[data-field="(.*)"\]$/.exec(sel);
    if (m) return this.dataset.field === m[1];
    if (sel.startsWith('.'))
      return sel
        .slice(1)
        .split('.')
        .every((c) => this.classList.contains(c));
    if (sel.startsWith('#')) return this.id === sel.slice(1);
    return sel
      .split(',')
      .map((s) => s.trim().toUpperCase())
      .some((s) => s === this.tagName || (s === 'BUTTON.PRIMARY' && this.tagName === 'BUTTON' && this.classList.contains('primary')));
  }
  querySelector(sel) {
    return this.all().find((e) => e.matches(sel)) || null;
  }
  querySelectorAll(sel) {
    return this.all().filter((e) => e.matches(sel));
  }
  getContext() {
    if (this.tagName !== 'CANVAS') return null;
    if (!this.ctx) this.ctx = fakeCtx(this);
    return this.ctx;
  }
  toBlob(cb) {
    cb({ arrayBuffer: async () => new Uint8Array([137, 80, 78, 71]).buffer });
  }
}

function fakeCtx(canvas) {
  const calls = [];
  const noop =
    (name) =>
    (...a) => {
      calls.push(name);
    };
  return new Proxy(
    { calls, canvas },
    {
      get(t, k) {
        if (k in t) return t[k];
        if (k === 'putImageData')
          return (img) => {
            if (!img || !img.data || !img.width) throw new Error('not ImageData');
            if (img.width !== canvas.width || img.height !== canvas.height)
              throw new Error(`putImageData size ${img.width}x${img.height} vs canvas ${canvas.width}x${canvas.height}`);
            calls.push('putImageData');
          };
        if (k === 'drawImage')
          return (src) => {
            if (!src || src.tagName !== 'CANVAS') throw new Error('drawImage needs a canvas');
            calls.push('drawImage');
          };
        return noop(k);
      },
      set(t, k, v) {
        t[k] = v;
        return true;
      },
    },
  );
}

function makeDocument() {
  const doc = { activeElement: null };
  doc.body = new Element(doc, 'body');
  doc.ids = new Map();
  doc.createElement = (tag) => new Element(doc, tag);
  doc.createTextNode = (t) => new TextNode(doc, t);
  doc.getElementById = (id) => {
    if (!doc.ids.has(id)) {
      const tag = /view$|^px-view$/.test(id) ? 'canvas' : /^px-fps$|^px-color-input$|^fps$|^br-/.test(id) ? 'input' : 'div';
      const e = new Element(doc, tag);
      e.setAttribute('id', id);
      doc.body.appendChild(e);
      doc.ids.set(id, e);
    }
    return doc.ids.get(id);
  };
  doc.querySelector = (sel) => doc.body.querySelector(sel);
  doc.listeners = {};
  doc.addEventListener = (t, fn) => {
    (doc.listeners[t] = doc.listeners[t] || []).push(fn);
  };
  doc.removeEventListener = (t, fn) => {
    doc.listeners[t] = (doc.listeners[t] || []).filter((f) => f !== fn);
  };
  return doc;
}

module.exports = { makeDocument, Element };
