-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 14 migration: move off a retired AI model
--  Safe to run more than once.
--
--  The AI generator has been answering "SeRuh couldn't find the
--  words this time" since Google shut down gemini-2.0-flash on
--  1 June 2026. A request naming a retired model gets 404 from
--  generativelanguage.googleapis.com; the edge function sees
--  !res.ok, writes a FAILED row and returns 502. Nothing on our
--  side was broken, which is exactly why nothing looked broken.
--
--  Phase 3 seeds ai_settings with id = 1 and lets every other
--  column take its default, so production has been carrying
--  'gemini-2.0-flash' in that row since the day it was created.
--
--  The model is read from ai_settings on every request, so this
--  one row brings the generator back with no redeploy. The two
--  matching literals in the edge function are only fallbacks for
--  a missing settings row, and are corrected separately.
--
--  Why gemini-3.8-flash: it is the current Flash tier, and the
--  whole value of this feature is the quality of a short piece of
--  writing. Volume is small — 5 generations a day for a guest, 25
--  signed in — so the cheaper gemini-3.5-flash-lite saves little
--  here. Switching later is one UPDATE, not an edit to this file.
-- ═══════════════════════════════════════════════════════════════

begin;

-- ─── 1. The live setting ────────────────────────────────────────
-- Retired ids are named one by one rather than matched on a
-- pattern, so a 2.x model that is still served is never swept up.
update public.ai_settings
   set model = 'gemini-3.8-flash'
 where id = 1
   and model in ('gemini-2.0-flash', 'gemini-2.0-flash-001',
                 'gemini-2.0-flash-lite', 'gemini-2.0-flash-lite-001');

-- ─── 2. The column default, for a fresh install ─────────────────
alter table public.ai_settings
  alter column model set default 'gemini-3.8-flash';

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

  if btrim(coalesce(v_model, '')) = '' then
    raise exception 'ai_settings.model is blank — the function would fall back without saying so';
  end if;

  select pg_get_expr(d.adbin, d.adrelid) into v_default
    from pg_attrdef d
    join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
   where d.adrelid = 'public.ai_settings'::regclass
     and a.attname = 'model';

  if v_default is null or v_default not like '%gemini-3.8-flash%' then
    raise exception 'the model column default was not updated: %', coalesce(v_default, '<none>');
  end if;

  raise notice 'phase 14 self-test passed: live model is %, new rows default to gemini-3.8-flash', v_model;
end $$;

commit;

-- ═══════════════════════════════════════════════════════════════
--  After this runs the generator works again, with no deploy.
--
--  Verify from a terminal — this is the same call the page makes:
--
--    curl -i -X POST \
--      https://<project>.supabase.co/functions/v1/ai-generate \
--      -H "apikey: <publishable key>" \
--      -H "Authorization: Bearer <publishable key>" \
--      -H "Content-Type: application/json" \
--      -d '{"feeling":"I feel calm tonight","mood":"Peaceful",
--           "style":"Midnight","length":"Short",
--           "visitor_id":"00000000-0000-4000-8000-000000000001"}'
--
--  200 carrying a "quote" field is a pass. A 502 means the
--  provider is still refusing; the exact reason is printed in the
--  Supabase dashboard under Edge Functions → ai-generate → Logs,
--  as: provider error <status> <body>.
-- ═══════════════════════════════════════════════════════════════
