// ─────────────────────────────────────────────────────────────
// Integration tests for the share-preview edge function itself —
//   node netlify/lib/share-preview.integration.test.mjs
//
// share-meta.test.mjs covers the pure helpers. This covers the
// handler: the part that only ever runs on a deploy, in front of
// every HTML response, where a mistake is an outage rather than a
// missing tag.
//
// Netlify Edge Functions run on Deno. Node supplies everything the
// handler uses (fetch, Request/Response, AbortSignal.timeout) except
// Deno.env, which is shimmed below. The handler file is imported
// unmodified, so what is exercised here is what ships.
//
// Network: the happy path reads one real row from the public API to
// prove the whole chain works. Everything else is offline.
// ─────────────────────────────────────────────────────────────

import { readFileSync } from 'node:fs'

let pass = 0, fail = 0
const ok = (cond, label, extra = '') => {
  if (cond) { pass++; console.log('  PASS  ' + label) }
  else { fail++; console.log('  FAIL  ' + label + (extra ? '  → ' + extra : '')) }
}

// ── Deno shim, set before the handler is imported ──
const env = new Map()
globalThis.Deno = { env: { get: (k) => env.get(k) } }

const html = readFileSync('index.html', 'utf8')
const SUPABASE_URL = html.match(/https:\/\/[a-z0-9]+\.supabase\.co/)?.[0]
const ANON_KEY = html.match(/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)?.[0]

const handler = (await import('../edge-functions/share-preview.js')).default

const htmlResponse = (body = html) =>
  new Response(body, { status: 200, headers: { 'content-type': 'text/html; charset=UTF-8' } })

// context.next() is what Netlify gives the handler to reach the origin
const ctx = (response) => ({ next: async () => response })

const run = (path, { response = htmlResponse(), origin = 'https://seruh.netlify.app' } = {}) =>
  handler(new Request(origin + path), ctx(response))

console.log('\n═══ 1. happy path — a real wall post, through the whole chain ═══')
env.set('SUPABASE_URL', SUPABASE_URL)
env.set('SUPABASE_ANON_KEY', ANON_KEY)

let realId = null, realText = null
try {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/feelings_public?select=id,content&order=created_at.desc&limit=1`,
    { headers: { apikey: ANON_KEY } })
  const rows = await r.json()
  realId = rows[0]?.id; realText = rows[0]?.content
} catch { /* offline — section skipped below */ }

if (realId) {
  const res = await run(`/f/${realId}`)
  const out = await res.text()
  ok(res.status === 200, 'status preserved')
  const firstWords = realText.replace(/\s+/g, ' ').trim().slice(0, 20)
  ok(out.includes('og:title'), 'og tags injected')
  ok(out.includes(firstWords.slice(0, 12)), 'the post\'s own words are in the card', firstWords)
  ok(!out.includes('<title>SeRuh — Where Feelings Find Words</title>'), 'generic title replaced')
  ok(out.includes('<div id="root"></div>'), 'app markup intact')
  ok((out.match(/<title>/g) || []).length === 1, 'exactly one <title>')
  ok(!res.headers.get('content-length'), 'stale content-length dropped')
  ok(res.headers.get('content-type').includes('text/html'), 'content-type preserved')
} else {
  console.log('  SKIP  no network — happy path not exercised')
}

console.log('\n═══ 2. homepage — tags injected with no upstream call ═══')
let fetched = false
const realFetch = globalThis.fetch
globalThis.fetch = (...a) => { fetched = true; return realFetch(...a) }
const home = await (await run('/')).text()
globalThis.fetch = realFetch
ok(!fetched, 'no upstream request for /')
ok(home.includes('og:site_name') && home.includes('canonical'), 'homepage still gets a card')
ok(home.includes('<div id="root"></div>'), 'app markup intact')

console.log('\n═══ 3. degradation — missing config must not break anything ═══')
env.delete('SUPABASE_URL'); env.delete('SUPABASE_ANON_KEY')
const noEnv = await run('/q/some-id')
const noEnvBody = await noEnv.text()
ok(noEnv.status === 200, 'still 200 without config')
ok(noEnvBody.includes('og:title'), 'still emits a complete card')
ok(noEnvBody.includes('<div id="root"></div>'), 'app markup intact')
env.set('SUPABASE_URL', SUPABASE_URL); env.set('SUPABASE_ANON_KEY', ANON_KEY)

console.log('\n═══ 4. upstream failure and timeout degrade, never propagate ═══')
for (const [label, impl] of [
  ['throws', () => { throw new Error('network down') }],
  ['non-200', async () => new Response('nope', { status: 500 })],
  ['bad JSON', async () => new Response('<<not json>>', { status: 200, headers: { 'content-type': 'application/json' } })],
  // a real fetch aborts on the signal; this stub honours it so the
  // handler's own timeout wiring is what gets tested
  ['aborts on signal', (_u, o) => new Promise((_, rej) => {
    o?.signal?.addEventListener('abort', () => rej(new Error('aborted')))
  })],
  // and this one ignores the signal entirely, which is what the
  // belt-and-braces deadline in the handler exists for
  ['ignores the signal', () => new Promise(() => {})],
]) {
  const saved = globalThis.fetch
  globalThis.fetch = impl
  const started = Date.now()
  let body = '', status = 0
  try {
    const r = await run('/q/some-id')
    status = r.status; body = await r.text()
  } finally { globalThis.fetch = saved }
  const took = Date.now() - started
  ok(status === 200 && body.includes('<div id="root"></div>'),
    `upstream ${label} → page still served`, `status=${status}`)
  if (label === 'aborts on signal' || label === 'ignores the signal') {
    ok(took < 4000, `${label}: bounded, not hung`, `${took}ms`)
  }
}

console.log('\n═══ 5. pass-through cases ═══')
const json = await run('/q/x', { response: new Response('{"a":1}', { status: 200, headers: { 'content-type': 'application/json' } }) })
ok(await json.text() === '{"a":1}', 'non-HTML response passed through untouched')
const notFound = await run('/q/x', { response: new Response('missing', { status: 404, headers: { 'content-type': 'text/html' } }) })
ok(notFound.status === 404, '404 status preserved')
const unknown = await (await run('/totally-unknown')).text()
ok(!unknown.includes('og:title'), 'unmatched path left alone')

console.log('\n═══ 6. hostile input reaches nothing ═══')
for (const p of ['/q/../../etc/passwd', '/q/%3Cscript%3E', '/f/' + 'a'.repeat(500), '/mood/<img src=x>']) {
  const r = await run(p)
  const b = await r.text()
  ok(r.status === 200 && !b.includes('<script>alert') && b.includes('<div id="root"></div>'),
    `handled: ${p.slice(0, 34)}`)
}

console.log('\n═══ 7. a PRIVATE feeling cannot be previewed ═══')
// the handler reads feelings_public, which excludes PRIVATE and
// anything not PUBLISHED — assert the URL it actually builds
let requested = null
const saved = globalThis.fetch
globalThis.fetch = (u, o) => { requested = String(u); return saved(u, o) }
await run('/f/00000000-0000-0000-0000-000000000000')
globalThis.fetch = saved
ok(requested && requested.includes('feelings_public'), 'reads the public wall view', requested?.slice(0, 80))
ok(requested && !/\/rest\/v1\/feelings\?/.test(requested), 'never reads the feelings table')

console.log(`\n───────────────────────────────\n  ${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)
