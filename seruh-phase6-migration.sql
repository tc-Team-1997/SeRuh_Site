-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 6 migration: release the legacy FLAGGED backlog
--  Run AFTER seruh-phase5-migration.sql (it needs the repaired
--  moderation engine). Safe to run more than once.
--
--  Scope: adds two admin-only functions and, when you call the
--  second one, updates legacy rows in public.feelings. No schema
--  changes, no threshold changes, no existing function altered.
--
--  Defect (F-03):
--    seruh-phase4-migration.sql line 51 did
--      update feelings set status = 'FLAGGED' where status = 'PENDING';
--    which turned "nobody got round to approving this" into
--    "moderation flagged this". Those feelings are not on the wall,
--    their authors were never told, and clearing them needs an admin
--    click — the mandatory-approval workflow Phase 4 set out to
--    remove, still in force for everything submitted before it ran.
--
--    They are identifiable: a genuinely flagged row always carries a
--    moderation_decision, because finalize_publish() sets one. A row
--    with status = 'FLAGGED' and moderation_decision IS NULL was
--    never moderated at all — the migration relabelled it.
--
--  What this does:
--    Re-runs the (now working) engine over exactly those rows and
--    routes each by its real score, using the thresholds configured
--    in mod_settings rather than any hard-coded number:
--
--      score <  flag_threshold    → PUBLISHED, decision ALLOW
--      score >= flag_threshold    → stays FLAGGED, but now with a
--                                   real decision/score/reason so the
--                                   admin queue is meaningful
--      score >= reject_threshold  → REMOVED, decision REJECT
--
--    Every row touched gets a moderation_logs entry with
--    source = 'SYSTEM', so the backfill is auditable afterwards.
--    created_at is never modified; published_at is set to the row's
--    own write time, matching what Phase 4 did for APPROVED rows.
--
--  How to use it — preview first, it changes nothing:
--
--    select * from public.preview_legacy_flagged();
--    select * from public.release_legacy_flagged();
--
--  Neither function is granted to anon or authenticated. Run them
--  from the Supabase SQL Editor.
-- ═══════════════════════════════════════════════════════════════

-- ─── Dry run: what would happen, and to how many ────────────────
create or replace function public.preview_legacy_flagged()
returns table (
  outcome        text,
  rows           bigint,
  min_score      numeric,
  max_score      numeric,
  sample_reason  text,
  oldest         timestamptz,
  newest         timestamptz
) language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select flag_threshold, reject_threshold into s from public.mod_settings where id = 1;

  return query
  with legacy as (
    select f.id, f.created_at,
           (public.moderate_text(coalesce(f.title, '') || ' ' || f.content)) as m
    from public.feelings f
    where f.status = 'FLAGGED' and f.moderation_decision is null
  ), scored as (
    select id, created_at,
           (m->>'score')::numeric as score,
           m->>'reason' as reason,
           case
             when (m->>'score')::numeric >= s.reject_threshold then 'REMOVED (reject)'
             when (m->>'score')::numeric >= s.flag_threshold   then 'FLAGGED (genuinely)'
             else 'PUBLISHED (released)'
           end as outcome
    from legacy
  )
  select sc.outcome, count(*)::bigint, min(sc.score), max(sc.score),
         max(sc.reason), min(sc.created_at), max(sc.created_at)
  from scored sc
  group by sc.outcome
  order by sc.outcome;
end $$;

revoke execute on function public.preview_legacy_flagged() from public, anon, authenticated;

-- ─── Apply ──────────────────────────────────────────────────────
-- p_only restricts the run to specific ids. It exists so the
-- self-test below can exercise the routing on its own throwaway
-- rows without touching the real backlog — applying this migration
-- must never perform the backfill as a side effect.
create or replace function public.release_legacy_flagged(p_only uuid[] default null)
returns table (outcome text, rows bigint)
language plpgsql security definer set search_path = public as $$
declare
  s        record;
  r        record;
  m        json;
  v_score  numeric;
  v_reason text;
  v_status text;
  v_dec    text;
  n_pub    bigint := 0;
  n_flag   bigint := 0;
  n_rem    bigint := 0;
begin
  select flag_threshold, reject_threshold into s from public.mod_settings where id = 1;

  for r in
    select id, title, content, updated_at, created_at
    from public.feelings
    where status = 'FLAGGED' and moderation_decision is null
      and (p_only is null or id = any(p_only))
    order by created_at
  loop
    m := public.moderate_text(coalesce(r.title, '') || ' ' || r.content);
    v_score  := (m->>'score')::numeric;
    v_reason := m->>'reason';

    if v_score >= s.reject_threshold then
      v_status := 'REMOVED';  v_dec := 'REJECT';  n_rem  := n_rem  + 1;
    elsif v_score >= s.flag_threshold then
      v_status := 'FLAGGED';  v_dec := 'FLAG';    n_flag := n_flag + 1;
    else
      v_status := 'PUBLISHED'; v_dec := 'ALLOW';  n_pub  := n_pub  + 1;
    end if;

    update public.feelings set
      status              = v_status,
      moderation_decision = v_dec,
      moderation_score    = v_score,
      moderation_reason   = v_reason,
      -- only a released row gains a publication time; keep any existing one
      published_at        = case when v_status = 'PUBLISHED'
                                 then coalesce(published_at, updated_at, created_at)
                                 else published_at end,
      removed_at          = case when v_status = 'REMOVED' then now() else removed_at end,
      updated_at          = now()
    where id = r.id;

    insert into public.moderation_logs (feeling_id, action, decision, risk_score, reason, source)
    values (r.id, 'legacy_backfill_' || lower(v_status), v_dec, v_score, v_reason, 'SYSTEM');
  end loop;

  -- t.rows must be qualified: bare "rows" would collide with the
  -- OUT parameter of the same name
  return query
    select t.label, t.n from (values
      ('PUBLISHED (released)', n_pub),
      ('FLAGGED (genuinely)',  n_flag),
      ('REMOVED (reject)',     n_rem)
    ) as t(label, n)
    where t.n > 0;
end $$;

revoke execute on function public.release_legacy_flagged(uuid[]) from public, anon, authenticated;

-- ─── Self-test: proves the routing on throwaway rows ────────────
-- Creates three legacy-shaped rows, runs the release, checks each
-- landed where it should, then removes them. It asserts rather than
-- reporting, so a wrong result stops the migration.
do $$
declare
  id_safe uuid; id_flag uuid; id_bad uuid;
  st text; dec text; sc numeric; wall int; logs int;
  pre_legacy bigint;
begin
  -- how many real legacy rows are waiting (reported, not touched here)
  select count(*) into pre_legacy from public.feelings
   where status = 'FLAGGED' and moderation_decision is null;

  insert into public.feelings (content, mood, status, visibility)
  values ('phase6 selftest — a quiet safe feeling about missing someone', 'Sad', 'FLAGGED', 'PUBLIC')
  returning id into id_safe;
  insert into public.feelings (content, mood, status, visibility)
  values ('phase6 selftest — you are such a bitch and i hate you', 'Sad', 'FLAGGED', 'PUBLIC')
  returning id into id_flag;
  insert into public.feelings (content, mood, status, visibility)
  values ('phase6 selftest — you are a worthless idiot and i will hurt you', 'Sad', 'FLAGGED', 'PUBLIC')
  returning id into id_bad;

  perform public.release_legacy_flagged(array[id_safe, id_flag, id_bad]);

  -- safe → published and on the wall
  select status, moderation_decision into st, dec from public.feelings where id = id_safe;
  if st <> 'PUBLISHED' or dec <> 'ALLOW' then
    raise exception 'safe legacy row not released: status=% decision=%', st, dec;
  end if;
  select count(*) into wall from public.feelings_public where id = id_safe;
  if wall <> 1 then raise exception 'released row did not reach the wall'; end if;
  if (select published_at is null from public.feelings where id = id_safe) then
    raise exception 'released row has no published_at';
  end if;

  -- borderline → stays flagged, but now labelled
  select status, moderation_decision, moderation_score into st, dec, sc
    from public.feelings where id = id_flag;
  if st <> 'FLAGGED' or dec <> 'FLAG' or sc is null then
    raise exception 'borderline row mislabelled: status=% decision=% score=%', st, dec, sc;
  end if;
  if (select count(*) from public.feelings_public where id = id_flag) <> 0 then
    raise exception 'flagged row leaked onto the wall';
  end if;

  -- directed abuse → removed
  select status, moderation_decision into st, dec from public.feelings where id = id_bad;
  if st <> 'REMOVED' or dec <> 'REJECT' then
    raise exception 'abusive row not removed: status=% decision=%', st, dec;
  end if;

  -- every touched row is auditable
  select count(*) into logs from public.moderation_logs
   where feeling_id in (id_safe, id_flag, id_bad) and source = 'SYSTEM';
  if logs <> 3 then raise exception 'expected 3 SYSTEM audit rows, found %', logs; end if;

  -- idempotent: nothing left to do
  if exists (select 1 from public.feelings
             where id in (id_safe, id_flag, id_bad)
               and status = 'FLAGGED' and moderation_decision is null) then
    raise exception 'rows still look legacy after release';
  end if;

  delete from public.moderation_logs where feeling_id in (id_safe, id_flag, id_bad);
  delete from public.feelings where id in (id_safe, id_flag, id_bad);

  raise notice 'phase 6 self-test passed: safe→PUBLISHED, borderline→FLAGGED+labelled, abusive→REMOVED, 3 audit rows, idempotent';
  if pre_legacy > 0 then
    raise notice 'phase 6: % real legacy row(s) still awaiting release — nothing was changed. Run: select * from preview_legacy_flagged();  then: select * from release_legacy_flagged();', pre_legacy;
  else
    raise notice 'phase 6: no legacy rows found — nothing to release';
  end if;
end $$;
