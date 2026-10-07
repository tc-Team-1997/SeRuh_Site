-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 15 migration: a model the size of the task
--  Safe to run more than once.
--
--  Phase 14 moved off the retired gemini-2.0-flash and onto
--  gemini-3.8-flash. That restored a model Google still serves, but
--  it chose the wrong one, and the generator stayed dark.
--
--  gemini-3.8-flash is Google's heaviest Flash — their own words are
--  "long-horizon software engineering, autonomous agents, and complex
--  enterprise workflows" — and it defaults to thinkingLevel "medium".
--  Asked for one short poetic line, it reasoned for 17s, then 42s,
--  then past 120s, and never reached the quote. Raising the token
--  ceiling made that worse: more budget simply bought more thinking.
--
--  gemini-3.5-flash-lite defaults to thinkingLevel "minimal". That is
--  the right shape for this job. The whole task is a sentence of at
--  most sixty words; the quality that matters is phrasing, not
--  reasoning depth, and the model's own default no longer fights it.
--
--  This is the half that needs no deploy. The model is read from
--  ai_settings on every request, so this row alone brings the
--  generator back even while the function is still an older build.
--  The matching code change — thinkingLevel "low", which both models
--  accept — ships separately.
-- ═══════════════════════════════════════════════════════════════

begin;

-- ─── 1. The live setting ────────────────────────────────────────
-- Only moves a row that is still on a model this project chose and
-- found wanting; a model somebody has since picked deliberately is
-- left exactly where it is.
update public.ai_settings
   set model = 'gemini-3.5-flash-lite'
 where id = 1
   and model in ('gemini-2.0-flash', 'gemini-2.0-flash-001',
                 'gemini-2.0-flash-lite', 'gemini-2.0-flash-lite-001',
                 'gemini-3.8-flash');

-- ─── 2. The column default, for a fresh install ─────────────────
alter table public.ai_settings
  alter column model set default 'gemini-3.5-flash-lite';

-- ─── 3. Self-test ───────────────────────────────────────────────
do $$
declare
  v_model   text;
  v_default text;
begin
  select model into v_model from public.ai_settings where id = 1;
  if not found then
    raise exception 'ai_settings has no row 1 — phase 3 seeds it, so something removed it';
  end if;

  if v_model in ('gemini-2.0-flash', 'gemini-2.0-flash-001',
                 'gemini-2.0-flash-lite', 'gemini-2.0-flash-lite-001') then
    raise exception 'ai_settings still names a retired model: %', v_model;
  end if;

  if v_model = 'gemini-3.8-flash' then
    raise exception 'ai_settings still names the over-heavy model: %', v_model;
  end if;

  if btrim(coalesce(v_model, '')) = '' then
    raise exception 'ai_settings.model is blank — the function would fall back without saying so';
  end if;

  select pg_get_expr(d.adbin, d.adrelid) into v_default
    from pg_attrdef d
    join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
   where d.adrelid = 'public.ai_settings'::regclass
     and a.attname = 'model';

  if v_default is null or v_default not like '%gemini-3.5-flash-lite%' then
    raise exception 'the model column default was not updated: %', coalesce(v_default, '<none>');
  end if;

  raise notice 'phase 15 self-test passed: live model is %, new rows default to gemini-3.5-flash-lite', v_model;
end $$;

commit;

-- ═══════════════════════════════════════════════════════════════
--  Run this first and test before touching the function. If the
--  generator answers, the deploy is tidying rather than firefighting.
--
--    curl -i -X POST \
--      https://stowxeobdtvhapkzsvaq.supabase.co/functions/v1/ai-generate \
--      -H "apikey: <publishable key>" \
--      -H "Authorization: Bearer <publishable key>" \
--      -H "Content-Type: application/json" \
--      -d '{"feeling":"tired but okay","mood":"Peaceful",
--           "style":"Minimal","length":"One Line",
--           "visitor_id":"00000000-0000-4000-8000-000000000001"}'
--
--  Paste the real key — <publishable key> written literally returns
--  401 UNAUTHORIZED_INVALID_JWT_FORMAT.
--
--  200 carrying a "quote" field is a pass. A 502 means look at
--  Edge Functions → ai-generate → Logs: "provider error <status>"
--  is the model or the key, "empty generation <finishReason>" is the
--  model answering with nothing, which is thinking depth again.
-- ═══════════════════════════════════════════════════════════════
