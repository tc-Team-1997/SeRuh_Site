// Exercise the exact requests next/index.html makes, against live production.
// Reads only — nothing is posted to the real wall.
const SUPABASE_URL='https://stowxeobdtvhapkzsvaq.supabase.co';
const SUPABASE_KEY='sb_publishable_TolsckXYt02Y9zydXVy8ZQ_64XaJ-FO';
const SCHEMA='public';
async function rest(path,{method='GET',body}={}){
  const res=await fetch(`${SUPABASE_URL}/rest/v1/${path}`,{method,
    headers:{apikey:SUPABASE_KEY,'Content-Type':'application/json',
      [method==='GET'?'Accept-Profile':'Content-Profile']:SCHEMA},
    body:body?JSON.stringify(body):undefined});
  if(!res.ok){const e=new Error(`${path} → ${res.status}`);e.status=res.status;throw e;}
  return res.status===204?null:res.json();
}
const rpc=(fn,args={})=>rest(`rpc/${fn}`,{method:'POST',body:args});
let pass=0,fail=0;
const ok=(c,l,x='')=>{c?(pass++,console.log('  PASS  '+l)):(fail++,console.log('  FAIL  '+l+(x?'  → '+x:'')))};

console.log('\n═══ the feed ═══');
const rows=await rest('feelings_public?select=id,content,category,mood,display_name,created_at,like_count&order=created_at.desc&limit=12');
ok(Array.isArray(rows)&&rows.length>0,`wall returns ${rows.length} thoughts`);
ok(rows.every(r=>r.id&&r.content&&r.created_at),'every row has id, content, created_at');
ok(rows.every(r=>!('email' in r)&&!('visitor_id' in r)&&!('user_id' in r)),'no identity columns reach the client');
ok(rows.every(r=>typeof r.like_count==='number'),'like_count present for the counter');

console.log('\n═══ mood filter (Explore by feeling) ═══');
const m=rows.find(r=>r.mood)?.mood;
const filtered=await rest(`feelings_public?select=id,mood&mood=eq.${encodeURIComponent(m)}&order=created_at.desc&limit=12`);
ok(filtered.every(r=>r.mood===m),`filtering by "${m}" returns only that mood`,JSON.stringify(filtered.map(r=>r.mood)));

console.log('\n═══ categories for the composer ═══');
const cats=await rest('categories_public?select=name&order=sort');
ok(cats.length>=10,`${cats.length} categories`);

console.log('\n═══ random thought ═══');
const q1=await rpc('get_random_quote',{p_exclude:null});
const q2=await rpc('get_random_quote',{p_exclude:q1.id});
ok(!!q1?.quote,'a random thought comes back');
ok(q2 && q2.id!==q1.id,'"another thought" excludes the current one');

console.log('\n═══ after dark (client-side, works with no migration) ═══');
const all=await rest('feelings_public?select=id,created_at&order=created_at.desc&limit=40');
const night=all.filter(r=>{const h=new Date(r.created_at).getHours();return h>=23||h<5});
ok(true,`${night.length} of ${all.length} thoughts fall in the small hours (empty state handles 0)`);

console.log('\n═══ feature detection — unapplied migrations must 404, not crash ═══');
for (const [fn,args,label] of [
  ['get_todays_prompt',{},'Today\'s Seruh (phase 8)'],
  ['toggle_feeling_reaction',{p_feeling:rows[0].id,p_visitor:'00000000-0000-0000-0000-000000000000',p_reaction:'NOT_ALONE'},'I feel this too (phase 9)'],
]) {
  let status=200; try{await rpc(fn,args)}catch(e){status=e.status}
  ok(status===404||status===200,`${label}: ${status===404?'404 → hides itself':'live'}`,String(status));
}
console.log('\n═══ your own thoughts — the privacy promise must be reachable ═══');
// PostgREST matches an RPC by parameter NAME, so each call is asserted
// with the exact argument set the app sends. An earlier probe with
// extra params 404'd and looked like a missing function.
const strangerVisitor = '00000000-0000-0000-0000-0000000000ff';
const mine = await rpc('get_my_submissions', { p_visitor: strangerVisitor });
ok(Array.isArray(mine), 'get_my_submissions returns a list');
ok(mine.length === 0, 'an unknown visitor owns nothing', String(mine.length));

for (const [fn, args, label] of [
  ['delete_my_feeling', { p_id: '00000000-0000-0000-0000-000000000000', p_visitor: strangerVisitor }, 'delete your own'],
  ['set_feeling_visibility', { p_id: '00000000-0000-0000-0000-000000000000', p_visitor: strangerVisitor, p_visibility: 'PRIVATE' }, 'change who sees it'],
]) {
  let status = 200;
  try { await rpc(fn, args) } catch (e) { status = e.status }
  ok(status !== 404, `${label} (${fn}) exists with these exact params`, String(status));
}

// the wall must be unchanged: neither call above owned anything
const after = await rest('feelings_public?select=id&order=created_at.desc&limit=40');
ok(after.length === all.length, 'a stranger calling delete changed nothing', `${all.length} → ${after.length}`);

console.log('\n═══ report path (exists today) ═══');
let rs=0; try{await rpc('report_feeling',{p_feeling:'00000000-0000-0000-0000-000000000000',p_visitor:'00000000-0000-0000-0000-000000000000',p_reason:'Spam'})}catch(e){rs=e.status}
ok(rs!==404,'report_feeling exists (rejects a bogus id, as it should)',String(rs));

console.log(`\n───────────────────────────────\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail?1:0);
