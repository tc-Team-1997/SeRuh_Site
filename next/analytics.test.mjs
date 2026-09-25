// Tests for next/analytics.js — run with:  node next/analytics.test.mjs
//
// The privacy sections are the point. Seruh's content IS the
// vulnerable part, so "no user text reaches analytics" has to be
// impossible rather than merely intended. If someone adds a
// parameter carrying what a person wrote, section 2 fails.

const sent = [];
const listeners = {};
globalThis.window = { dataLayer: null };
globalThis.document = {
  title: "Seruh — Say what you can't say out loud",
  head: { appendChild() {} },
  createElement: () => ({}),
  querySelector: () => null,
};
globalThis.location = { pathname: '/next' };

const A = await import('./analytics.js');

let pass = 0, fail = 0;
const ok = (c, l, x = '') => { c ? (pass++, console.log('  PASS  ' + l)) : (fail++, console.log('  FAIL  ' + l + (x ? '  → ' + x : ''))); };

A.initAnalytics({ id: 'G-TEST12345', debug: true });
const dl = globalThis.window.dataLayer;
const push = dl.push.bind(dl);
dl.push = (args) => { if (args[0] === 'event') sent.push({ name: args[1], params: args[2] }); return push(args); };

console.log('\n═══ 1. it only runs when configured ═══');
ok(A.isEnabled() === true, 'enabled with a measurement id');

console.log('\n═══ 2. PRIVACY — what a person wrote can never leave ═══');
sent.length = 0;
A.trackEvent('thought_submitted', {
  emotion: 'Lonely', category: 'Late Night Thoughts', length_bucket: '41-140',
  // every one of these must be dropped:
  content: 'Everyone thinks I am doing great. I am actually exhausted.',
  body: 'a private reply to a stranger', thought: 'raw text',
  email: 'someone@example.com', name: 'A Person', phone: '+919999999999',
  visitor_id: 'uuid', user_id: 'uuid', feeling_id: 'uuid', quote: 'raw',
});
ok(JSON.stringify(sent[0].params) === JSON.stringify(
  { emotion: 'Lonely', category: 'Late Night Thoughts', length_bucket: '41-140' }),
  'only allowlisted params survive', JSON.stringify(sent[0].params));
ok(!/exhausted|someone@|A Person|9999|uuid|private reply/i.test(JSON.stringify(sent)),
  'no user text, contact detail or id anywhere in the payload');

console.log('\n═══ 3. a thought is measured by length, never by content ═══');
sent.length = 0;
A.trackThoughtSubmitted({ emotion: 'Sad', category: 'Love', body: 'I still check my phone knowing there will be nothing.' });
ok(sent[0].params.length_bucket === '41-140', 'length becomes a bucket', JSON.stringify(sent[0].params));
ok(!JSON.stringify(sent[0]).includes('phone knowing'), 'the thought itself is absent');
ok(A.lengthBucket('') === '0' && A.lengthBucket('x'.repeat(500)) === '400+', 'bucket edges');

console.log('\n═══ 4. a private reply is counted, never carried ═══');
sent.length = 0;
A.trackReplySubmitted({ body: 'I do not know you, but I understand that feeling.' });
ok(sent[0].name === 'reply_submitted', 'event fires');
ok(!JSON.stringify(sent[0]).includes('understand that feeling'), 'the reply text is absent');
ok(Object.keys(sent[0].params).join() === 'length_bucket', 'only a bucket goes with it');

console.log('\n═══ 5. the product questions get answered ═══');
sent.length = 0;
A.trackShareThoughtClicked('hero'); A.trackEmotionSelected('Lonely', 'explore');
A.trackCategorySelected('Loneliness'); A.trackFeelThisToo(true);
A.trackShareClicked('copy_link'); A.trackRandomThought(); A.trackDailyViewed();
A.trackAfterDarkViewed(3); A.trackReportSubmitted('Spam');
ok(sent.map(e => e.name).join(',') ===
  'share_thought_clicked,emotion_selected,category_selected,feel_this_too,share_clicked,random_thought_clicked,daily_seruh_viewed,after_dark_viewed,report_submitted',
  'all nine engagement events', sent.map(e => e.name).join(','));
ok(sent.find(e => e.name === 'after_dark_viewed').params.result_count === 3, 'counts come through as numbers');

console.log('\n═══ 6. pageview does not double-fire ═══');
sent.length = 0;
A.trackPageView('/next'); A.trackPageView('/next'); A.trackPageView();
ok(sent.filter(e => e.name === 'page_view').length === 1, 'three calls, one page_view', String(sent.length));

console.log('\n═══ 7. it never throws, and never invents an event ═══');
sent.length = 0;
A.trackEvent('Bad Name!'); A.trackEvent(''); A.trackEvent(null); A.trackEvent('x');
ok(sent.length === 0, 'malformed event names dropped', JSON.stringify(sent));
let threw = false;
try {
  A.trackEvent('feel_this_too', null); A.trackThoughtSubmitted(); A.trackReplySubmitted();
  A.trackEmotionSelected(undefined); A.lengthBucket(null); A.sanitize(null);
} catch { threw = true; }
ok(!threw, 'null and undefined arguments never throw');

console.log(`\n───────────────────────────────\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
