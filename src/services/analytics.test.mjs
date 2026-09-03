// ─────────────────────────────────────────────────────────────
// Tests for services/analytics.js — run with:  node src/services/analytics.test.mjs
//
// No test runner and no dependencies: the repo has neither, and
// analytics is exactly the kind of code that should not be trusted
// on inspection. It stubs window/document, captures what would be
// pushed to gtag's dataLayer, and asserts on the payloads.
//
// The privacy assertions are the point. If someone adds a parameter
// that carries a person's words, section 6 fails.
// ─────────────────────────────────────────────────────────────

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))

// analytics.js reads import.meta.env (Vite). Node has no such thing,
// so load it with that rewritten to a stub we control.
//
// Each call must get its own module instance — the module holds
// initialisation and pageview-dedupe state, and section 12 needs a
// fresh one. Identical source would be served from Node's module
// cache, so a counter is appended to make each load distinct.
let loadCount = 0
async function loadAnalytics(env) {
  globalThis.__ENV = env
  const src = readFileSync(join(here, 'analytics.js'), 'utf8')
    .replace(/import\.meta\.env/g, 'globalThis.__ENV') + `\n// instance ${++loadCount}\n`
  return import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'))
}

const sent = []
const listeners = {}
globalThis.window = {
  location: { hash: '' },
  dataLayer: null,
  addEventListener: (t, f) => { (listeners[t] ||= []).push(f) },
  removeEventListener: (t, f) => { listeners[t] = (listeners[t] || []).filter(x => x !== f) },
}
globalThis.document = {
  title: 'SeRuh — Where Feelings Find Words',
  head: { appendChild() {} },
  createElement: () => ({}),
}

const A = await loadAnalytics({ VITE_GA_MEASUREMENT_ID: 'G-TEST12345', VITE_GA_DEBUG: 'true', PROD: false, DEV: false })
A.initAnalytics()
const dl = globalThis.window.dataLayer
const push = dl.push.bind(dl)
dl.push = (args) => { if (args[0] === 'event') sent.push({ name: args[1], params: args[2] }); return push(args) }

let pass = 0, fail = 0
const ok = (cond, label, extra = '') => {
  if (cond) { pass++; console.log('  PASS  ' + label) }
  else { fail++; console.log('  FAIL  ' + label + (extra ? '  → ' + extra : '')) }
}
const paths = () => sent.filter(e => e.name === 'page_view').map(e => e.params.page_path)

console.log('\n═══ 1. hash → virtual page path ═══')
for (const [hash, want] of [
  ['', '/'], ['#', '/'], ['#home', '/home'], ['#explore', '/explore'], ['#write', '/write'],
  ['#today', '/today'], ['#unsaid', '/unsaid'], ['#generate', '/generate'], ['#story', '/story'],
  ['#/admin', '/admin'], ['#/admin/moderation', '/admin/moderation'], ['#/admin/', '/admin'],
  ['#/me', '/me'], ['#/me/saved', '/me/saved'], ['#/me/submissions', '/me/submissions'],
]) ok(A.pathFromHash(hash) === want, `${hash || '(none)'} → ${want}`, A.pathFromHash(hash))

console.log('\n═══ 2. no duplicate page_view (StrictMode / re-render / same-view nav) ═══')
sent.length = 0
globalThis.window.location.hash = '#explore'
const stop1 = A.startPageViewTracking()
const stop2 = A.startPageViewTracking()   // StrictMode double-invoked effect
A.trackPageView()                          // a re-render
ok(paths().length === 1, 'three init/track calls on one view → 1 page_view', JSON.stringify(paths()))

console.log('\n═══ 3. navigation sequence Home → Explore → Write → Home ═══')
sent.length = 0
for (const h of ['#home', '#explore', '#write', '#home']) {
  globalThis.window.location.hash = h
  ;(listeners.hashchange || []).forEach(f => f())
}
ok(JSON.stringify(paths()) === JSON.stringify(['/home', '/explore', '/write', '/home']),
  'four distinct views in order', JSON.stringify(paths()))
sent.length = 0
;(listeners.hashchange || []).forEach(f => f())
ok(sent.length === 0, 'repeat hashchange on the same view → no event')
stop1(); stop2()

console.log('\n═══ 4. back / forward ═══')
sent.length = 0
globalThis.window.location.hash = '#/me/saved'
const stop3 = A.startPageViewTracking()
globalThis.window.location.hash = '#explore'
;(listeners.popstate || []).forEach(f => f())
ok(paths().join(',') === '/me/saved,/explore', 'popstate produces a pageview', JSON.stringify(paths()))
stop3()

console.log('\n═══ 5. page_group separates admin from public ═══')
sent.length = 0
A.trackPageView('/admin/moderation'); A.trackPageView('/me/saved'); A.trackPageView('/explore')
ok(sent.map(e => e.params.page_group).join(',') === 'admin,my_seruh,public',
  'admin / my_seruh / public', JSON.stringify(sent.map(e => e.params.page_group)))

console.log('\n═══ 6. PRIVACY — raw text and PII cannot leave ═══')
sent.length = 0
A.trackEvent('quote_shared', {
  quote_id: 'abc-123', category: 'Healing', mood: 'Peaceful', share_method: 'whatsapp',
  // everything below must be dropped by the allowlist:
  content: 'I still check my phone sometimes, knowing there wont be a message',
  quote: 'raw quote body', feeling_text: 'my private feeling', email: 'someone@example.com',
  name: 'A Person', phone: '+919999999999', password: 'hunter2', access_token: 'eyJhbGciOi',
  user_id: 'uuid-here', visitor_id: 'uuid-here', search_query: 'why do i feel this way',
})
ok(JSON.stringify(sent[0].params) === JSON.stringify(
  { quote_id: 'abc-123', category: 'Healing', mood: 'Peaceful', share_method: 'whatsapp' }),
  'only allowlisted params survive', JSON.stringify(sent[0].params))
ok(!/phone sometimes|someone@|hunter2|eyJhbGciOi|private feeling|why do i feel/i.test(JSON.stringify(sent)),
  'no PII or user text anywhere in the payload')

console.log('\n═══ 7. search sends a bucket, never the query ═══')
sent.length = 0
A.trackSearch({ searchType: 'quote_search', resultCount: 12, query: 'i miss my mother so much it hurts' })
ok(sent[0].params.result_count === 12 && sent[0].params.query_length === '26-60',
  'result_count + query_length bucket', JSON.stringify(sent[0].params))
ok(!JSON.stringify(sent[0]).includes('mother'), 'query text absent')

console.log('\n═══ 8. AI events carry only safe metadata ═══')
sent.length = 0
A.trackAIGenerationStarted({ mood: 'Nostalgic', style: 'Short & Deep', length: 'Short' })
A.trackAIGenerationCompleted({ mood: 'Nostalgic', style: 'Short & Deep', length: 'Short' })
A.trackAIGenerationFailed({ errorKind: 'rate_limited' })
ok(sent.map(e => e.name).join(',') === 'ai_generation_started,ai_generation_completed,ai_generation_failed',
  'three AI events')
ok(sent[0].params.mood === 'Nostalgic' && !('feeling' in sent[0].params), 'mood / style / length only')

console.log('\n═══ 9. feelings — metadata only, private stays private ═══')
sent.length = 0
A.trackFeelingStarted()
A.trackFeelingSubmitted({ visibility: 'PRIVATE', category: 'Healing', mood: 'Numb' })
A.trackFeelingPublished({ visibility: 'PRIVATE', category: 'Healing', mood: 'Numb', decision: 'ALLOW' })
ok(sent.map(e => e.name).join(',') === 'feeling_started,feeling_submitted,feeling_published',
  'ordered feeling events')
ok(sent[1].params.visibility === 'PRIVATE' && Object.keys(sent[1].params).length === 3,
  'visibility / category / mood only', JSON.stringify(sent[1].params))

console.log('\n═══ 10. admin traffic marked internal ═══')
sent.length = 0
A.setInternalTraffic(true)
A.trackEvent('quote_liked', { quote_id: 'x' })
ok(sent[0].params.traffic_type === 'internal', 'traffic_type=internal on admin sessions')
A.setInternalTraffic(false)
sent.length = 0
A.trackEvent('quote_liked', { quote_id: 'x' })
ok(!('traffic_type' in sent[0].params), 'public sessions unmarked')

console.log('\n═══ 11. event-name hygiene, and never throws ═══')
sent.length = 0
A.trackEvent('Bad Name!'); A.trackEvent(''); A.trackEvent(null); A.trackEvent('x')
ok(sent.length === 0, 'malformed event names dropped', JSON.stringify(sent))
let threw = false
try {
  A.trackEvent('quote_liked', null); A.trackPageView(undefined); A.trackQuoteShared(undefined)
  A.trackMoodSelected(undefined); A.trackSearch(); A.trackDailySeRuhViewed(null)
} catch { threw = true }
ok(!threw, 'undefined / null arguments never throw')

console.log('\n═══ 12. an unconfigured build sends nothing ═══')
sent.length = 0
const B = await loadAnalytics({ VITE_GA_MEASUREMENT_ID: '', VITE_GA_DEBUG: 'false', PROD: true, DEV: false })
B.initAnalytics(); B.trackEvent('quote_liked', { quote_id: 'x' }); B.trackPageView('/x')
ok(B.isAnalyticsEnabled === false, 'isAnalyticsEnabled false without a measurement id')
ok(sent.length === 0, 'no events emitted when unconfigured', JSON.stringify(sent))

console.log(`\n───────────────────────────────\n  ${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)
