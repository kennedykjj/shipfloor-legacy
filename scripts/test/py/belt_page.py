"""The dashboard page, run in node on a small fake DOM (#181): dashboard.html's own script is loaded as the browser would,
fed overviews through its own loadOverview(), and the tests read what it drew (the tree under #cells, the header's status
sentence), what it animated (Element.animate calls, inline styles), where it moved focus, and what the page's CSS makes
of each drawn element (a cascade over the page's <style> for a viewport width and prefers-reduced-motion).

belt_page.run(ops, width=1280, reduced=False) -> {"results": [one per op], "errors": [...]}. An op is a dict:
  read       {"op": "read", "overview": {...}}   the page's loadOverview() answered with this overview; result: the belt snapshot
  focus      {"op": "focus", "key": "shop/120"}  focus() on that token                  result: the snapshot
  focuslook  {"op": "focuslook", "key": "shop/120"}  the css that token has while it is :focus-visible (a dict)
  press      {"op": "press", "key": "ArrowRight"[, "on": "shop/120"]}  keydown on the focused (or that) element, then the
             click a browser makes of Enter/Space on a button                         result: the snapshot
  click      {"op": "click", "key": "shop/120"}  a click on that token                   result: the snapshot, with the page's S
  advance    {"op": "advance", "ms": 2000}       the page's timers due within that time run
  find       {"op": "find", "needle": "text"}    the smallest elements whose text holds needle (with their ancestors)
Replay (#184) adds, all of them waiting for the page's promises to settle before they answer:
  day        {"op": "day", "day": {...}}         what GET /api/day/<project> answers (null: HTTP 500; no "day" key: 404)
  settle / advance_settle {"ms": n}              let the page's promises run / advance the timers, then let them run
  keysel     {"op": "keysel", "sel": css, "key": "Home"}  keydown on the first element matching css                  result: the snapshot
  clicksel / focussel {"sel": css}               click / focus the first element matching css                       result: the snapshot
  clicktext  {"op": "clicktext", "text": "Back to live"}  click the visible button with exactly that text         result: the snapshot
  query      {"op": "query", "sel": css}         [{tag, attrs, css, text}] of every match anywhere in the page
  fetches    the requests the page made since the last call, [{path, method}]        hash: the address's fragment now
  active     the focused element {tag, attrs}    eval: {"code": "return ..."} JSON of the page's own state
A snapshot is {"cells": node, "chain": [ancestors of #cells], "anim": [...], "styles": [...], "scrolls": [...], "active": ...,
"S": {...}}; a node is {"tag", "attrs", "css": {property: winning value}, "kids": [node or text]}.
Standard library only (node is the browser stand-in, as in dashboard-brief.test.sh)."""
import json
import os
import re
import shutil
import subprocess
import tempfile

import support

HTML = os.path.join(support.SCRIPTS, "dashboard.html")
EN = os.path.join(support.SCRIPTS, "lang", "dashboard.en.json")

HARNESS = r'''
"use strict";
const fs = require("fs"), vm = require("vm");
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const source = fs.readFileSync(cfg.html, "utf8").replace(/\r\n/g, "\n");
const EN = JSON.parse(fs.readFileSync(cfg.lang, "utf8")).messages;
const LOG = { anim: [], styles: [], scrolls: [], errors: [], fetches: [] };
process.on("unhandledRejection", (e) => LOG.errors.push("rejection: " + ((e && e.stack) || e)));
process.on("uncaughtException", (e) => { LOG.errors.push("exception: " + ((e && e.stack) || e)); });

// ---------------------------------------------------------------- the tree
const ENT = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", middot: "·", nbsp: " ", hellip: "…", mdash: "—", ndash: "–" };
const dec = (s) => s.replace(/&(#x?[0-9a-fA-F]+|\w+);/g, (m, e) => e[0] === "#" ? String.fromCodePoint(e[1] === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : (e in ENT ? ENT[e] : m));
const VOID = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
let VER = 0, ACTIVE = null, FOCUSMODE = false;
const kebab = (s) => s.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
const noop = () => undefined;

class Txt {
  constructor(t) { this.nodeType = 3; this.text = String(t); this.parent = null; }
  get textContent() { return this.text; }
  get parentElement() { return this.parent; }
}
class El {
  constructor(tag) {
    this.nodeType = 1; this.tag = String(tag || "div").toLowerCase(); this.tagName = this.tag.toUpperCase();
    this.attrs = {}; this.nodes = []; this.parent = null; this.ls = {}; this._ih = undefined; this._st = {};
    this.value = ""; this.checked = false; this.scrollTop = 0; this.scrollLeft = 0; this.open = false; this.selectionStart = 0;
  }
  get id() { return this.attrs.id || ""; } set id(v) { this.attrs.id = String(v); VER++; }
  get className() { return this.attrs.class || ""; } set className(v) { this.attrs.class = String(v); }
  get hidden() { return "hidden" in this.attrs; } set hidden(v) { if (v) this.attrs.hidden = ""; else delete this.attrs.hidden; }
  get disabled() { return "disabled" in this.attrs; } set disabled(v) { if (v) this.attrs.disabled = ""; else delete this.attrs.disabled; }
  get inert() { return "inert" in this.attrs; } set inert(v) { if (v) this.attrs.inert = ""; else delete this.attrs.inert; }
  get tabIndex() { if ("tabindex" in this.attrs) return Number(this.attrs.tabindex); return (["button", "input", "select", "textarea"].includes(this.tag) || (this.tag === "a" && "href" in this.attrs)) && !this.disabled ? 0 : -1; }
  set tabIndex(v) { this.attrs.tabindex = String(v); }
  get title() { return this.attrs.title || ""; } set title(v) { this.attrs.title = String(v); }
  get href() { return this.attrs.href || ""; } set href(v) { this.attrs.href = String(v); }
  get src() { return this.attrs.src || ""; } set src(v) { this.attrs.src = String(v); }
  get type() { return this.attrs.type || ""; } set type(v) { this.attrs.type = String(v); }
  get name() { return this.attrs.name || ""; } set name(v) { this.attrs.name = String(v); }
  get placeholder() { return this.attrs.placeholder || ""; } set placeholder(v) { this.attrs.placeholder = String(v); }
  get dataset() {
    const el = this;
    return new Proxy({}, {
      get: (_, k) => typeof k === "string" ? el.attrs["data-" + kebab(k)] : undefined,
      set: (_, k, v) => { el.attrs["data-" + kebab(k)] = String(v); return true; },
      has: (_, k) => typeof k === "string" && ("data-" + kebab(k)) in el.attrs,
      deleteProperty: (_, k) => { delete el.attrs["data-" + kebab(k)]; return true; },
      ownKeys: () => Object.keys(el.attrs).filter((a) => a.startsWith("data-")).map((a) => a.slice(5).replace(/-([a-z])/g, (m, c) => c.toUpperCase())),
      getOwnPropertyDescriptor: (_, k) => typeof k === "string" && ("data-" + kebab(k)) in el.attrs ? { enumerable: true, configurable: true, value: el.attrs["data-" + kebab(k)] } : undefined,
    });
  }
  get classList() {
    const el = this, list = () => (el.attrs.class || "").split(/\s+/).filter(Boolean), put = (l) => { el.attrs.class = l.join(" "); };
    return {
      add: (...c) => { const l = list(); for (const x of c) if (!l.includes(x)) l.push(x); put(l); },
      remove: (...c) => put(list().filter((x) => !c.includes(x))),
      contains: (c) => list().includes(c),
      toggle: (c, force) => { const has = list().includes(c), want = force === undefined ? !has : !!force; if (want && !has) put([...list(), c]); if (!want && has) put(list().filter((x) => x !== c)); return want; },
      replace: (a, b) => { const l = list(); if (!l.includes(a)) return false; put(l.map((x) => x === a ? b : x)); return true; },
      get length() { return list().length; }, item: (i) => list()[i] ?? null, [Symbol.iterator]: () => list()[Symbol.iterator](),
    };
  }
  get style() {
    const el = this;
    return new Proxy(el._st, {
      get: (o, k) => k === "setProperty" ? (p, v) => { o[p] = String(v); LOG.styles.push({ el: ref(el), prop: p, value: String(v) }); }
        : k === "removeProperty" ? (p) => { delete o[p]; } : k === "getPropertyValue" ? (p) => o[p] || "" : k === "cssText" ? "" : (o[k] === undefined ? "" : o[k]),
      set: (o, k, v) => { o[k] = String(v); LOG.styles.push({ el: ref(el), prop: String(k), value: String(v) }); return true; },
    });
  }
  get children() { return this.nodes.filter((n) => n.nodeType === 1); }
  get childNodes() { return this.nodes; }
  get firstChild() { return this.nodes[0] || null; } get lastChild() { return this.nodes[this.nodes.length - 1] || null; }
  get firstElementChild() { return this.children[0] || null; } get lastElementChild() { const c = this.children; return c[c.length - 1] || null; }
  get parentElement() { return this.parent; } get parentNode() { return this.parent; }
  get nextElementSibling() { if (!this.parent) return null; const c = this.parent.children; return c[c.indexOf(this) + 1] || null; }
  get previousElementSibling() { if (!this.parent) return null; const c = this.parent.children; return c[c.indexOf(this) - 1] || null; }
  get isConnected() { let e = this; while (e.parent) e = e.parent; return e === ROOT; }
  get innerHTML() { return this._ih !== undefined ? this._ih : this.nodes.map(ser).join(""); }
  set innerHTML(v) { this.clear(); this._ih = String(v); parseInto(this, String(v)); VER++; settleFocus(); }
  get outerHTML() { return ser(this); }
  get textContent() { return this.nodes.map((n) => n.textContent).join(""); }
  set textContent(v) { this.clear(); this._ih = undefined; this.nodes = [new Txt(v)]; this.nodes[0].parent = this; VER++; settleFocus(); }
  get innerText() { return this.textContent; } set innerText(v) { this.textContent = v; }
  get offsetParent() { return hiddenIn(this) ? null : (this.parent || ROOT); }
  get offsetWidth() { return rectOf(this).width; } get offsetHeight() { return rectOf(this).height; }
  get clientWidth() { return rectOf(this).width; } get clientHeight() { return rectOf(this).height; } get scrollWidth() { return rectOf(this).width; } get scrollHeight() { return rectOf(this).height; }
  get ownerDocument() { return DOC; }
  clear() { for (const n of this.nodes) n.parent = null; this.nodes = []; }
  getAttribute(n) { n = String(n).toLowerCase(); return n in this.attrs ? this.attrs[n] : null; }
  setAttribute(n, v) { n = String(n).toLowerCase(); this.attrs[n] = String(v); if (n === "id") VER++; }
  removeAttribute(n) { delete this.attrs[String(n).toLowerCase()]; }
  hasAttribute(n) { return String(n).toLowerCase() in this.attrs; }
  toggleAttribute(n, force) { const has = this.hasAttribute(n), want = force === undefined ? !has : !!force; if (want) this.attrs[n] = this.attrs[n] ?? ""; else delete this.attrs[n]; return want; }
  appendChild(n) { return this.insertBefore(n, null); }
  append(...ns) { for (const n of ns) this.insertBefore(typeof n === "string" ? new Txt(n) : n, null); }
  prepend(...ns) { for (const n of ns.reverse()) this.insertBefore(typeof n === "string" ? new Txt(n) : n, this.nodes[0] || null); }
  insertBefore(n, ref) { if (n.parent) n.parent.nodes.splice(n.parent.nodes.indexOf(n), 1); const i = ref ? this.nodes.indexOf(ref) : -1; if (i < 0) this.nodes.push(n); else this.nodes.splice(i, 0, n); n.parent = this; this._ih = undefined; VER++; return n; }
  removeChild(n) { const i = this.nodes.indexOf(n); if (i >= 0) { this.nodes.splice(i, 1); n.parent = null; this._ih = undefined; VER++; settleFocus(); } return n; }
  remove() { if (this.parent) this.parent.removeChild(this); }
  replaceChildren(...ns) { this.clear(); this._ih = undefined; this.append(...ns); }
  insertAdjacentHTML(pos, html) {
    const tmp = new El("div"); parseInto(tmp, String(html)); const kids = [...tmp.nodes];
    if (pos === "afterbegin") this.prepend(...kids); else if (pos === "beforeend") this.append(...kids);
    else if (pos === "beforebegin" && this.parent) for (const k of kids) this.parent.insertBefore(k, this);
    else if (pos === "afterend" && this.parent) { const nx = this.parent.nodes[this.parent.nodes.indexOf(this) + 1] || null; for (const k of kids) this.parent.insertBefore(k, nx); }
  }
  contains(n) { for (let e = n; e; e = e.parent) if (e === this) return true; return false; }
  matches(sel) { return matchesAny(this, sel, null); }
  closest(sel) { for (let e = this; e && e.nodeType === 1; e = e.parent) if (matchesAny(e, sel, null)) return e; return null; }
  querySelector(sel) { return queryAll(this, sel, true)[0] || null; }
  querySelectorAll(sel) { return queryAll(this, sel, false); }
  getElementsByTagName(t) { return queryAll(this, t, false); }
  addEventListener(type, fn) { (this.ls[type] ||= []).push(fn); }
  removeEventListener(type, fn) { this.ls[type] = (this.ls[type] || []).filter((f) => f !== fn); }
  dispatchEvent(ev) { ev.target = ev.target || this; dispatch(ev); return !ev.defaultPrevented; }
  focus() { if (hiddenIn(this) || this.disabled) return; ACTIVE = this; dispatch(mkEvent("focusin", this, {})); }
  blur() { if (ACTIVE === this) ACTIVE = null; }
  click() { dispatch(mkEvent("click", this, {})); }
  getBoundingClientRect() { const r = rectOf(this); return { ...r, x: r.left, y: r.top, toJSON: noop }; }
  getClientRects() { return hiddenIn(this) ? [] : [this.getBoundingClientRect()]; }
  animate(keyframes, options) { LOG.anim.push({ el: ref(this), keyframes: JSON.parse(JSON.stringify(keyframes || null)), options: typeof options === "number" ? { duration: options } : JSON.parse(JSON.stringify(options || {})) }); return { onfinish: null, finished: Promise.resolve(), cancel: noop, finish: noop, play: noop, pause: noop, reverse: noop, addEventListener: noop }; }
  getAnimations() { return []; }
  scrollIntoView(o) { LOG.scrolls.push({ el: ref(this), opts: JSON.parse(JSON.stringify(o === undefined ? null : o)) }); }
  scrollTo() {} scrollBy() {} select() {} setSelectionRange() {} showModal() {} close() {} requestSubmit() {} reset() {} setPointerCapture() {} releasePointerCapture() {} before() {} after() {} replaceWith() {}
  checkValidity() { return true; } reportValidity() { return true; } setCustomValidity() {}
}
const ref = (el) => { const k = el.closest ? el.closest("[data-key]") : null; return { tag: el.tag, id: el.id, key: k ? k.attrs["data-key"] : null, cls: el.attrs.class || "", role: el.attrs.role || "" }; };
function add(parent, n) { n.parent = parent; parent.nodes.push(n); }
function parseAttrs(el, s) {
  const re = /([^\s=\/"'<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g; let m;
  while ((m = re.exec(s))) el.attrs[m[1].toLowerCase()] = dec(m[2] ?? m[3] ?? m[4] ?? "");
}
function parseInto(parent, str) {
  const stack = [parent], re = /<!--[\s\S]*?-->|<(\/?)([a-zA-Z][\w:-]*)((?:"[^"]*"|'[^']*'|[^'">])*?)(\/?)>|([^<]+|<)/g; let m;
  while ((m = re.exec(str))) {
    if (m[0].startsWith("<!--")) continue;
    const top = stack[stack.length - 1];
    if (m[5] !== undefined) { if (m[5] !== "<") add(top, new Txt(dec(m[5]))); continue; }
    const tag = m[2].toLowerCase();
    if (m[1] === "/") { for (let i = stack.length - 1; i > 0; i--) if (stack[i].tag === tag) { stack.length = i; break; } continue; }
    const el = new El(tag); parseAttrs(el, m[3]); add(top, el);
    if (!m[4] && !VOID.has(tag)) stack.push(el);
  }
}
const escA = (s) => String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
function ser(n) {
  if (n.nodeType === 3) return n.text.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const a = Object.entries(n.attrs).map(([k, v]) => v === "" ? ` ${k}` : ` ${k}="${escA(v)}"`).join("");
  return VOID.has(n.tag) ? `<${n.tag}${a}>` : `<${n.tag}${a}>${n.nodes.map(ser).join("")}</${n.tag}>`;
}
const hiddenIn = (el) => { for (let e = el; e && e.nodeType === 1; e = e.parent) if (e.hidden) return true; return false; };
function settleFocus() { if (ACTIVE && !ACTIVE.isConnected) ACTIVE = null; }
function walk(el, fn) { fn(el); for (const n of el.nodes) if (n.nodeType === 1) walk(n, fn); }

// ---------------------------------------------------------------- selectors
function unesc(s) { return s.replace(/\\(.)/g, "$1"); }
function parseCompound(s, i, c) {
  const n = s.length;
  while (i < n && !/[\s>+~]/.test(s[i])) {
    const ch = s[i];
    if (ch === "*") { c.tag = "*"; i++; }
    else if (ch === "#" || ch === ".") {
      const m = /^((?:\\.|[\w-])+)/.exec(s.slice(i + 1)); if (!m) { c.bad = true; return n; }
      if (ch === "#") c.id = unesc(m[1]); else c.classes.push(unesc(m[1])); i += 1 + m[1].length;
    } else if (ch === "[") {
      const j = s.indexOf("]", i); const body = s.slice(i + 1, j < 0 ? n : j);
      const m = /^\s*([\w-]+)\s*(?:([~|^$*]?=)\s*(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)'|([^\s\]]+))\s*(i)?)?\s*$/.exec(body);
      if (m) c.attrs.push({ name: m[1].toLowerCase(), op: m[2] || null, val: unesc(m[3] ?? m[4] ?? m[5] ?? ""), ci: !!m[6] }); else c.bad = true;
      i = (j < 0 ? n : j) + 1;
    } else if (ch === ":") {
      const m = /^::?([\w-]+)/.exec(s.slice(i)); if (!m) { c.bad = true; return n; }
      i += m[0].length;
      if (s[i] === "(") { let d = 0, j = i; for (; j < n; j++) { if (s[j] === "(") d++; if (s[j] === ")" && --d === 0) break; } i = j + 1; }
      if (m[1] === "scope") c.scope = true; else if (m[1] === "focus-visible" || m[1] === "focus") c.focus = true; else c.bad = true;
    } else if (/[\w-]/.test(ch)) { const m = /^[\w-]+/.exec(s.slice(i)); c.tag = m[0].toLowerCase(); i += m[0].length; }
    else { c.bad = true; return n; }
  }
  return i;
}
function parseComplex(s) {
  const out = []; let i = 0, comb = null; const n = s.length;
  while (i < n) {
    let ws = false; while (i < n && /\s/.test(s[i])) { i++; ws = true; }
    if (i >= n) break;
    if (">+~".includes(s[i])) { comb = s[i]; i++; continue; }
    const c = { tag: null, id: null, classes: [], attrs: [], bad: false, scope: false, focus: false, comb: out.length ? (comb || " ") : null };
    comb = null; i = parseCompound(s, i, c); out.push(c);
  }
  return out;
}
const SELCACHE = new Map();
function parseSel(sel) {
  if (SELCACHE.has(sel)) return SELCACHE.get(sel);
  const parts = []; let d = 0, cur = "";
  for (const ch of String(sel)) { if (ch === "(" || ch === "[") d++; if (ch === ")" || ch === "]") d--; if (ch === "," && d === 0) { parts.push(cur); cur = ""; } else cur += ch; }
  parts.push(cur);
  const r = parts.map((p) => parseComplex(p.trim())).filter((x) => x.length);
  SELCACHE.set(sel, r); return r;
}
function matchCompound(el, c, scope) {
  if (c.bad) return false;
  if (c.scope && el !== scope) return false;
  if (c.focus && !FOCUSMODE) return false;
  if (c.tag && c.tag !== "*" && el.tag !== c.tag) return false;
  if (c.id !== null && el.attrs.id !== c.id) return false;
  if (c.classes.length) { const l = (el.attrs.class || "").split(/\s+/); for (const k of c.classes) if (!l.includes(k)) return false; }
  for (const a of c.attrs) {
    if (!(a.name in el.attrs)) return false;
    let v = el.attrs[a.name], w = a.val; if (a.ci) { v = v.toLowerCase(); w = w.toLowerCase(); }
    if (a.op === "=" && v !== w) return false; if (a.op === "^=" && !v.startsWith(w)) return false; if (a.op === "$=" && !v.endsWith(w)) return false;
    if (a.op === "*=" && !v.includes(w)) return false; if (a.op === "~=" && !v.split(/\s+/).includes(w)) return false; if (a.op === "|=" && v !== w && !v.startsWith(w + "-")) return false;
  }
  return true;
}
function matchFrom(el, cx, idx, scope) {
  if (!matchCompound(el, cx[idx], scope)) return false;
  if (idx === 0) return true;
  const comb = cx[idx].comb;
  if (comb === ">") return !!el.parent && el.parent.nodeType === 1 && matchFrom(el.parent, cx, idx - 1, scope);
  if (comb === " ") { for (let p = el.parent; p && p.nodeType === 1; p = p.parent) if (matchFrom(p, cx, idx - 1, scope)) return true; return false; }
  const sibs = el.parent ? el.parent.children : [], at = sibs.indexOf(el);
  if (comb === "+") return at > 0 && matchFrom(sibs[at - 1], cx, idx - 1, scope);
  for (let k = 0; k < at; k++) if (matchFrom(sibs[k], cx, idx - 1, scope)) return true;
  return false;
}
const matchesAny = (el, sel, scope) => parseSel(sel).some((cx) => matchFrom(el, cx, cx.length - 1, scope));
function queryAll(root, sel, first) {
  const out = [], cxs = parseSel(sel);
  const go = (el) => {
    for (const n of el.nodes) {
      if (n.nodeType !== 1) continue;
      if (cxs.some((cx) => matchFrom(n, cx, cx.length - 1, root))) { out.push(n); if (first) return true; }
      if (go(n)) return true;
    }
    return false;
  };
  go(root); return out;
}

// ---------------------------------------------------------------- events
function mkEvent(type, target, extra) {
  const ev = { type, target, bubbles: true, defaultPrevented: false, _stop: false, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, ...extra };
  ev.preventDefault = () => { ev.defaultPrevented = true; }; ev.stopPropagation = () => { ev._stop = true; }; ev.stopImmediatePropagation = () => { ev._stop = true; };
  return ev;
}
function dispatch(ev) {
  const path = []; for (let e = ev.target; e; e = e.parent) path.push(e);
  path.push(DOC, WIN);
  for (const node of path) {
    ev.currentTarget = node;
    for (const fn of [...((node.ls || {})[ev.type] || [])]) { try { fn.call(node, ev); } catch (e) { LOG.errors.push(`handler ${ev.type}: ${(e && e.stack) || e}`); } }
    if (ev._stop) break;
  }
}

// ---------------------------------------------------------------- layout: a token's place depends on the segment it is in
let LAYVER = -1, LAY = new Map();
function layout() {
  if (LAYVER === VER) return; LAYVER = VER; LAY = new Map(); let i = 0;
  const cells = byId("cells");
  walk(ROOT, (el) => { LAY.set(el, { left: (i % 40) * 8, top: Math.floor(i / 40) * 8, width: 48, height: 30 }); i++; });
  if (!cells) return;
  const lists = queryAll(cells, '[role="list"]', false);
  walk(cells, (el) => {
    if (!("data-key" in el.attrs)) return;
    let seg = -1, pos = 0;
    for (let p = el.parent; p; p = p.parent) if (p.attrs.role === "list") { seg = lists.indexOf(p); break; }
    if (seg < 0) seg = lists.length;
    const mates = []; if (seg < lists.length) walk(lists[seg], (e) => { if ("data-key" in e.attrs) mates.push(e); });
    pos = Math.max(0, mates.indexOf(el));
    LAY.set(el, { left: 200 * seg + 60 * pos, top: 100, width: 54, height: 30 });
  });
}
function rectOf(el) { layout(); const r = LAY.get(el) || { left: 0, top: 0, width: 0, height: 0 }; return { left: r.left, top: r.top, width: r.width, height: r.height, right: r.left + r.width, bottom: r.top + r.height }; }

// ---------------------------------------------------------------- the css cascade
const ENV = { width: cfg.width, reduced: !!cfg.reduced };
function mq(cond) {
  return cond.split(",").some((q) => q.replace(/\bscreen\b|\ball\b/g, "").split(/\band\b/).map((s) => s.trim()).filter(Boolean).every((f) => {
    let m = /^\(\s*(min-|max-)?width\s*:\s*([\d.]+)px\s*\)$/.exec(f);
    if (m) return m[1] === "min-" ? ENV.width >= +m[2] : m[1] === "max-" ? ENV.width <= +m[2] : ENV.width === +m[2];
    m = /^\(\s*width\s*(<=|<|>=|>)\s*([\d.]+)px\s*\)$/.exec(f);
    if (m) return { "<": ENV.width < +m[2], "<=": ENV.width <= +m[2], ">": ENV.width > +m[2], ">=": ENV.width >= +m[2] }[m[1]];
    m = /^\(\s*prefers-reduced-motion\s*:\s*(\w+)\s*\)$/.exec(f);
    if (m) return m[1] === "reduce" ? ENV.reduced : !ENV.reduced;
    m = /^\(\s*prefers-color-scheme\s*:\s*(\w+)\s*\)$/.exec(f);
    if (m) return m[1] === "dark";
    return false;
  }));
}
function parseDecls(body) {
  const out = []; let d = 0, q = null, cur = "";
  const flush = () => { const i = cur.indexOf(":"); if (i > 0) { let v = cur.slice(i + 1).trim(), imp = /!important\s*$/.test(v); if (imp) v = v.replace(/!important\s*$/, "").trim(); out.push([cur.slice(0, i).trim().toLowerCase(), v, imp]); } cur = ""; };
  for (const ch of body) {
    if (q) { cur += ch; if (ch === q) q = null; continue; }
    if (ch === '"' || ch === "'") q = ch; if (ch === "(") d++; if (ch === ")") d--;
    if (ch === ";" && d === 0) flush(); else cur += ch;
  }
  flush(); return out;
}
function collect(text, out) {
  let i = 0;
  while (i < text.length) {
    const open = text.indexOf("{", i); if (open < 0) break;
    const pre = text.slice(i, open).trim(); let d = 1, j = open + 1;
    while (j < text.length && d) { const c = text[j]; if (c === "{") d++; else if (c === "}") d--; j++; }
    const inner = text.slice(open + 1, j - 1); i = j;
    if (pre.startsWith("@media")) { if (mq(pre.slice(6))) collect(inner, out); }
    else if (pre.startsWith("@layer")) collect(inner, out);
    else if (pre.startsWith("@")) continue;
    else out.push({ pre, inner });
  }
}
function spec(cx) { let a = 0, b = 0, c = 0; for (const k of cx) { if (k.id !== null) a++; b += k.classes.length + k.attrs.length; if (k.tag && k.tag !== "*") c++; } return a * 1e6 + b * 1e3 + c; }
let RULES = null;
function rules() {
  if (RULES) return RULES;
  const css = source.slice(source.indexOf("<style>") + 7, source.indexOf("</style>")).replace(/\/\*[\s\S]*?\*\//g, "").replace(/@font-face\s*\{[^}]*\}/g, "");
  const raw = []; collect(css, raw); RULES = [];
  raw.forEach((r, order) => {
    const sels = parseSel(r.pre).filter((cx) => !cx.some((k) => k.bad)); if (!sels.length) return;
    RULES.push({ sels, decls: parseDecls(r.inner).filter(([p]) => !p.startsWith("--")), order });
  });
  return RULES;
}
function computed(el) {
  const best = {};
  const put = (p, v, imp, sp, order) => { const k = (imp ? 1e12 : 0) + sp, cur = best[p]; if (!cur || k > cur.k || (k === cur.k && order >= cur.order)) best[p] = { v, k, order }; };
  for (const r of rules()) {
    let sp = -1;
    for (const cx of r.sels) if (matchFrom(el, cx, cx.length - 1, null)) sp = Math.max(sp, spec(cx));
    if (sp < 0) continue;
    for (const [p, v, imp] of r.decls) put(p, v, imp, sp, r.order);
  }
  if (el.attrs.style) for (const [p, v, imp] of parseDecls(el.attrs.style)) put(p, v, imp, 1e11, 1e9);
  for (const [p, v] of Object.entries(el._st)) put(kebab(p), v, false, 1e11, 1e9);
  return Object.fromEntries(Object.entries(best).map(([p, o]) => [p, o.v]));
}
function dump(el, deep) {
  const o = { tag: el.tag, attrs: { ...el.attrs }, css: computed(el), kids: [] };
  if (deep) for (const n of el.nodes) o.kids.push(n.nodeType === 3 ? n.text : dump(n, true));
  return o;
}

// ---------------------------------------------------------------- the document
const ROOT = new El("html"), HEAD = new El("head"), BODY = new El("body");
ROOT.append(HEAD, BODY);
const bodyAt = source.indexOf("<body>") + 6, langAt = source.indexOf('<script type="application/json" id="lang-data">');
parseInto(BODY, source.slice(bodyAt, langAt));
const LD = new El("script"); LD.attrs.id = "lang-data"; LD.attrs.type = "application/json";
LD.append(JSON.stringify({ language: "en", messages: EN, en: EN })); BODY.append(LD);
const FAV = new El("link"); FAV.attrs.id = "favicon"; HEAD.append(FAV);
VER++;
let IDV = -1, IDS = new Map();
function byId(id) {
  if (IDV !== VER) { IDV = VER; IDS = new Map(); walk(ROOT, (e) => { if (e.attrs.id && !IDS.has(e.attrs.id)) IDS.set(e.attrs.id, e); }); }
  return IDS.get(id) || null;
}
const DOC = {
  ls: {}, nodes: [], nodeType: 9, documentElement: ROOT, body: BODY, head: HEAD, hidden: false, visibilityState: "visible", readyState: "complete", title: "", fonts: { ready: Promise.resolve() },
  getElementById: (id) => byId(id),
  querySelector: (s) => queryAll(ROOT, s, true)[0] || null, querySelectorAll: (s) => queryAll(ROOT, s, false),
  createElement: (t) => new El(t), createTextNode: (t) => new Txt(t),
  addEventListener(type, fn) { (this.ls[type] ||= []).push(fn); }, removeEventListener(type, fn) { this.ls[type] = (this.ls[type] || []).filter((f) => f !== fn); },
  dispatchEvent(ev) { dispatch(ev); return true; }, hasFocus: () => true, execCommand: () => false,
  get activeElement() { return ACTIVE || BODY; },
};
const store = () => { const m = new Map(); return { getItem: (k) => m.has(k) ? m.get(k) : null, setItem: (k, v) => { m.set(k, String(v)); }, removeItem: (k) => { m.delete(k); }, clear: () => m.clear() }; };
const WIN = { ls: {}, addEventListener(type, fn) { (this.ls[type] ||= []).push(fn); }, removeEventListener() {}, dispatchEvent(ev) { dispatch(ev); return true; } };

// ---------------------------------------------------------------- timers, frames, network
let NOW = 0; const TIMERS = []; let RAFS = [], TID = 1;
const routes = { overview: null, day: undefined };
const fetchStub = (path, opts) => {
  LOG.fetches.push({ path: String(path), method: String((opts && opts.method) || "GET").toUpperCase() });
  if (String(path).startsWith("/api/day/") && routes.day !== undefined) {
    if (routes.day === null) return Promise.resolve({ status: 500, json: () => Promise.resolve({ error: "boom" }), text: () => Promise.resolve("{}") });
    const body = JSON.parse(JSON.stringify(routes.day));
    return Promise.resolve({ status: 200, json: () => Promise.resolve(body), text: () => Promise.resolve(JSON.stringify(body)) });
  }
  if (cfg.intervals && String(path).startsWith("/api/feed")) return Promise.resolve({ status: 200, json: () => Promise.resolve({ events: [] }), text: () => Promise.resolve("{}") });
  if (String(path).startsWith("/api/overview")) {
    if (!routes.overview) return new Promise(() => {});
    const body = JSON.parse(JSON.stringify(routes.overview));
    return Promise.resolve({ status: 200, json: () => Promise.resolve(body), text: () => Promise.resolve(JSON.stringify(body)) });
  }
  return Promise.resolve({ status: 404, json: () => Promise.resolve({}), text: () => Promise.resolve("") });
};
const media = (q) => ({ media: q, get matches() { return mq(q); }, addEventListener: noop, removeEventListener: noop, addListener: noop, removeListener: noop });
const g = {
  window: null, self: null, document: DOC, location: { search: "?t=test", href: "http://127.0.0.1/?t=test", origin: "http://127.0.0.1", hash: cfg.hash || "", pathname: "/" },
  localStorage: store(), sessionStorage: store(), navigator: { clipboard: { writeText: () => { LOG.copied = true; return Promise.resolve(); } }, language: "en", languages: ["en"], userAgent: "node", maxTouchPoints: 0 },
  history: { replaceState: (s, t, u) => setUrl(u), pushState: (s, t, u) => setUrl(u) }, CSS: { escape: (s) => String(s).replace(/[^\w-]/g, (c) => "\\" + c), supports: () => false },
  matchMedia: media, getComputedStyle: (el) => ({ getPropertyValue: () => "", ...(el && el.attrs ? computed(el) : {}) }),
  innerWidth: cfg.width, innerHeight: 800, devicePixelRatio: 1, fetch: fetchStub, console: { log: noop, warn: noop, error: noop, info: noop },
  setTimeout: (fn, ms) => { const id = TID++; TIMERS.push({ id, at: NOW + (ms || 0), fn }); return id; }, clearTimeout: (id) => { const i = TIMERS.findIndex((t) => t.id === id); if (i >= 0) TIMERS.splice(i, 1); },
  setInterval: (fn, ms) => { const id = TID++; if (cfg.intervals) TIMERS.push({ id, at: NOW + (ms || 1), every: ms || 1, fn }); return id; },
  clearInterval: (id) => { const i = TIMERS.findIndex((t) => t.id === id); if (i >= 0) TIMERS.splice(i, 1); }, requestAnimationFrame: (fn) => { RAFS.push(fn); return TID++; }, cancelAnimationFrame: noop,
  addEventListener: (t, f) => WIN.addEventListener(t, f), removeEventListener: noop, dispatchEvent: (ev) => WIN.dispatchEvent(ev),
  scrollTo: noop, scrollBy: noop, open: noop, focus: noop, postMessage: noop, getSelection: () => ({ removeAllRanges: noop, toString: () => "" }),
  ResizeObserver: class { observe() {} unobserve() {} disconnect() {} }, MutationObserver: class { observe() {} disconnect() {} }, IntersectionObserver: class { observe() {} disconnect() {} },
  URL, URLSearchParams, AbortController, TextEncoder, TextDecoder, structuredClone, Event: class { constructor(type) { this.type = type; } }, CustomEvent: class { constructor(type, o) { this.type = type; this.detail = o && o.detail; } },
  Element: El, HTMLElement: El, Node: El, Notification: undefined,
};
g.window = g; g.self = g; g.globalThis = g;
const ctx = vm.createContext(g);
function flush() {
  for (let n = 0; n < 50 && RAFS.length; n++) { const q = RAFS; RAFS = []; for (const f of q) { try { f(NOW); } catch (e) { LOG.errors.push("raf: " + ((e && e.stack) || e)); } } }
}
function advance(ms) {
  const end = NOW + ms;
  for (;;) {
    TIMERS.sort((a, b) => a.at - b.at); const t = TIMERS[0];
    if (!t || t.at > end) break;
    TIMERS.shift(); NOW = Math.max(NOW, t.at); clockTo(); if (t.every) { t.at += t.every; TIMERS.push(t); }
    try { t.fn(); } catch (e) { LOG.errors.push("timer: " + ((e && e.stack) || e)); } flush();
  }
  NOW = end; clockTo();
}
// the page's clock: cfg.now (epoch ms) fixes "now"; the fake timers move it
if (cfg.now != null) vm.runInContext(`(() => { const R = Date, base = ${Number(cfg.now)}; globalThis.__off = 0;
  class D extends R { constructor(...a) { if (a.length) super(...a); else super(base + globalThis.__off); } static now() { return base + globalThis.__off; } }
  globalThis.Date = D; })()`, ctx);
const clockTo = () => { if (cfg.now != null) g.__off = NOW; };
function setUrl(u) { if (typeof u !== "string") return; const i = u.indexOf("#"); g.location.hash = i >= 0 ? u.slice(i) : ""; }
const settle = async () => { for (let i = 0; i < 12; i++) await new Promise((r) => setImmediate(r)); flush(); };
const first = (sel) => queryAll(ROOT, sel, true)[0] || null;

// ---------------------------------------------------------------- the page
const heads = source.slice(source.indexOf("<script>") + 8, source.indexOf("</script>"));
const mainAt = source.indexOf("<script>", langAt), main = source.slice(mainAt + 8, source.indexOf("</script>", mainAt));
const bootErrors = [];
try { vm.runInContext(heads, ctx, { filename: "head.js" }); } catch (e) { bootErrors.push("head: " + ((e && e.stack) || e)); }
try { vm.runInContext(main, ctx, { filename: "page.js" }); } catch (e) { bootErrors.push("page: " + ((e && e.stack) || e)); }
flush();

function snapshot() {
  const cells = byId("cells"), chain = [];
  for (let p = cells && cells.parent; p; p = p.parent) chain.push(dump(p, false));
  const act = ACTIVE ? ref(ACTIVE) : null;
  let S = null; try { S = JSON.parse(vm.runInContext("JSON.stringify({open: S.open, full: S.full, tab: S.tab, project: S.project, peek: S.peek || null})", ctx)); } catch (e) { S = { error: String(e) }; }
  const snap = { cells: cells ? dump(cells, true) : null, chain, anim: LOG.anim.splice(0), styles: LOG.styles.splice(0), scrolls: LOG.scrolls.splice(0), active: act, S };
  if (act && ACTIVE) { act.tabindex = ACTIVE.attrs.tabindex ?? null; }
  return snap;
}
const tokenEl = (key) => { const c = byId("cells"); return c ? queryAll(c, '[data-key="' + key.replace(/"/g, '\\"') + '"]', false).find((e) => e.tag === "button") || queryAll(c, '[data-key="' + key.replace(/"/g, '\\"') + '"]', true)[0] : null; };
const norm = (s) => s.replace(/\s+/g, " ").trim();
async function run() {
  const results = [];
  for (const op of cfg.ops) {
    try {
      if (op.op === "read") {
        routes.overview = op.overview; await vm.runInContext("loadOverview()", ctx); flush(); results.push(snapshot());
      } else if (op.op === "advance") { advance(op.ms); flush(); results.push(snapshot()); }
      else if (op.op === "focus") { const e = tokenEl(op.key); if (e) e.focus(); flush(); results.push(snapshot()); }
      else if (op.op === "press") {
        const el = op.on ? tokenEl(op.on) : ACTIVE;
        if (el) {
          const ev = mkEvent("keydown", el, { key: op.key, code: op.key });
          dispatch(ev);
          if (!ev.defaultPrevented && (op.key === "Enter" || op.key === " ") && el.tag === "button" && !el.disabled) dispatch(mkEvent("click", el, {}));
        }
        flush(); results.push(snapshot());
      } else if (op.op === "click") { const e = tokenEl(op.key); if (e) dispatch(mkEvent("click", e, {})); flush(); results.push(snapshot()); }
      else if (op.op === "focuslook") { const e = tokenEl(op.key); FOCUSMODE = true; const css = e ? computed(e) : null; FOCUSMODE = false; results.push(css); }
      else if (op.op === "find") {
        const hits = [];
        const text = (e) => norm(e.textContent);
        walk(BODY, (e) => {
          if (!text(e).includes(op.needle)) return;
          if (e.children.some((k) => text(k).includes(op.needle))) return;
          const chain = []; for (let p = e; p && p !== ROOT; p = p.parent) chain.push({ tag: p.tag, id: p.id, attrs: { ...p.attrs } });
          hits.push({ tag: e.tag, id: e.id, attrs: { ...e.attrs }, text: text(e), html: ser(e), chain });
        });
        results.push(hits);
      }
      else if (op.op === "day") { routes.day = op.day === undefined ? undefined : op.day; results.push(null); }
      else if (op.op === "settle") { await settle(); results.push(snapshot()); }
      else if (op.op === "advance_settle") { advance(op.ms); await settle(); results.push(snapshot()); }
      else if (op.op === "keysel") {
        const el = first(op.sel);
        if (el) { const ev = mkEvent("keydown", el, { key: op.key, code: op.key }); dispatch(ev); if (!ev.defaultPrevented && (op.key === "Enter" || op.key === " ") && el.tag === "button" && el.attrs["aria-disabled"] !== "true") dispatch(mkEvent("click", el, {})); }
        await settle(); results.push(snapshot());
      }
      else if (op.op === "clicksel") { const el = first(op.sel); if (el) dispatch(mkEvent("click", el, {})); await settle(); results.push(snapshot()); }
      else if (op.op === "clicktext") {
        let hit = null; walk(BODY, (e) => { if (!hit && (e.tag === "button" || e.attrs.role === "button") && norm(e.textContent) === op.text && !hiddenIn(e)) hit = e; });
        if (hit) dispatch(mkEvent("click", hit, {})); await settle(); results.push(snapshot());
      }
      else if (op.op === "focussel") { const el = first(op.sel); if (el) el.focus(); flush(); results.push(snapshot()); }
      else if (op.op === "query") { results.push(queryAll(ROOT, op.sel, false).map((e) => ({ tag: e.tag, attrs: { ...e.attrs }, css: computed(e), text: norm(e.textContent) }))); }
      else if (op.op === "fetches") { results.push(LOG.fetches.splice(0)); }
      else if (op.op === "hash") { results.push(g.location.hash); }
      else if (op.op === "active") { results.push(ACTIVE ? { tag: ACTIVE.tag, attrs: { ...ACTIVE.attrs } } : null); }
      else if (op.op === "eval") { results.push(JSON.parse(vm.runInContext("JSON.stringify((() => { " + op.code + " })() ?? null)", ctx))); }
      else results.push({ error: "unknown op " + op.op });
    } catch (e) { LOG.errors.push(`op ${op.op}: ${(e && e.stack) || e}`); results.push(null); }
  }
  process.stdout.write(JSON.stringify({ results, errors: [...bootErrors, ...LOG.errors] }));
}
run();
'''


def run(ops, width=1280, reduced=False, now=None, hash="", intervals=False):
    """runs the page's script in node on the fake DOM through ops; see the module docstring.
    now: epoch ms the page's clock starts at (Date is fixed there, the fake timers move it); hash: the address's #fragment at load;
    intervals: setInterval runs on advance (off by default: the belt tests never needed the polls)"""
    node = shutil.which("node")
    if not node:
        raise AssertionError("node is not installed: the belt tests run the page's own script in node")
    with tempfile.TemporaryDirectory() as d:
        script, cfg = os.path.join(d, "harness.js"), os.path.join(d, "cfg.json")
        with open(script, "w", encoding="utf-8") as f:
            f.write(HARNESS)
        with open(cfg, "w", encoding="utf-8") as f:
            json.dump({"html": HTML, "lang": EN, "width": width, "reduced": reduced, "ops": ops, "now": now, "hash": hash, "intervals": intervals}, f)
        p = subprocess.run([node, script, cfg], capture_output=True, timeout=120, cwd=d)
    out = p.stdout.decode("utf-8", "replace")
    if p.returncode != 0 or not out:
        raise AssertionError("node failed (%s): %s" % (p.returncode, p.stderr.decode("utf-8", "replace")[-1500:]))
    return json.loads(out)


# ---------------------------------------------------------------- reading a snapshot

def kids(node):
    return [k for k in node.get("kids", []) if isinstance(k, dict)]


def text(node):
    if isinstance(node, str):
        return node
    return "".join(text(k) for k in node.get("kids", []))


def squash(s):
    return re.sub(r"\s+", " ", s).strip()


def walk(node, up=()):
    """(node, ancestors from the root down) for every element under node, node first"""
    yield node, up
    for k in kids(node):
        yield from walk(k, up + (node,))


def attr(node, name, default=None):
    return node["attrs"].get(name, default)


def tokens(snap):
    """the belt's real tokens: buttons with a data-key (the ghost ones are aria-hidden)"""
    return [n for n, _ in walk(snap["cells"]) if n["tag"] == "button" and "data-key" in n["attrs"] and attr(n, "aria-hidden") != "true"]


def token(snap, key):
    return next((n for n in tokens(snap) if attr(n, "data-key") == key), None)


def by_id(snap, ident):
    return next((n for n, _ in walk(snap["cells"]) if attr(n, "id") == ident), None)


def label_of(snap, seg):
    """a segment's name and meta: the elements its aria-labelledby names (else its aria-label), as text, in that order"""
    ids = (attr(seg, "aria-labelledby") or "").split()
    if ids:
        return [squash(text(by_id(snap, i)) if by_id(snap, i) else "") for i in ids]
    return [squash(attr(seg, "aria-label", ""))]


def segments(snap):
    """the belt's segments: every role=list under the group, in order, as (label parts, node)"""
    return [(label_of(snap, n), n) for n, _ in walk(snap["cells"]) if attr(n, "role") == "list"]


def group(snap):
    """the element with role=group: #cells itself or inside it"""
    return next((n for n, _ in walk(snap["cells"]) if attr(n, "role") == "group"), None)


def segment_of(snap, key):
    """the segment (label parts) that holds the token with this data-key"""
    for parts, seg in segments(snap):
        if any(attr(n, "data-key") == key for n, _ in walk(seg) if n["tag"] == "button"):
            return parts
    return None


# ---------------------------------------------------------------- what the page's CSS makes of a node

def look(node):
    """the declared look of a token and everything inside it, by property group: background, border, color, bar"""
    groups = {"background": ("background", "background-color", "background-image"),
              "border": ("border", "border-color", "border-style", "border-width", "outline"),
              "color": ("color",)}
    out = {g: [] for g in groups}
    for n, _ in walk(node):
        for g, props in groups.items():
            out[g] += [n["css"][p] for p in props if p in n["css"]]
    return {g: " ".join(v) for g, v in out.items()}


def css_of(node, *props):
    return " ".join(node["css"][p] for p in props if p in node["css"])
