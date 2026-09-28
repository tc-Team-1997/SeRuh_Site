// ─────────────────────────────────────────────────────────────
// Tests for the live-site comments widget — run with:
//   node next/seruh-comments.test.mjs
//
// The widget attaches itself to an app whose source does not exist,
// so the only contract it has is the shape of the DOM that app
// renders. These tests rebuild that shape from the real markup in
// index.html and check where the 💬 button actually lands.
//
// The bug this exists to prevent: the app's action row ends with a
// "More options" button carrying ml-auto, which consumes all free
// space. Appending after it put the button outside the card.
// ─────────────────────────────────────────────────────────────

import { readFileSync } from 'node:fs'

let pass = 0, fail = 0
const ok = (cond, label, extra = '') => {
  if (cond) { pass++; console.log('  PASS  ' + label) }
  else { fail++; console.log('  FAIL  ' + label + (extra ? '  → ' + extra : '')) }
}

/* ── a DOM small enough to read, large enough to run the widget ── */
class N {
  constructor(tag) { this.tagName = String(tag).toUpperCase(); this.attrs = {}; this.children = []; this.parentElement = null; this._text = null }
  setAttribute(k, v) { this.attrs[k] = String(v) }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null }
  hasAttribute(k) { return k in this.attrs }
  removeAttribute(k) { delete this.attrs[k] }
  appendChild(c) { c.parentElement = this; this.children.push(c); return c }
  insertBefore(c, ref) {
    const i = this.children.indexOf(ref)
    if (i === -1) return this.appendChild(c)
    c.parentElement = this; this.children.splice(i, 0, c); return c
  }
  removeChild(c) { const i = this.children.indexOf(c); if (i > -1) this.children.splice(i, 1); c.parentElement = null }
  addEventListener() {}
  get style() { return (this._style ||= {}) }
  set textContent(v) { this._text = String(v); this.children = [] }
  get textContent() {
    if (this._text !== null) return this._text
    return this.children.map(c => c.textContent).join('')
  }
  querySelectorAll(sel) { const out = []; walk(this, n => { if (matches(n, sel)) out.push(n) }); return out }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null }
}
class T { constructor(t) { this._t = String(t); this.parentElement = null; this.children = [] } get textContent() { return this._t } }

const walk = (n, fn) => { for (const c of n.children) { if (c instanceof N) { fn(c); walk(c, fn) } } }

/* tag[attr="value"].class — the only selector shapes the widget uses */
function matches(n, sel) {
  return String(sel).split(',').some(part => {
    const p = part.trim()
    const m = p.match(/^([a-z0-9]+)?((?:\[[^\]]+\])*)((?:\.[A-Za-z0-9_-]+)*)$/i)
    if (!m) throw new Error('selector not supported by this shim: ' + p)
    const [, tag, attrs, classes] = m
    if (tag && n.tagName !== tag.toUpperCase()) return false
    for (const a of attrs.match(/\[[^\]]+\]/g) || []) {
      const am = a.match(/^\[([^=\]]+)(?:=["']?([^"'\]]*)["']?)?\]$/)
      if (!am) throw new Error('attr selector not supported: ' + a)
      const v = n.getAttribute(am[1])
      if (v === null) return false
      if (am[2] !== undefined && v !== am[2]) return false
    }
    for (const c of classes.match(/\.[A-Za-z0-9_-]+/g) || []) {
      const cls = (n.getAttribute('class') || '').split(/\s+/)
      if (!cls.includes(c.slice(1))) return false
    }
    return true
  })
}

/* ── the app's card, rebuilt from the markup in index.html ──
   feeling row: Like · Copy · Share · [ml-auto] More options
   quote   row: Like · Save · Copy · Share · [ml-auto] More options */
function card(kind, text) {
  const article = new N('div'); article.setAttribute('class', 'rounded-2xl bg-card border border-linec p-6 sm:p-7')
  const bq = new N('blockquote'); bq.setAttribute('class', 'font-display')
  if (kind === 'feeling') {           // the app wraps a feeling in curly quotes
    bq.appendChild(new T('“')); bq.appendChild(new T(text)); bq.appendChild(new T('”'))
  } else {
    bq.appendChild(new T(text))       // a quote is rendered bare
  }
  article.appendChild(bq)

  const row = new N('div')
  row.setAttribute('class', 'mt-4 pt-3.5 border-t border-linec/70 flex items-center gap-0.5')
  const btn = (label, cls) => { const b = new N('button'); b.setAttribute('aria-label', label); b.setAttribute('class', cls); row.appendChild(b); return b }
  const pill = 'flex items-center gap-1.5 rounded-full px-3 py-1.5 text-[0.8rem]'
  if (kind === 'feeling') {
    btn('Like this feeling', pill); btn('Copy this feeling', pill); btn('Share this feeling', pill)
    btn('More options — report this feeling', 'ml-auto p-1.5 rounded-full text-faint')
  } else {
    btn('Like this quote (3 likes)', pill); btn('Save for later', pill)
    btn('Copy this quote', pill); btn('Share this quote', pill)
    btn('More options — report this quote', 'ml-auto p-1.5 rounded-full text-faint')
  }
  article.appendChild(row)
  return { article, row }
}

/* ── run the widget against that DOM ── */
const QUOTE_TEXT = 'Loving you was never loud.'
const FEELING_TEXT = 'Some days I just hold it together with tape.'
const QUOTE_ID = '65f42c6e-193b-415c-bda8-e75823fba02c'
const FEELING_ID = '069c0154-beb4-4db2-8643-d79c45652f75'

function load({ noSpacer = false, decoy = false } = {}) {
  const document = new N('#document')
  document.head = document.appendChild(new N('head'))
  document.body = document.appendChild(new N('body'))
  document.readyState = 'complete'
  document.createElement = t => new N(t)
  document.createElementNS = (_ns, t) => new N(t)
  document.createTextNode = t => new T(t)
  document.addEventListener = () => {}

  const q = card('quote', QUOTE_TEXT), f = card('feeling', FEELING_TEXT)
  if (noSpacer) f.row.children.pop()          // a row with no ml-auto at all
  if (decoy) {                                // an ml-auto nested inside a button
    const inner = new N('span'); inner.setAttribute('class', 'ml-auto')
    f.row.querySelector('button[aria-label="Share this feeling"]').appendChild(inner)
  }
  document.body.appendChild(q.article); document.body.appendChild(f.article)

  const calls = []
  const fetchStub = (url) => {
    calls.push(url)
    const json = url.includes('quotes_public') ? [{ id: QUOTE_ID, quote: QUOTE_TEXT }]
      : url.includes('feelings_public') ? [{ id: FEELING_ID, content: FEELING_TEXT }]
      : 3                                      // count_* RPCs
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(json) })
  }
  const store = new Map()
  const src = readFileSync(new URL('./seruh-comments.js', import.meta.url), 'utf8')
  new Function('document', 'localStorage', 'crypto', 'fetch', 'MutationObserver', 'window', src)(
    document, { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) },
    { randomUUID: () => '11111111-2222-4333-8444-555555555555' },
    fetchStub, class { observe() {} disconnect() {} }, {})
  return { document, quote: q, feeling: f, calls }
}

const settle = () => new Promise(r => setTimeout(r, 0))
const commentBtn = row => row.children.find(c => (c.getAttribute?.('class') || '').includes('sqc-btn'))
const idxOf = (row, n) => row.children.indexOf(n)

console.log('\n═══ 1. the button lands inside the card, ahead of the ml-auto spacer ═══')
{
  const { feeling, quote } = load(); await settle()
  for (const [name, c] of [['feeling', feeling], ['quote', quote]]) {
    const b = commentBtn(c.row)
    const spacer = c.row.querySelector('.ml-auto')
    ok(!!b, `${name}: a 💬 button was added`)
    ok(!!spacer, `${name}: the app's ml-auto button is still there`)
    ok(b && spacer && idxOf(c.row, b) < idxOf(c.row, spacer),
      `${name}: 💬 sits BEFORE ml-auto`, b && spacer ? `💬@${idxOf(c.row, b)} ml-auto@${idxOf(c.row, spacer)}` : '')
    ok(spacer && idxOf(c.row, spacer) === c.row.children.length - 1,
      `${name}: nothing is left after ml-auto — the overflow regression`)
    const share = c.row.querySelector(`button[aria-label="Share this ${name}"]`)
    ok(share && b && idxOf(c.row, b) === idxOf(c.row, share) + 1, `${name}: order reads Copy · Share · 💬 · ···`)
  }
}

console.log('\n═══ 2. the count is fetched and shown ═══')
{
  const { feeling } = load(); await settle()
  ok(commentBtn(feeling.row)?.textContent.includes('3'), 'the comment count is rendered',
    JSON.stringify(commentBtn(feeling.row)?.textContent))
}

console.log('\n═══ 3. curly quotes do not stop a wall post from matching ═══')
{
  const { feeling, quote } = load(); await settle()
  ok(feeling.row.querySelector('blockquote') === null, 'the blockquote is a sibling of the row, not inside it')
  ok(!!commentBtn(feeling.row), 'a feeling wrapped in “ ” still resolved to an id')
  ok(!!commentBtn(quote.row), 'a bare quote still resolved to an id')
}

console.log('\n═══ 4. a row with no ml-auto still gets the button ═══')
{
  const { feeling } = load({ noSpacer: true }); await settle()
  const b = commentBtn(feeling.row)
  ok(!!b, 'fallback: appended when there is no spacer to sit ahead of')
  ok(b && idxOf(feeling.row, b) === feeling.row.children.length - 1, 'fallback: it goes last')
}

console.log('\n═══ 5. an ml-auto nested inside a button is not mistaken for the spacer ═══')
{
  const { feeling } = load({ decoy: true }); await settle()
  const b = commentBtn(feeling.row)
  const real = feeling.row.children.find(c => (c.getAttribute?.('class') || '').split(/\s+/).includes('ml-auto'))
  ok(!!b, 'decoy: the button was still added')
  ok(real && b && idxOf(feeling.row, b) < idxOf(feeling.row, real),
    'decoy: still lands before the row\'s OWN ml-auto child')
  ok(real && idxOf(feeling.row, real) === feeling.row.children.length - 1,
    'decoy: nothing after ml-auto')
}

console.log('\n═══ 6. a re-render never stacks a second button ═══')
{
  const { feeling } = load(); await settle()
  const before = feeling.row.children.length
  ok(feeling.row.hasAttribute('data-seruh-comments'), 'the row is marked as enhanced')
  ok(feeling.row.children.filter(c => (c.getAttribute?.('class') || '').includes('sqc-btn')).length === 1,
    'exactly one 💬 button', String(before))
}

console.log('\n═══ 7. it looks like a comment control, not a pasted-on emoji ═══')
{
  const { feeling } = load(); await settle()
  const b = commentBtn(feeling.row)
  ok(!!b.querySelector('svg'), 'the icon is real SVG, in the app\'s own icon family')
  ok(b.querySelector('svg')?.getAttribute('stroke') === 'currentColor', 'it inherits the button colour')
  ok(b.querySelector('svg')?.getAttribute('width') === '14', 'sized like the app\'s lucide icons')
  ok(!/[\u{1F300}-\u{1FAFF}]/u.test(b.textContent), 'no emoji left in the button', JSON.stringify(b.textContent))
  ok(b.textContent.includes('Reply'), 'it says what it is, the way Copy and Share do')
  const badge = b.children.find(c => (c.getAttribute?.('class') || '').includes('sqc-n'))
  ok(!!badge, 'the count is a badge of its own')
  ok(badge?.textContent === '3', 'the badge carries the count', JSON.stringify(badge?.textContent))
}

console.log('\n═══ 8. the stylesheet carries the rules that keep it in the card ═══')
{
  const { document } = load(); await settle()
  const css = document.head.querySelectorAll('style').map(s => s.textContent).join('')
  ok(css.includes('[data-seruh-comments]{flex-wrap:wrap'), 'the row may wrap rather than overflow')
  ok(css.includes('[data-seruh-comments]>button{white-space:nowrap'), 'button text never stacks into single words')
  ok(!css.includes('flex-shrink:0'), 'the app is left free to squeeze its own buttons')
  ok(css.includes('.sqc-n:empty{display:none}'), 'a zero count shows no badge at all')
  ok(css.includes('#9a545f') && css.includes('#b76e79') && css.includes('#f4e3e2'),
    'the chip uses the site\'s own rose, rosedeep and roseveil')
  ok(css.includes('.sqc-btn:focus-visible'), 'the chip has a visible focus ring')
  ok((css.match(/\{/g) || []).length === (css.match(/\}/g) || []).length, 'braces balance')
}

console.log('\n═══ 9. no rule may erase a size the app set on itself ═══')
{
  const { document } = load(); await settle()
  const css = document.head.querySelectorAll('style').map(s => s.textContent).join('')

  // flatten @media, then split into selector/body pairs
  const flat = css.replace(/@media[^{]+\{((?:[^{}]*\{[^{}]*\})*)\}/g, '$1')
  const rules = [...flat.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(m => ({ sel: m[1].trim(), body: m[2] }))
  ok(rules.length > 10, 'the stylesheet parsed into rules', String(rules.length))

  /* This sheet is appended after the app's, so a bare single class
     ties with Tailwind's text-[…] and wins on source order — it wipes
     the explicit size rather than adjusting it. Anything sizing the
     app's own type must name the element (blockquote.font-display)
     so the intent is deliberate and visible. */
  const offenders = rules
    .filter(r => /font-size/.test(r.body))
    .flatMap(r => r.sel.split(',').map(x => x.trim()))
    .filter(sel => !sel.startsWith('.sqc-'))
    .filter(sel => /^\.[A-Za-z0-9_\\:-]+$/.test(sel))
  ok(offenders.length === 0,
    'no bare app class sets font-size', offenders.join(' '))
  ok(!/(^|[^a-z-])\.font-display\s*\{/.test(css),
    'specifically, no blanket .font-display size — it flattened the wordmark')
  ok(css.includes('blockquote.font-display{font-size:1.04rem'),
    'the deliberate, element-named card-quote size is still there')
}

console.log(`\n───────────────────────────────\n  ${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)
