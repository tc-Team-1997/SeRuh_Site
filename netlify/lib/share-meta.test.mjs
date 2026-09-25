// ─────────────────────────────────────────────────────────────
// Tests for the share-preview logic — run with:
//   node netlify/lib/share-meta.test.mjs
//
// The edge function itself only runs on a deploy, so this covers the
// part worth checking offline: which paths are recognised, what a
// preview says, that a failed upstream read still produces a sane
// card, and that injection cannot corrupt the page.
// ─────────────────────────────────────────────────────────────

import { parseTarget, flatten, buildMeta, injectMeta, describe as describeTarget } from './share-meta.mjs'

let pass = 0, fail = 0
const ok = (cond, label, extra = '') => {
  if (cond) { pass++; console.log('  PASS  ' + label) }
  else { fail++; console.log('  FAIL  ' + label + (extra ? '  → ' + extra : '')) }
}

const HTML = `<!doctype html><html><head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>SeRuh — Where Feelings Find Words</title>
<meta name="description" content="SeRuh — Where Feelings Find Words. For the thoughts we feel…" />
<link rel="stylesheet" href="x.css">
</head><body><div id="root"></div></body></html>`

console.log('\n═══ 1. path recognition ═══')
for (const [p, kind] of [
  ['/', 'home'], ['/daily', 'daily'],
  ['/q/65f42c6e-193b-415c-bda8-e75823fba02c', 'quote'],
  ['/f/069c0154-beb4-4db2-8643-d79c45652f75', 'feeling'],
  ['/mood/lonely', 'mood'], ['/c/unsaid-things', 'category'],
  ['/q/', 'none'], ['/admin', 'none'], ['/nonsense', 'none'],
  ['/q/../../etc/passwd', 'none'], ['/mood/<script>', 'none'],
]) ok(parseTarget(p).kind === kind, `${p} → ${kind}`, parseTarget(p).kind)
ok(parseTarget('/q/abc/').kind === 'quote', 'trailing slash tolerated')

console.log('\n═══ 2. a quote previews as the quote ═══')
const quote = { quote: 'Loving you was never loud.\nIt was the quietest thing I ever did\nwith my whole heart.', category: 'Love' }
const m = buildMeta({ target: parseTarget('/q/abc'), item: quote, url: 'https://seruh.netlify.app/q/abc' })
ok(m.description === 'Loving you was never loud. It was the quietest thing I ever did with my whole heart.',
  'newlines flattened into one line', m.description)
ok(m.tags.includes('og:title') && m.tags.includes('og:description'), 'og title + description present')
ok(m.tags.includes('<link rel="canonical" href="https://seruh.netlify.app/q/abc">'), 'canonical points at the item')
ok(m.tags.includes('content="article"'), 'og:type article for an item')
ok(m.tags.includes('article:section" content="Love"'), 'category carried as section')

console.log('\n═══ 3. injection replaces title and description, keeps the page ═══')
const out = injectMeta(HTML, m)
ok(out.includes('<title>Loving you was never loud. It was the quietest thing I ever… — SeRuh</title>'),
  'build title replaced by the quote, cut on a word boundary')
ok(m.title.length <= 70, 'title stays inside what a preview card shows', String(m.title.length))
ok(!out.includes('content="SeRuh — Where Feelings Find Words. For the thoughts'), 'generic description replaced')
ok((out.match(/<title>/g) || []).length === 1, 'exactly one <title>')
ok((out.match(/name="description"/g) || []).length === 1, 'exactly one description')
ok(out.includes('<div id="root"></div>') && out.includes('<meta charset="UTF-8"'), 'body and charset untouched')
ok(out.indexOf('og:title') < out.indexOf('</head>'), 'tags land inside <head>')

console.log('\n═══ 4. a failed upstream read still yields a sane card ═══')
const fallback = buildMeta({ target: parseTarget('/q/abc'), item: null, url: 'https://seruh.netlify.app/q/abc' })
ok(fallback.title === 'SeRuh — Where Feelings Find Words', 'falls back to the brand title', fallback.title)
ok(fallback.tags.includes('og:description'), 'still emits a complete card')
ok(injectMeta(HTML, fallback).includes('<div id="root"></div>'), 'page still intact')

console.log('\n═══ 5. mood and category pages describe themselves without a fetch ═══')
const mood = buildMeta({ target: parseTarget('/mood/lonely'), item: null, url: 'https://seruh.netlify.app/mood/lonely' })
ok(mood.title === 'Feeling Lonely — SeRuh', 'mood title', mood.title)
const cat = buildMeta({ target: parseTarget('/c/unsaid-things'), item: null, url: 'https://seruh.netlify.app/c/unsaid-things' })
ok(cat.title === 'Unsaid Things — SeRuh', 'category title from slug', cat.title)
ok(cat.tags.includes('content="website"'), 'og:type website for a listing')

console.log('\n═══ 6. escaping — content cannot break out of an attribute ═══')
const nasty = { content: 'she said "goodbye" & <script>alert(1)</script> \'quietly\'', category: 'Healing' }
const n = buildMeta({ target: parseTarget('/f/abc'), item: nasty, url: 'https://seruh.netlify.app/f/abc' })
ok(!n.tags.includes('<script>'), 'no raw script tag in the meta block')
ok(n.tags.includes('&lt;script&gt;') && n.tags.includes('&quot;') && n.tags.includes('&amp;'), 'entities escaped')
const injected = injectMeta(HTML, n)
ok((injected.match(/<script>/g) || []).length === 0, 'nothing script-shaped reaches the page')
ok(injected.includes('<div id="root"></div>'), 'page still intact after hostile content')

console.log('\n═══ 7. truncation is kind to words ═══')
const long = 'a'.repeat(30) + ' ' + 'word '.repeat(60)
ok(flatten(long, 200).length <= 201, 'respects the cap', String(flatten(long, 200).length))
ok(flatten(long, 200).endsWith('…'), 'marks the cut')
ok(!flatten('short line', 200).endsWith('…'), 'no ellipsis when it fits')
ok(flatten('  spaced   out \n\n line  ') === 'spaced out line', 'whitespace collapsed')

console.log('\n═══ 8. malformed input is survivable ═══')
let threw = false
try {
  parseTarget(undefined); parseTarget(null); flatten(null); flatten(undefined)
  buildMeta({ target: { kind: 'none' }, item: null, url: 'https://x/' })
  describeTarget({ kind: 'quote' }, {})
  injectMeta(null, m); injectMeta('no head here', m); injectMeta('<head>unclosed', m)
} catch (e) { threw = true; console.log('    threw:', e.message) }
ok(!threw, 'null / undefined / malformed HTML never throw')
ok(injectMeta('no head here', m) === 'no head here', 'HTML without a head is returned untouched')

console.log(`\n───────────────────────────────\n  ${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)
