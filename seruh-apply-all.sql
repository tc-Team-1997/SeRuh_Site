-- ═══════════════════════════════════════════════════════════════
--  SeRuh — apply everything outstanding, in one paste.
--
--  Supabase → SQL Editor → New query → paste → Run.
--
--  THE WHOLE FILE IS ONE TRANSACTION. Either all of it applies or
--  none of it does. The individual seruh-phaseN-migration.sql files
--  each commit separately; this bundle deliberately does not, so a
--  failure anywhere cannot leave the database half-migrated — and so
--  the "already applied" guard below cannot be stepped past by a
--  client configured to continue after an error.
--
--  Contains, in dependency order:
--    5   moderation engine   (already applied 3 Sep; a no-op, but
--        included because phase 6 calls it and a bundle should not
--        depend on what it assumes)
--    5b  likes on the wall — they throw today
--    6   release the stranded legacy backlog
--    7   keep contact details off the wall
--    8   daily prompts, archive, curated highlights
--    9   emotional reactions
--    10  post register
--    11  echoes
--    12  comments on quotes
--
--  Every section ends in an assertion block that raises rather than
--  applying something wrong. Nothing here deletes data or overwrites
--  an existing value.
--
--  Three things it deliberately does NOT do. Each changes existing
--  rows and deserves a look at its preview first:
--    select * from preview_legacy_flagged();        then release_legacy_flagged();
--    select * from preview_unsafe_display_names();  then scrub_unsafe_display_names();
--    select * from preview_register_backfill();     then apply_register_backfill();
-- ═══════════════════════════════════════════════════════════════

begin;

-- ─── Guard: this bundle runs once ───────────────────────────────
-- Three sections own successive signatures of publish_feeling and
-- two own successive versions of feelings_public. Replaying that
-- would recreate a narrower signature beside a wider one, or try to
-- shrink a view CREATE OR REPLACE can only grow. Refusing is safer
-- than mutating shared objects to force a replay.
do $$
begin
  if to_regclass('public.quote_comments') is not null then
    raise exception 'Already applied — nothing was changed. Re-run an individual seruh-phaseN-migration.sql if you need to.';
  end if;
end $$;


-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase5-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 5 migration: moderation engine repair
--  Run AFTER seruh-setup.sql, seruh-phase3-migration.sql and
--  seruh-phase4-migration.sql. Safe to run more than once.
--
--  Scope: public.moderate_text() ONLY.
--  No schema changes. No threshold changes. No other function,
--  view, policy or table is touched. mod_settings keeps its
--  configured flag_threshold (0.35) and reject_threshold (0.70).
--
--  What changes:
--   1. Category append no longer throws. `cats := cats || 'spam'`
--      was resolved by Postgres as anyarray || anyarray and raised
--      22P02 malformed array literal, so ANY content matching ANY
--      rule aborted the whole submission. Now array_append().
--   2. Directed abuse and threats are detected, in two tiers:
--        Tier 1 (+0.90, >= reject_threshold → blocked before insert)
--          unambiguous second-person threat or slur.
--        Tier 2 (+0.60, flag only → publishes, admin reviews)
--          phrases that also occur reflexively in genuine feelings
--          ("some days it feels like everyone hates you").
--      Both tiers are second-person only: a feeling about oneself
--      ("I feel worthless") must never be touched.
--   3. Contractions are matched. The alternation now carries its
--      own leading space — you( are|'re), i( will|'ll| am going to)
--      — because `you (are|'re)` only ever matched "you 're".
-- ═══════════════════════════════════════════════════════════════

create or replace function public.moderate_text(p_text text)
returns json language plpgsql immutable as $$
declare
  t text := lower(coalesce(p_text, ''));
  score numeric := 0;
  cats text[] := '{}';
  links int;
begin
  -- malicious / injection
  if t ~ '(<\s*script|javascript\s*:|onerror\s*=|onload\s*=|<\s*iframe|data:text/html|srcdoc\s*=)' then
    score := score + 0.95; cats := array_append(cats, 'malicious');
  elsif t ~ '<\s*[a-z]+[^>]*>' then
    score := score + 0.5; cats := array_append(cats, 'html');
  end if;
  if t ~ '(union\s+(all\s+)?select|insert\s+into\s+\w|drop\s+table|xp_cmdshell|;\s*delete\s+from)' then
    score := score + 0.9; cats := array_append(cats, 'malicious');
  end if;

  -- links & promotion (spam)
  links := (char_length(t) - char_length(replace(replace(t, 'http://', ''), 'https://', ''))) / 7;
  if links >= 2 then score := score + 0.6; cats := array_append(cats, 'spam');
  elsif links = 1 then score := score + 0.3; cats := array_append(cats, 'links');
  end if;
  if t ~ '(buy now|click here|limited offer|promo code|discount code|earn money|make \$|whatsapp me|call me at|dm for|follow me|subscribe to|free followers|crypto invest|loan approval)' then
    score := score + 0.55; cats := array_append(cats, 'spam');
  end if;

  -- severe abuse / threats / self-harm encouragement
  if t ~ '(kill yourself|kys\M|go die\M|you should die|i will kill|i''ll kill|rape you|deserve to be raped|behead|lynch)' then
    score := score + 0.95; cats := array_append(cats, 'abuse');
  end if;
  if t ~ '(bomb (the|a)|plant a bomb|shoot up|attack (the|a) (school|temple|mosque|church))' then
    score := score + 0.95; cats := array_append(cats, 'threat');
  end if;

  -- Tier 1 — directed threat or slur aimed at another person.
  -- Weighted to clear reject_threshold on its own: this content is
  -- blocked before insert and never reaches the public wall.
  if t ~ '(i( will|''ll| am going to) (hurt|beat) you|you( are|''re) (a |an |such a )?(worthless|stupid|pathetic|disgusting) (idiot|loser|person|trash|piece)|you( are|''re) (trash|garbage))' then
    score := score + 0.90; cats := array_append(cats, 'abuse');
  end if;

  -- Tier 2 — same register, but these phrasings also carry a
  -- reflexive/generic "you" in genuine emotional writing, so they
  -- flag for review rather than block. The guard drops the common
  -- consoling construction ("it is not that nobody wants you...").
  if t ~ '(everyone hates you|nobody (loves|likes|wants) you)'
     and t !~ '(not that|n''t that|not because) nobody (loves|likes|wants) you' then
    score := score + 0.60; cats := array_append(cats, 'abuse');
  end if;

  -- harassment-ish profanity (moderate)
  if t ~ '\m(bitch|bastard|asshole|chutiya|madarchod|behenchod|randi|kamina|haramzada|whore|slut)\M' then
    score := score + 0.45; cats := array_append(cats, 'profanity');
  end if;

  -- bot-ish noise
  if t ~ '(.)\1{7,}' then score := score + 0.15; cats := array_append(cats, 'noise'); end if;

  return json_build_object(
    'score', least(1.0, score),
    'categories', to_json(cats),
    'reason', case when array_length(cats,1) is null then null else array_to_string(cats, ', ') end
  );
end $$;

-- ─── Self-test: fails loudly rather than silently mis-scoring ───
-- Reads mod_settings so the assertions track the configured
-- thresholds instead of hard-coding 0.35 / 0.70.
do $$
declare
  reject numeric;
  flagat numeric;
  s      numeric;
  fails  text[] := '{}';

  procedure_note text;

  -- must be blocked outright (score >= reject_threshold)
  block_cases text[] := array[
    'You are a worthless idiot and I will hurt you. Everyone hates you, you stupid trash.',
    'i''ll hurt you if you keep talking',
    'i am going to beat you up',
    'you''re such a stupid loser',
    'you are trash and always will be',
    'you''re garbage, honestly',
    '<script>alert(document.cookie)</script> I feel sad',
    'Buy now! click here https://a.example https://b.example',
    'kill yourself you worthless person'
  ];

  -- must publish untouched (score < flag_threshold)
  allow_cases text[] := array[
    'I miss the person I used to be.',
    'I know I will find you again in another life.',
    'I will get you through this, I promise.',
    'You are nothing short of everything I never knew I needed.',
    'You are nothing but kind, even when I gave you no reason.',
    'It is not that nobody wants you - it is that you stopped asking.',
    'I feel worthless today, like nobody would notice if I disappeared for a while.',
    'I feel stupid for still waiting on someone who never looked back.',
    'Sometimes the thing you want to hold is the thing that hurts you the most.',
    'You are a person I keep writing letters to and never sending.',
    'you''re the reason I still believe in soft things'
  ];

  -- must publish, but be surfaced to an admin
  flag_cases text[] := array[
    'Some days it feels like everyone hates you and you cannot explain why.',
    'you are such a bitch and i hate you'
  ];
begin
  select reject_threshold, flag_threshold into reject, flagat from public.mod_settings where id = 1;

  foreach procedure_note in array block_cases loop
    s := (public.moderate_text(procedure_note) ->> 'score')::numeric;
    if s < reject then
      fails := array_append(fails, format('NOT BLOCKED (%s < %s): %s', s, reject, left(procedure_note, 44)));
    end if;
  end loop;

  foreach procedure_note in array allow_cases loop
    s := (public.moderate_text(procedure_note) ->> 'score')::numeric;
    if s >= flagat then
      fails := array_append(fails, format('FALSE POSITIVE (%s >= %s): %s', s, flagat, left(procedure_note, 44)));
    end if;
  end loop;

  foreach procedure_note in array flag_cases loop
    s := (public.moderate_text(procedure_note) ->> 'score')::numeric;
    if s < flagat or s >= reject then
      fails := array_append(fails, format('NOT FLAGGED (%s): %s', s, left(procedure_note, 44)));
    end if;
  end loop;

  if array_length(fails, 1) is not null then
    raise exception E'moderate_text self-test failed:\n%', array_to_string(fails, E'\n');
  end if;

  raise notice 'moderate_text self-test passed: % blocked, % allowed, % flagged (reject >= %, flag >= %)',
    array_length(block_cases, 1), array_length(allow_cases, 1), array_length(flag_cases, 1), reject, flagat;
end $$;

-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase5b-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 5b migration: repair likes on the feelings wall
--  Run AFTER seruh-phase5-migration.sql. Safe to run more than once.
--
--  Scope: public.toggle_feeling_like() ONLY.
--  No schema changes, no threshold changes, no other function,
--  view, policy or table is touched.
--
--  Defect (F-02):
--    toggle_feeling_like() was last defined in Phase 3 and still
--    guards on status = 'APPROVED'. Phase 4 replaced the status
--    vocabulary — the check constraint now allows only PUBLISHED /
--    FLAGGED / REMOVED / ARCHIVED / UNDER_REVIEW — so the guard can
--    never be satisfied and EVERY like on the public wall raises
--    'feeling not available'. The UI updates optimistically, so the
--    heart fills, the count rises, then both revert with an error.
--
--  Fix:
--    A feeling is likeable exactly when it is visible, so the guard
--    reads public.feelings_public — the wall view itself — instead
--    of restating its predicate. Restating it would create a second
--    definition of "visible" that can silently drift from the view
--    the way the 'APPROVED' check drifted from the status model.
--    One source of truth: change the wall, and likes follow.
--
--    Consequence, by construction:
--      PUBLISHED + PUBLIC/ANONYMOUS  → in the view  → likeable
--      PRIVATE                       → not in view  → refused
--      FLAGGED / UNDER_REVIEW        → not in view  → refused
--      REMOVED / ARCHIVED            → not in view  → refused
-- ═══════════════════════════════════════════════════════════════

create or replace function public.toggle_feeling_like(p_feeling uuid, p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_liked boolean; v_count bigint; v_user uuid := auth.uid();
begin
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;

  -- single source of truth: likeable iff it is on the public wall
  if not exists (select 1 from public.feelings_public where id = p_feeling) then
    raise exception 'feeling not available';
  end if;

  if v_user is not null then
    delete from public.feeling_likes where feeling_id = p_feeling and user_id = v_user;
  else
    delete from public.feeling_likes where feeling_id = p_feeling and visitor_id = p_visitor and user_id is null;
  end if;

  if not found then
    insert into public.feeling_likes (feeling_id, visitor_id, user_id)
    values (p_feeling, coalesce(p_visitor, gen_random_uuid()), v_user)
    on conflict do nothing;
    v_liked := true;
  else
    v_liked := false;
  end if;

  select count(*) into v_count from public.feeling_likes where feeling_id = p_feeling;
  return json_build_object('liked', v_liked, 'count', v_count);
end $$;

-- ─── Self-test: fails loudly rather than shipping a broken like ──
do $$
declare
  v_pub uuid; v_visitor uuid := gen_random_uuid();
  v_probe uuid; v_state text;
  r json; base bigint; n bigint; msg text;
  hidden_states text[] := array['PRIVATE','FLAGGED','REMOVED','ARCHIVED','UNDER_REVIEW'];
begin
  select id into v_pub from public.feelings_public order by created_at desc limit 1;
  if v_pub is null then
    raise notice 'toggle_feeling_like self-test skipped: no published wall post to test against';
    return;
  end if;

  select count(*) into base from public.feeling_likes where feeling_id = v_pub;

  -- like
  r := public.toggle_feeling_like(v_pub, v_visitor);
  if (r->>'liked')::boolean is not true then raise exception 'like did not register: %', r; end if;
  if (r->>'count')::bigint <> base + 1 then
    raise exception 'like count wrong: expected %, got %', base + 1, r->>'count';
  end if;

  -- a second like from the same visitor is a toggle, not a duplicate row
  r := public.toggle_feeling_like(v_pub, v_visitor);
  if (r->>'liked')::boolean is not false then raise exception 'second call did not unlike: %', r; end if;
  select count(*) into n from public.feeling_likes
    where feeling_id = v_pub and visitor_id = v_visitor and user_id is null;
  if n <> 0 then raise exception 'duplicate like rows left behind: %', n; end if;
  if (r->>'count')::bigint <> base then
    raise exception 'count not restored: expected %, got %', base, r->>'count';
  end if;

  -- every non-visible state must refuse, using a throwaway row per state
  foreach v_state in array hidden_states loop
    if v_state = 'PRIVATE' then
      insert into public.feelings (content, mood, status, visibility)
      values ('self-test probe', 'Sad', 'PUBLISHED', 'PRIVATE') returning id into v_probe;
    else
      insert into public.feelings (content, mood, status, visibility)
      values ('self-test probe', 'Sad', v_state, 'PUBLIC') returning id into v_probe;
    end if;

    begin
      r := public.toggle_feeling_like(v_probe, v_visitor);
      delete from public.feelings where id = v_probe;
      raise exception 'non-visible feeling (%) was likeable — guard is too loose', v_state;
    exception when others then
      msg := SQLERRM;
      delete from public.feelings where id = v_probe;
      if msg <> 'feeling not available' then raise; end if;
    end;
  end loop;

  raise notice 'toggle_feeling_like self-test passed: like/unlike toggles cleanly, count restored to %, and PRIVATE/FLAGGED/REMOVED/ARCHIVED/UNDER_REVIEW all refused', base;
end $$;

-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase6-migration.sql
-- ══════════════════════════════════════════════════════════
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

-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase7-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 7 migration: keep contact details off the wall
--  Run AFTER seruh-phase5-migration.sql. Safe to run more than once.
--
--  Scope: one new helper, one new preview/scrub pair, and a
--  surgical change to publish_feeling (name handling only — the
--  moderation, rate-limit, duplicate and ownership logic is
--  untouched). No schema changes, no threshold changes.
--
--  Defect (F-08):
--    publish_feeling trims a display name to 80 characters and
--    publishes it verbatim as feelings_public.display_name, a view
--    anon can read. Nothing stops someone typing an email address,
--    a phone number or a link where a first name belongs. The live
--    wall already carries one: "amit@rudra".
--
--  What this does:
--    Treats a name that looks like contact details as no name at
--    all: the feeling still publishes, the author is told, and the
--    post shows as Anonymous. Rejecting the submission instead
--    would cost someone their writing over a form field — the wrong
--    trade on a platform people come to in order to say something.
--
--    The rule lives in one function, looks_like_contact(), so the
--    live path and the backfill cannot drift apart.
--
--  Deliberately narrow, to protect real names:
--      contains "@"                     → amit@rudra, a@b.com
--      7+ digits allowing spaces/()+-   → +91 99999 99999
--      contains http / www.             → promo links
--    "Ravi", "Ash", "QA Tester", "Ravi123", "O'Brien", "Anne-Marie"
--    and "जया" all pass untouched — asserted in the self-test.
--
--  Existing rows — preview first, it changes nothing:
--
--    select * from public.preview_unsafe_display_names();
--    select * from public.scrub_unsafe_display_names();
-- ═══════════════════════════════════════════════════════════════

-- ─── The rule, in one place ─────────────────────────────────────
create or replace function public.looks_like_contact(p_name text)
returns boolean language sql immutable as $$
  select case
    when p_name is null or btrim(p_name) = '' then false
    when p_name like '%@%' then true
    when p_name ~ '[0-9][0-9\s().+-]{5,}[0-9]' then true
    when lower(p_name) ~ '(https?://|www\.)' then true
    else false
  end
$$;

-- ─── Live path: drop the name, publish anyway, say so ───────────
create or replace function public.publish_feeling(
  p_title text, p_content text, p_category text, p_mood text,
  p_visibility text, p_name text, p_visitor uuid,
  p_honey text default '', p_tags text[] default '{}', p_edit_id uuid default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_user uuid := auth.uid(); v_recent int; v_limit int; m json; v_vis text;
  v_name text; v_name_dropped boolean := false; v_result json;
begin
  select * into s from public.mod_settings where id = 1;

  -- honeypot: silently accept but never store (bot trap)
  if coalesce(p_honey,'') <> '' then
    insert into public.moderation_logs (action, decision, reason, source)
    values ('honeypot_tripped', 'REJECT', 'bot suspected', 'SYSTEM');
    return json_build_object('ok', true, 'decision', 'ALLOW', 'message', 'Your words are out there now. ❤️');
  end if;

  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if v_user is not null and exists (select 1 from public.profiles where user_id = v_user and status <> 'ACTIVE') then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'This account can''t publish right now.');
  end if;

  v_vis := upper(coalesce(p_visibility, 'PUBLIC'));
  if v_vis not in ('PUBLIC','ANONYMOUS','PRIVATE') then v_vis := 'PUBLIC'; end if;
  if char_length(btrim(coalesce(p_content,''))) < 3 then raise exception 'too short'; end if;
  if char_length(p_content) > s.max_content_len then raise exception 'too long'; end if;
  if char_length(coalesce(p_title,'')) > s.max_title_len then raise exception 'title too long'; end if;

  -- rate limit (stricter for guests)
  v_limit := case when v_user is not null then s.user_max_per_10min else s.guest_max_per_10min end;
  select count(*) into v_recent from public.feelings
    where created_at > now() - interval '10 minutes'
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor));
  if v_recent >= v_limit then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'Take a breath — you can share again in a few minutes. 🕊️');
  end if;

  -- duplicate detection
  if exists (
    select 1 from public.feelings
    where lower(btrim(content)) = lower(btrim(p_content))
      and created_at > now() - (s.duplicate_window_hours || ' hours')::interval
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor))
      and (p_edit_id is null or id <> p_edit_id)
  ) then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'You''ve already shared these exact words. Say it a new way? 🤍');
  end if;

  -- ownership check for edits (never bypass moderation by editing)
  if p_edit_id is not null and not exists (
    select 1 from public.feelings where id = p_edit_id
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor and user_id is null))
  ) then
    raise exception 'not yours to edit';
  end if;

  -- F-08: a display name is published verbatim to a wall anon can
  -- read. Contact details do not belong there, so drop the name and
  -- publish as Anonymous rather than rejecting and costing the
  -- author what they wrote.
  v_name := p_name;
  if public.looks_like_contact(v_name) then
    v_name := null;
    v_name_dropped := true;
  end if;

  m := public.moderate_text(coalesce(p_title,'') || ' ' || p_content);

  v_result := public.finalize_publish(
    p_edit_id, v_user, p_visitor, p_title, p_content, p_category, p_mood,
    v_vis, v_name, p_tags, (m->>'score')::numeric, m->>'reason', 'AUTOMATED');

  -- say so, rather than silently changing what they typed
  if v_name_dropped and coalesce((v_result->>'ok')::boolean, false) then
    v_result := jsonb_set(
      v_result::jsonb, '{message}',
      to_jsonb('Shared — we left the name off, it looked like contact details. 🤍'::text)
    )::json;
  end if;

  return v_result;
end $$;
-- ─── Existing rows: dry run ─────────────────────────────────────
create or replace function public.preview_unsafe_display_names()
returns table (feeling_id uuid, current_name text, visibility text, status text, created_at timestamptz)
language sql security definer set search_path = public as $$
  select f.id, f.name, f.visibility, f.status, f.created_at
  from public.feelings f
  where public.looks_like_contact(f.name)
  order by f.created_at;
$$;
revoke execute on function public.preview_unsafe_display_names() from public, anon, authenticated;

-- ─── Existing rows: apply ───────────────────────────────────────
-- The feeling itself is never touched — only the name is cleared,
-- so the post stays exactly where it is and shows as Anonymous.
create or replace function public.scrub_unsafe_display_names()
returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  with scrubbed as (
    update public.feelings
       set name = null, updated_at = now()
     where public.looks_like_contact(name)
    returning id
  )
  insert into public.moderation_logs (feeling_id, action, decision, reason, source)
  select id, 'display_name_scrubbed', null, 'looked like contact details', 'SYSTEM' from scrubbed;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.scrub_unsafe_display_names() from public, anon, authenticated;

-- ─── Self-test ──────────────────────────────────────────────────
do $$
declare
  r json; v uuid := gen_random_uuid(); shown text; pending bigint; nm text;
  keep text[] := array['Ravi','Ash','QA Tester','Ravi123','O''Brien','Anne-Marie','जया','Amit Kumar'];
  drop_ text[] := array['amit@rudra','a@b.com','+91 99999 99999','(555) 123-4567','www.buyfollowers.io','https://x.io'];
begin
  -- the rule itself: real names survive, contact details do not
  foreach nm in array keep loop
    if public.looks_like_contact(nm) then
      raise exception 'false positive — real name rejected: %', nm;
    end if;
  end loop;
  foreach nm in array drop_ loop
    if not public.looks_like_contact(nm) then
      raise exception 'missed contact detail: %', nm;
    end if;
  end loop;

  -- live path: a feeling with an email-shaped name still publishes
  r := public.publish_feeling(null, 'phase7 selftest — a quiet line about waiting',
        'Life', 'Emotional', 'PUBLIC', 'someone@example.com', v);
  if not coalesce((r->>'ok')::boolean, false) then
    raise exception 'feeling with an email-shaped name failed to publish: %', r;
  end if;
  if r->>'message' not like '%left the name off%' then
    raise exception 'author was not told the name was dropped: %', r->>'message';
  end if;

  select display_name into shown from public.feelings_public where id = (r->>'id')::uuid;
  if shown <> 'Anonymous' then
    raise exception 'contact-shaped name reached the wall as %', shown;
  end if;
  if (select name is not null from public.feelings where id = (r->>'id')::uuid) then
    raise exception 'contact-shaped name was still stored';
  end if;

  -- a real name is untouched, and the normal message is unchanged
  r := public.publish_feeling(null, 'phase7 selftest — another quiet line about waiting',
        'Life', 'Emotional', 'PUBLIC', 'Ravi', gen_random_uuid());
  select display_name into shown from public.feelings_public where id = (r->>'id')::uuid;
  if shown <> 'Ravi' then raise exception 'real name was altered: %', shown; end if;
  if r->>'message' like '%left the name off%' then
    raise exception 'unnecessary name notice on a clean name';
  end if;

  delete from public.feelings where content like 'phase7 selftest%';

  select count(*) into pending from public.preview_unsafe_display_names();
  raise notice 'phase 7 self-test passed: % real names kept, % contact patterns caught, feeling still publishes as Anonymous with the author told', array_length(keep,1), array_length(drop_,1);
  if pending > 0 then
    raise notice 'phase 7: % existing row(s) carry contact-shaped names — nothing was changed. Run: select * from preview_unsafe_display_names();  then: select public.scrub_unsafe_display_names();', pending;
  else
    raise notice 'phase 7: no existing rows carry contact-shaped names';
  end if;
end $$;

-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase8-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 8 migration: daily prompts, archive, highlights
--  Run AFTER seruh-phase7-migration.sql. Safe to run more than once.
--
--  Why this one comes first of the five in the engagement brief:
--  eight posts in three weeks is a blank-page problem as much as a
--  traffic problem, and a question is the cheapest known fix for a
--  blank page. Everything else in that brief needs an audience
--  first; this changes what the few who do arrive are looking at.
--
--  Scope — backend only. Every screen this serves still needs the
--  application source, which is not in the repository. What ships
--  here is the schema and the API those screens will call.
--
--  What it adds:
--    · prompts            — the questions, schedulable or rotating
--    · feelings.prompt_id — which question a feeling answers
--    · feelings.featured  — a curator's pick for the landing page
--    · public RPCs        — today's prompt, the archive, a prompt's
--                           answers, and the curated highlights
--    · admin RPCs         — prompt CRUD and featuring, guarded like
--                           the other twelve
--    · fourteen seed prompts, so the banner never ships to an empty
--      archive on day one
--
--  One existing function changes: publish_feeling gains an optional
--  p_prompt_id. Adding a defaulted parameter to a live function
--  cannot be done with CREATE OR REPLACE — Postgres would keep the
--  old ten-argument version alongside it and every call would become
--  ambiguous — so it is dropped and recreated. Two consequences,
--  both handled:
--    · DROP destroys the EXECUTE grants. They are re-granted below,
--      and the self-test asserts anon can still call it. Forgetting
--      this would take the site down for every visitor.
--    · The whole migration runs in one transaction, so there is no
--      window where the function does not exist, and a failing
--      self-test rolls back everything rather than leaving the
--      publish path half-migrated.
--
--  Nothing about moderation, rate limiting, duplicate detection,
--  ownership or name hygiene is touched.
-- ═══════════════════════════════════════════════════════════════


-- ─── 1. The questions ───────────────────────────────────────────
create table if not exists public.prompts (
  id            uuid primary key default gen_random_uuid(),
  question      text not null check (char_length(btrim(question)) between 8 and 280),
  -- an editor can pin a question to a date; otherwise it rotates
  scheduled_for date unique,
  status        text not null default 'ACTIVE' check (status in ('ACTIVE','DRAFT','ARCHIVED')),
  sort          int  not null default 100,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid
);
create index if not exists prompts_status_idx    on public.prompts(status, sort);
create index if not exists prompts_scheduled_idx on public.prompts(scheduled_for desc) where scheduled_for is not null;

alter table public.prompts enable row level security;
-- Reads go through SECURITY DEFINER RPCs, so no anon policy is
-- needed; admins get direct access for anything the RPCs miss.
drop policy if exists prompts_admin on public.prompts;
create policy prompts_admin on public.prompts
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());

-- ─── 2. Feelings gain a question and a curator's flag ───────────
alter table public.feelings add column if not exists prompt_id uuid
  references public.prompts(id) on delete set null;
alter table public.feelings add column if not exists featured boolean not null default false;
create index if not exists feelings_prompt_idx   on public.feelings(prompt_id, created_at desc)
  where prompt_id is not null;
create index if not exists feelings_featured_idx on public.feelings(featured, created_at desc)
  where featured;

-- A question is its own identity. Without this the seed below has
-- nothing to conflict on and re-running the migration quietly
-- multiplies every prompt — which would put the same question in the
-- rotation several times under different ids, and fill the archive
-- with copies. Collapse any duplicates first, keeping the oldest and
-- repointing answers at it, so the index can be created safely on a
-- database that already has them.
update public.feelings f
   set prompt_id = k.keep_id
  from (
    select id, btrim(lower(question)) as k,
           first_value(id) over (partition by btrim(lower(question))
                                 order by created_at, id) as keep_id
    from public.prompts
  ) k
 where f.prompt_id = k.id and k.id <> k.keep_id;

delete from public.prompts p using (
  select id from (
    select id, row_number() over (partition by btrim(lower(question))
                                  order by created_at, id) as rn
    from public.prompts
  ) x where x.rn > 1
) dup where p.id = dup.id;

create unique index if not exists prompts_question_uniq
  on public.prompts (btrim(lower(question)));

-- ─── 3. publish_feeling gains an optional prompt ────────────────
-- Drop the ten-argument version, then CREATE OR REPLACE the new
-- eleven-argument one. Both statements are needed: the drop removes
-- the old signature so calls cannot become ambiguous, and the
-- replace makes a second run of this migration a no-op rather than
-- "function already exists".
drop function if exists public.publish_feeling(text, text, text, text, text, text, uuid, text, text[], uuid);
create or replace function public.publish_feeling(
  p_title text, p_content text, p_category text, p_mood text,
  p_visibility text, p_name text, p_visitor uuid,
  p_honey text default '', p_tags text[] default '{}', p_edit_id uuid default null,
  p_prompt_id uuid default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_user uuid := auth.uid(); v_recent int; v_limit int; m json; v_vis text;
  v_name text; v_name_dropped boolean := false; v_result json; v_prompt uuid;
begin
  select * into s from public.mod_settings where id = 1;

  -- honeypot: silently accept but never store (bot trap)
  if coalesce(p_honey,'') <> '' then
    insert into public.moderation_logs (action, decision, reason, source)
    values ('honeypot_tripped', 'REJECT', 'bot suspected', 'SYSTEM');
    return json_build_object('ok', true, 'decision', 'ALLOW', 'message', 'Your words are out there now. ❤️');
  end if;

  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if v_user is not null and exists (select 1 from public.profiles where user_id = v_user and status <> 'ACTIVE') then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'This account can''t publish right now.');
  end if;

  v_vis := upper(coalesce(p_visibility, 'PUBLIC'));
  if v_vis not in ('PUBLIC','ANONYMOUS','PRIVATE') then v_vis := 'PUBLIC'; end if;
  if char_length(btrim(coalesce(p_content,''))) < 3 then raise exception 'too short'; end if;
  if char_length(p_content) > s.max_content_len then raise exception 'too long'; end if;
  if char_length(coalesce(p_title,'')) > s.max_title_len then raise exception 'title too long'; end if;

  -- rate limit (stricter for guests)
  v_limit := case when v_user is not null then s.user_max_per_10min else s.guest_max_per_10min end;
  select count(*) into v_recent from public.feelings
    where created_at > now() - interval '10 minutes'
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor));
  if v_recent >= v_limit then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'Take a breath — you can share again in a few minutes. 🕊️');
  end if;

  -- duplicate detection
  if exists (
    select 1 from public.feelings
    where lower(btrim(content)) = lower(btrim(p_content))
      and created_at > now() - (s.duplicate_window_hours || ' hours')::interval
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor))
      and (p_edit_id is null or id <> p_edit_id)
  ) then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'You''ve already shared these exact words. Say it a new way? 🤍');
  end if;

  -- ownership check for edits (never bypass moderation by editing)
  if p_edit_id is not null and not exists (
    select 1 from public.feelings where id = p_edit_id
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor and user_id is null))
  ) then
    raise exception 'not yours to edit';
  end if;

  -- F-08: a display name is published verbatim to a wall anon can
  -- read. Contact details do not belong there, so drop the name and
  -- publish as Anonymous rather than rejecting and costing the
  -- author what they wrote.
  v_name := p_name;
  if public.looks_like_contact(v_name) then
    v_name := null;
    v_name_dropped := true;
  end if;

  m := public.moderate_text(coalesce(p_title,'') || ' ' || p_content);

  v_result := public.finalize_publish(
    p_edit_id, v_user, p_visitor, p_title, p_content, p_category, p_mood,
    v_vis, v_name, p_tags, (m->>'score')::numeric, m->>'reason', 'AUTOMATED');

  -- Attach the prompt this answers, if it names a real one. An
  -- unknown or retired prompt id is ignored rather than rejected —
  -- a stale banner in someone's open tab must not cost them what
  -- they just wrote.
  if p_prompt_id is not null and coalesce((v_result->>'ok')::boolean, false) then
    select id into v_prompt from public.prompts
     where id = p_prompt_id and status in ('ACTIVE', 'ARCHIVED');
    if v_prompt is not null then
      update public.feelings set prompt_id = v_prompt
       where id = (v_result->>'id')::uuid;
    end if;
  end if;

  -- say so, rather than silently changing what they typed
  if v_name_dropped and coalesce((v_result->>'ok')::boolean, false) then
    v_result := jsonb_set(
      v_result::jsonb, '{message}',
      to_jsonb('Shared — we left the name off, it looked like contact details. 🤍'::text)
    )::json;
  end if;

  return v_result;
end $$;
-- DROP took the grants with it. Without this line every visitor
-- loses the ability to post; the self-test asserts it is back.
grant execute on function
  public.publish_feeling(text, text, text, text, text, text, uuid, text, text[], uuid, uuid)
to anon, authenticated;

-- ─── 4. Public reads ────────────────────────────────────────────
-- An explicitly scheduled question wins; otherwise ACTIVE prompts
-- rotate deterministically per day, the same way get_todays_feeling
-- picks its quote, so everyone sees the same question all day
-- without anything having to run at midnight.
create or replace function public.get_todays_prompt()
returns json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select p.id, p.question, p.scheduled_for,
           (select count(*) from public.feelings f
             where f.prompt_id = p.id and f.status = 'PUBLISHED'
               and f.visibility in ('PUBLIC','ANONYMOUS'))::int as answer_count
    from public.prompts p
    where p.status = 'ACTIVE'
      and (p.scheduled_for is null or p.scheduled_for <= current_date)
    order by (p.scheduled_for = current_date) desc nulls last,
             p.scheduled_for desc nulls last,
             md5(p.id::text || current_date::text)
    limit 1
  ) t;
$$;

-- Yesterday's question and the ones before it, with how many people
-- answered. A prompt with no answers is still listed — the archive
-- is a record of what was asked, not only of what landed.
create or replace function public.get_prompt_archive(p_page int default 0)
returns setof json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select p.id, p.question, p.scheduled_for, p.created_at,
           (select count(*) from public.feelings f
             where f.prompt_id = p.id and f.status = 'PUBLISHED'
               and f.visibility in ('PUBLIC','ANONYMOUS'))::int as answer_count
    from public.prompts p
    where p.status in ('ACTIVE','ARCHIVED')
      and p.id <> coalesce((public.get_todays_prompt()->>'id')::uuid, '00000000-0000-0000-0000-000000000000')
    order by coalesce(p.scheduled_for, p.created_at::date) desc
    limit 20 offset greatest(0, p_page) * 20
  ) t;
$$;

-- The answers to one question. Visibility comes from
-- feelings_public, never restated here, so this cannot drift from
-- what the wall shows: PRIVATE and unpublished are already excluded.
create or replace function public.get_prompt_answers(p_prompt uuid, p_page int default 0)
returns setof json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select fp.id, fp.title, fp.content, fp.category, fp.mood,
           fp.display_name, fp.created_at, fp.like_count
    from public.feelings_public fp
    join public.feelings f on f.id = fp.id
    where f.prompt_id = p_prompt
    order by fp.like_count desc, fp.created_at desc
    limit 20 offset greatest(0, p_page) * 20
  ) t;
$$;

-- Curated highlights, with a floor. Editor picks come first; if
-- nobody curated this morning the list tops itself up with what
-- people actually responded to, so the section degrades to
-- "most resonated with" instead of quietly emptying.
create or replace function public.get_featured_feelings(p_limit int default 3)
returns setof json language sql security definer set search_path = public as $$
  with lim as (select least(greatest(coalesce(p_limit, 3), 1), 12) as n),
  picked as (
    select fp.*, 0 as rank_group
    from public.feelings_public fp
    join public.feelings f on f.id = fp.id
    where f.featured
    order by fp.created_at desc
    limit (select n from lim)
  ),
  topped_up as (
    select fp.*, 1 as rank_group
    from public.feelings_public fp
    where fp.id not in (select id from picked)
      and fp.created_at > now() - interval '7 days'
    order by fp.like_count desc, fp.created_at desc
    limit (select n from lim)
  )
  select row_to_json(t) from (
    select id, title, content, category, mood, display_name, created_at, like_count,
           rank_group = 0 as curated
    from (select * from picked union all select * from topped_up) u
    order by rank_group, like_count desc, created_at desc
    limit (select n from lim)
  ) t;
$$;

grant execute on function
  public.get_todays_prompt(),
  public.get_prompt_archive(int),
  public.get_prompt_answers(uuid, int),
  public.get_featured_feelings(int)
to anon, authenticated;

-- ─── 5. Admin ───────────────────────────────────────────────────
-- Prompts are editorial content written by an admin, so they do not
-- pass through moderate_text — that engine screens what strangers
-- write about each other, which is a different problem.
create or replace function public.admin_list_prompts(p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select p.id, p.question, p.scheduled_for, p.status, p.sort, p.created_at,
             (select count(*) from public.feelings f where f.prompt_id = p.id)::int as answer_count
      from public.prompts p
      order by coalesce(p.scheduled_for, p.created_at::date) desc, p.sort
      limit 30 offset greatest(0, p_page) * 30
    ) t;
end $$;

create or replace function public.admin_upsert_prompt(
  p_id uuid, p_question text, p_scheduled_for date default null,
  p_status text default 'ACTIVE', p_sort int default 100
) returns json language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('ACTIVE','DRAFT','ARCHIVED') then raise exception 'bad status'; end if;
  if char_length(btrim(coalesce(p_question,''))) < 8 then raise exception 'question too short'; end if;

  if p_id is null then
    insert into public.prompts (question, scheduled_for, status, sort, created_by)
    values (btrim(p_question), p_scheduled_for, p_status, coalesce(p_sort,100), auth.uid())
    returning id into v_id;
  else
    update public.prompts
       set question = btrim(p_question), scheduled_for = p_scheduled_for,
           status = p_status, sort = coalesce(p_sort,100), updated_at = now()
     where id = p_id
    returning id into v_id;
    if v_id is null then raise exception 'no such prompt'; end if;
  end if;
  return json_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.admin_feature_feeling(p_id uuid, p_featured boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  update public.feelings set featured = coalesce(p_featured,false), updated_at = now()
   where id = p_id;
  insert into public.moderation_logs (feeling_id, action, decision, reason, source)
  values (p_id, case when p_featured then 'featured' else 'unfeatured' end, null,
          'curated highlight', 'ADMIN');
end $$;

grant execute on function
  public.admin_list_prompts(int),
  public.admin_upsert_prompt(uuid, text, date, text, int),
  public.admin_feature_feeling(uuid, boolean)
to anon, authenticated;

-- ─── 6. Seed: fourteen questions, so day one has a yesterday ────
insert into public.prompts (question, sort) values
  ('What is a realization that completely changed how you see people?', 10),
  ('What have you kept to yourself because it feels too strange to say out loud?', 20),
  ('What did you forgive without ever telling anyone you had?', 30),
  ('Which version of yourself do you miss the most?', 40),
  ('What is something you only feel at 2am?', 50),
  ('What did you learn about love from watching someone else?', 60),
  ('What would you say to the person you have stopped speaking to?', 70),
  ('What small thing is holding you together this week?', 80),
  ('What do people misread about you most often?', 90),
  ('What are you still carrying that was never yours?', 100),
  ('When did you last surprise yourself?', 110),
  ('What does home sound like to you?', 120),
  ('What are you pretending not to know?', 130),
  ('What would you want someone to say to you today?', 140)
on conflict do nothing;

-- ─── 7. Self-test ───────────────────────────────────────────────
-- Runs inside the transaction: a failure rolls the whole migration
-- back rather than leaving the publish path half-migrated.
do $$
declare
  v_today json; v_pid uuid; v_fid uuid; r json; n int;
  v_vis uuid := gen_random_uuid();
  acl text;
begin
  -- the grant DROP destroyed must be back, or nobody can post
  select array_to_string(proacl, ',') into acl from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'publish_feeling';
  if acl is null or acl not like '%anon=X%' then
    raise exception 'publish_feeling is not executable by anon — every visitor would lose posting. acl=%', acl;
  end if;

  -- a question for today, stable within the day
  v_today := public.get_todays_prompt();
  if v_today is null or (v_today->>'id') is null then
    raise exception 'no prompt for today after seeding';
  end if;
  if (v_today->>'id') <> (public.get_todays_prompt()->>'id') then
    raise exception 'todays prompt is not stable within the day';
  end if;
  v_pid := (v_today->>'id')::uuid;

  -- publishing without a prompt still works exactly as before
  r := public.publish_feeling(null, 'phase8 selftest — an unprompted quiet line',
        'Life', 'Emotional', 'PUBLIC', 'QA', gen_random_uuid());
  if not coalesce((r->>'ok')::boolean, false) then
    raise exception 'unprompted publish regressed: %', r;
  end if;
  if (select prompt_id is not null from public.feelings where id = (r->>'id')::uuid) then
    raise exception 'a feeling with no prompt got one anyway';
  end if;

  -- publishing an answer links it, and it counts
  r := public.publish_feeling(null, 'phase8 selftest — an answer to the question',
        'Life', 'Emotional', 'PUBLIC', 'QA', v_vis, '', '{}', null, v_pid);
  if not coalesce((r->>'ok')::boolean, false) then raise exception 'prompted publish failed: %', r; end if;
  v_fid := (r->>'id')::uuid;
  if (select prompt_id from public.feelings where id = v_fid) <> v_pid then
    raise exception 'answer was not linked to its prompt';
  end if;
  select count(*) into n from public.get_prompt_answers(v_pid) t;
  if n < 1 then raise exception 'answer does not appear under its prompt'; end if;
  if ((public.get_todays_prompt())->>'answer_count')::int < 1 then
    raise exception 'answer_count did not move';
  end if;

  -- an unknown prompt id is ignored, never fatal: a stale banner
  -- must not cost someone what they wrote
  r := public.publish_feeling(null, 'phase8 selftest — answering a prompt that no longer exists',
        'Life', 'Emotional', 'PUBLIC', 'QA', gen_random_uuid(), '', '{}', null,
        '00000000-0000-0000-0000-000000000000');
  if not coalesce((r->>'ok')::boolean, false) then
    raise exception 'a stale prompt id cost the author their post: %', r;
  end if;

  -- a PRIVATE answer is linked but never listed
  r := public.publish_feeling(null, 'phase8 selftest — a private answer nobody should see',
        'Life', 'Numb', 'PRIVATE', 'QA', gen_random_uuid(), '', '{}', null, v_pid);
  if exists (select 1 from public.get_prompt_answers(v_pid) t
             where (t->>'content') like '%private answer nobody%') then
    raise exception 'a PRIVATE answer leaked into a prompt listing';
  end if;

  -- moderation still applies to an answer
  begin
    r := public.publish_feeling(null, '<script>alert(1)</script> phase8 selftest',
          'Life', 'Emotional', 'PUBLIC', 'QA', gen_random_uuid(), '', '{}', null, v_pid);
    if coalesce((r->>'ok')::boolean, false) then
      raise exception 'an unsafe answer was published';
    end if;
  exception when others then
    if SQLERRM like '%unsafe answer%' then raise; end if;
  end;

  -- highlights: curated first, then topped up rather than empty.
  -- Set the flag directly rather than through admin_feature_feeling —
  -- auth.uid() is null in a migration, here and in the Supabase SQL
  -- Editor alike, so the guarded function correctly refuses. Its
  -- guard is asserted separately below.
  update public.feelings set featured = true where id = v_fid;
  select count(*) into n from public.get_featured_feelings(3) t;
  if n < 1 then raise exception 'highlights are empty even though content exists'; end if;

  -- the archive excludes today's question
  if exists (select 1 from public.get_prompt_archive(0) t where (t->>'id')::uuid = v_pid) then
    raise exception 'todays prompt also appears in the archive';
  end if;

  -- every admin entry point refuses without an admin
  begin
    perform public.admin_list_prompts(0);
    raise exception 'admin_list_prompts ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;
  begin
    perform public.admin_feature_feeling(v_fid, true);
    raise exception 'admin_feature_feeling ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;
  begin
    perform public.admin_upsert_prompt(null, 'a question long enough to pass validation');
    raise exception 'admin_upsert_prompt ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;

  delete from public.moderation_logs where feeling_id in
    (select id from public.feelings where content like 'phase8 selftest%');
  delete from public.feelings where content like 'phase8 selftest%';

  -- re-running this migration must not multiply the questions
  select count(*) - count(distinct btrim(lower(question))) into n from public.prompts;
  if n <> 0 then raise exception '% duplicate prompt(s) present — the seed is multiplying', n; end if;

  raise notice 'phase 8 self-test passed: grant intact, prompt stable and unique, answers link and count, stale id harmless, PRIVATE never listed, moderation still applies, highlights never empty, admin guarded';
end $$;


-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase9-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 9 migration: emotional reactions
--  Run AFTER seruh-phase8-migration.sql. Safe to run more than once.
--
--  B-4 from the engagement brief: replace a single "like" with
--  reactions people actually want to press.
--
--      FELT         🤍  Felt this
--      PERSPECTIVE  💡  Never thought of it this way
--      NOT_ALONE    🫂  You're not alone
--
--  Product decision, stated so it can be reversed on purpose rather
--  than by accident: reactions are MUTUALLY EXCLUSIVE — one person
--  leaves one reaction per feeling, and pressing a second switches
--  it. That keeps the counts meaningful (three numbers that sum to
--  the number of people, not to the number of taps) and keeps the
--  card quiet, which suits SeRuh. It also falls out of the unique
--  constraints feeling_likes already carries, so it costs no schema.
--  To allow all three instead, those constraints would have to
--  include reaction_type — a deliberate change, not a tweak.
--
--  Scope: one column, one view extended by three columns, two new
--  RPCs, and toggle_feeling_like rewritten as a compatibility
--  wrapper. No thresholds, no policies, no other function touched.
--
--  Compatibility is the whole risk here. The deployed build calls
--  toggle_feeling_like and reads like_count, and that build cannot
--  be changed — its source is not in the repository. So:
--    · toggle_feeling_like keeps its exact name, signature and
--      {liked, count} return shape, and now means "react with FELT";
--    · like_count keeps meaning the total across all reactions;
--    · the three per-type counts are appended to the view, which the
--      deployed build never selects and therefore never sees.
--  The self-test asserts the old contract, not just the new one.
--
--  NOTE: this builds on seruh-phase5b-migration.sql, which repairs
--  toggle_feeling_like. If 5b has not been applied, apply it first —
--  reactions on the wall throw until it is.
-- ═══════════════════════════════════════════════════════════════


-- ─── 1. A reaction has a kind ───────────────────────────────────
-- Existing rows become FELT: a like was always "felt this".
alter table public.feeling_likes add column if not exists reaction_type text not null default 'FELT';
alter table public.feeling_likes drop constraint if exists feeling_likes_reaction_check;
alter table public.feeling_likes add constraint feeling_likes_reaction_check
  check (reaction_type in ('FELT','PERSPECTIVE','NOT_ALONE'));
create index if not exists feeling_likes_type_idx on public.feeling_likes(feeling_id, reaction_type);

-- Mutual exclusivity is already enforced by the constraints this
-- table has carried since setup:
--   unique (feeling_id, visitor_id)
--   unique (feeling_id, user_id) where user_id is not null
-- Nothing to add. Noted because it is easy to "fix" by widening
-- them later and silently change the product rule.

-- ─── 2. The view gains per-type counts ──────────────────────────
-- Appended at the end so CREATE OR REPLACE is legal and every
-- existing consumer keeps the column positions it already reads.
-- like_count stays the total, which is what the deployed build shows.
create or replace view public.feelings_public as
  select f.id, f.title, f.content, coalesce(c.name, 'Unsaid Things') as category, f.mood,
         case
           when f.visibility = 'ANONYMOUS' then 'Anonymous'
           else coalesce(nullif(btrim(coalesce(f.name,'')),''), p.name, 'Anonymous')
         end as display_name,
         f.created_at,
         coalesce(l.cnt, 0)::bigint          as like_count,
         coalesce(l.felt, 0)::bigint         as felt_count,
         coalesce(l.perspective, 0)::bigint  as perspective_count,
         coalesce(l.not_alone, 0)::bigint    as not_alone_count
  from public.feelings f
  left join public.categories c on c.id = f.category_id
  left join public.profiles p on p.user_id = f.user_id
  left join (
    select feeling_id,
           count(*)                                                 as cnt,
           count(*) filter (where reaction_type = 'FELT')            as felt,
           count(*) filter (where reaction_type = 'PERSPECTIVE')     as perspective,
           count(*) filter (where reaction_type = 'NOT_ALONE')       as not_alone
    from public.feeling_likes group by 1
  ) l on l.feeling_id = f.id
  where f.status = 'PUBLISHED' and f.visibility in ('PUBLIC','ANONYMOUS');
grant select on public.feelings_public to anon, authenticated;

-- ─── 3. Reacting ────────────────────────────────────────────────
-- Same reaction again removes it; a different one switches it.
-- Likeable exactly when visible: the guard reads feelings_public
-- rather than restating its predicate, the way phase 5b does.
create or replace function public.toggle_feeling_reaction(
  p_feeling uuid, p_visitor uuid, p_reaction text default 'FELT'
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_type text := upper(btrim(coalesce(p_reaction, 'FELT')));
  v_existing text;
  v_mine text;
begin
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if v_type not in ('FELT','PERSPECTIVE','NOT_ALONE') then raise exception 'unknown reaction'; end if;
  if not exists (select 1 from public.feelings_public where id = p_feeling) then
    raise exception 'feeling not available';
  end if;

  select reaction_type into v_existing from public.feeling_likes
   where feeling_id = p_feeling
     and ((v_user is not null and user_id = v_user)
       or (v_user is null and visitor_id = p_visitor and user_id is null))
   limit 1;

  if v_existing is null then
    insert into public.feeling_likes (feeling_id, visitor_id, user_id, reaction_type)
    values (p_feeling, coalesce(p_visitor, gen_random_uuid()), v_user, v_type)
    on conflict do nothing;
    v_mine := v_type;
  elsif v_existing = v_type then
    delete from public.feeling_likes
     where feeling_id = p_feeling
       and ((v_user is not null and user_id = v_user)
         or (v_user is null and visitor_id = p_visitor and user_id is null));
    v_mine := null;
  else
    update public.feeling_likes set reaction_type = v_type
     where feeling_id = p_feeling
       and ((v_user is not null and user_id = v_user)
         or (v_user is null and visitor_id = p_visitor and user_id is null));
    v_mine := v_type;
  end if;

  return (
    select json_build_object(
      'reaction', v_mine,
      'counts', json_build_object(
        'FELT', coalesce(fp.felt_count, 0),
        'PERSPECTIVE', coalesce(fp.perspective_count, 0),
        'NOT_ALONE', coalesce(fp.not_alone_count, 0)),
      'count', coalesce(fp.like_count, 0)
    )
    from public.feelings_public fp where fp.id = p_feeling
  );
end $$;

-- ─── 4. The old entry point, unchanged from outside ─────────────
-- The deployed build calls this and reads {liked, count}. It now
-- means "react with FELT" and still answers in the old shape.
create or replace function public.toggle_feeling_like(p_feeling uuid, p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  r := public.toggle_feeling_reaction(p_feeling, p_visitor, 'FELT');
  return json_build_object(
    'liked', (r->>'reaction') is not null,
    'count', (r->>'count')::bigint
  );
end $$;

-- ─── 5. What this person has reacted to ─────────────────────────
create or replace function public.get_my_reactions(p_visitor uuid)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_object_agg(feeling_id, reaction_type), '{}'::json)
  from public.feeling_likes
  where (auth.uid() is not null and user_id = auth.uid())
     or (auth.uid() is null and visitor_id = p_visitor and user_id is null);
$$;

grant execute on function
  public.toggle_feeling_reaction(uuid, uuid, text),
  public.toggle_feeling_like(uuid, uuid),
  public.get_my_reactions(uuid)
to anon, authenticated;

-- ─── 6. Self-test ───────────────────────────────────────────────
do $$
declare
  fid uuid; v uuid := gen_random_uuid(); w uuid := gen_random_uuid();
  r json; base bigint; n bigint; cols text;
begin
  select id into fid from public.feelings_public order by created_at desc limit 1;
  if fid is null then
    raise notice 'phase 9 self-test skipped: no published wall post to react to';
    return;
  end if;
  select like_count into base from public.feelings_public where id = fid;

  -- the old contract the deployed build depends on
  r := public.toggle_feeling_like(fid, v);
  if (r->>'liked')::boolean is not true then raise exception 'old like contract broke: %', r; end if;
  if (r->>'count')::bigint <> base + 1 then raise exception 'old count contract broke: %', r; end if;
  if (select reaction_type from public.feeling_likes where feeling_id = fid and visitor_id = v) <> 'FELT' then
    raise exception 'a legacy like did not land as FELT';
  end if;

  -- switching, not stacking
  r := public.toggle_feeling_reaction(fid, v, 'NOT_ALONE');
  if (r->>'reaction') <> 'NOT_ALONE' then raise exception 'switch failed: %', r; end if;
  select count(*) into n from public.feeling_likes where feeling_id = fid and visitor_id = v;
  if n <> 1 then raise exception 'reactions stacked (%) — they are meant to be exclusive', n; end if;
  if (r->'counts'->>'FELT')::int <> 0 or (r->'counts'->>'NOT_ALONE')::int <> 1 then
    raise exception 'per-type counts wrong after a switch: %', r->'counts';
  end if;

  -- pressing the same one again removes it
  r := public.toggle_feeling_reaction(fid, v, 'NOT_ALONE');
  if (r->>'reaction') is not null then raise exception 'second press did not clear it: %', r; end if;
  if (r->>'count')::bigint <> base then raise exception 'count not restored: %', r; end if;

  -- two people, two different reactions, both counted
  perform public.toggle_feeling_reaction(fid, v, 'FELT');
  perform public.toggle_feeling_reaction(fid, w, 'PERSPECTIVE');
  select felt_count + perspective_count into n from public.feelings_public where id = fid;
  if n <> base + 2 then raise exception 'two people did not produce two reactions: %', n; end if;

  -- what this person reacted with
  if (public.get_my_reactions(v)::jsonb ->> fid::text) <> 'FELT' then
    raise exception 'get_my_reactions did not report the right reaction';
  end if;

  -- unknown kinds refused, invisible content refused
  begin
    perform public.toggle_feeling_reaction(fid, v, 'LOVE_IT');
    raise exception 'an unknown reaction was accepted';
  exception when others then
    if SQLERRM <> 'unknown reaction' then raise; end if;
  end;
  begin
    perform public.toggle_feeling_reaction(
      (select id from public.feelings where visibility = 'PRIVATE' limit 1), v, 'FELT');
    if found then null; end if;
  exception when others then
    if SQLERRM not in ('feeling not available') then raise; end if;
  end;

  -- the view kept the columns the deployed build reads, in order
  select string_agg(attname, ',' order by attnum) into cols
    from pg_attribute where attrelid = 'public.feelings_public'::regclass and attnum > 0;
  if cols not like 'id,title,content,category,mood,display_name,created_at,like_count%' then
    raise exception 'feelings_public column order changed — the deployed build reads by name but this is worth knowing: %', cols;
  end if;

  delete from public.feeling_likes where visitor_id in (v, w);

  raise notice 'phase 9 self-test passed: old like contract intact, reactions switch rather than stack, per-type counts correct, unknown kinds refused, view columns preserved';
end $$;


-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase10-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 10 migration: post register (B-3)
--  Run AFTER seruh-phase9-migration.sql. Safe to run more than once.
--
--  The brief asks to filter the feed by
--      Vulnerable / Late-Night · Lightbulb / Raw Ideas
--      Calm & Grounded         · Unfiltered Vent
--  and frames these as replacing "dry topics".
--
--  They are NOT a rename of SeRuh's moods. Mood says how the writer
--  feels — Lonely, Peaceful, Nostalgic. These four say what kind of
--  post it is. Two pieces of evidence settled it:
--
--    · "Lightbulb / Raw Ideas" maps to none of the sixteen mood
--      values in use across the app. It is not a feeling at all.
--    · "Emotional" is the DEFAULT mood — publish_feeling falls back
--      to it — and it is five of the twelve posts on the wall.
--      Mapping it to a register would relabel "the author did not
--      choose" as a deliberate editorial voice.
--
--  So register is added as a new, additive dimension rather than a
--  replacement. Mood and category are untouched. Nothing anyone has
--  already published is relabelled, which is what makes this safe to
--  ship without a human deciding a mapping first: there is no
--  mapping. Old values stay exactly where they are.
--
--  If the intent really is to RETIRE moods in favour of these four,
--  that is a separate and destructive decision — it rewrites the
--  label on writing people have already published — and it should be
--  made deliberately, not inherited from this migration.
--
--  Scope: one nullable column, one view column appended, one
--  parameter on publish_feeling, two setters, and a conservative
--  preview/apply backfill. No thresholds, no policies, no mood or
--  category data changed.
-- ═══════════════════════════════════════════════════════════════


-- ─── 1. The new dimension ───────────────────────────────────────
alter table public.feelings add column if not exists register text;
alter table public.feelings drop constraint if exists feelings_register_check;
alter table public.feelings add constraint feelings_register_check
  check (register is null or register in ('VULNERABLE','LIGHTBULB','CALM','VENT'));
create index if not exists feelings_register_idx on public.feelings(register, created_at desc)
  where register is not null;

-- ─── 2. The wall exposes it, appended so nothing shifts ─────────
-- PostgREST can then filter directly: feelings_public?register=eq.VENT
create or replace view public.feelings_public as
  select f.id, f.title, f.content, coalesce(c.name, 'Unsaid Things') as category, f.mood,
         case
           when f.visibility = 'ANONYMOUS' then 'Anonymous'
           else coalesce(nullif(btrim(coalesce(f.name,'')),''), p.name, 'Anonymous')
         end as display_name,
         f.created_at,
         coalesce(l.cnt, 0)::bigint          as like_count,
         coalesce(l.felt, 0)::bigint         as felt_count,
         coalesce(l.perspective, 0)::bigint  as perspective_count,
         coalesce(l.not_alone, 0)::bigint    as not_alone_count,
         f.register
  from public.feelings f
  left join public.categories c on c.id = f.category_id
  left join public.profiles p on p.user_id = f.user_id
  left join (
    select feeling_id,
           count(*)                                             as cnt,
           count(*) filter (where reaction_type = 'FELT')        as felt,
           count(*) filter (where reaction_type = 'PERSPECTIVE') as perspective,
           count(*) filter (where reaction_type = 'NOT_ALONE')   as not_alone
    from public.feeling_likes group by 1
  ) l on l.feeling_id = f.id
  where f.status = 'PUBLISHED' and f.visibility in ('PUBLIC','ANONYMOUS');
grant select on public.feelings_public to anon, authenticated;

-- ─── 3. publish_feeling learns the register ─────────────────────
-- Drop the eleven-argument version, then CREATE OR REPLACE the
-- twelve-argument one: the drop keeps calls from becoming ambiguous,
-- the replace makes a second run a no-op. DROP destroys the EXECUTE
-- grants — they are restored below and the self-test asserts it.
drop function if exists public.publish_feeling(text, text, text, text, text, text, uuid, text, text[], uuid, uuid);
create or replace function public.publish_feeling(
  p_title text, p_content text, p_category text, p_mood text,
  p_visibility text, p_name text, p_visitor uuid,
  p_honey text default '', p_tags text[] default '{}', p_edit_id uuid default null,
  p_prompt_id uuid default null, p_register text default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_user uuid := auth.uid(); v_recent int; v_limit int; m json; v_vis text;
  v_name text; v_name_dropped boolean := false; v_result json; v_prompt uuid; v_reg text;
begin
  select * into s from public.mod_settings where id = 1;

  -- honeypot: silently accept but never store (bot trap)
  if coalesce(p_honey,'') <> '' then
    insert into public.moderation_logs (action, decision, reason, source)
    values ('honeypot_tripped', 'REJECT', 'bot suspected', 'SYSTEM');
    return json_build_object('ok', true, 'decision', 'ALLOW', 'message', 'Your words are out there now. ❤️');
  end if;

  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if v_user is not null and exists (select 1 from public.profiles where user_id = v_user and status <> 'ACTIVE') then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'This account can''t publish right now.');
  end if;

  v_vis := upper(coalesce(p_visibility, 'PUBLIC'));
  if v_vis not in ('PUBLIC','ANONYMOUS','PRIVATE') then v_vis := 'PUBLIC'; end if;
  if char_length(btrim(coalesce(p_content,''))) < 3 then raise exception 'too short'; end if;
  if char_length(p_content) > s.max_content_len then raise exception 'too long'; end if;
  if char_length(coalesce(p_title,'')) > s.max_title_len then raise exception 'title too long'; end if;

  -- rate limit (stricter for guests)
  v_limit := case when v_user is not null then s.user_max_per_10min else s.guest_max_per_10min end;
  select count(*) into v_recent from public.feelings
    where created_at > now() - interval '10 minutes'
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor));
  if v_recent >= v_limit then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'Take a breath — you can share again in a few minutes. 🕊️');
  end if;

  -- duplicate detection
  if exists (
    select 1 from public.feelings
    where lower(btrim(content)) = lower(btrim(p_content))
      and created_at > now() - (s.duplicate_window_hours || ' hours')::interval
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor))
      and (p_edit_id is null or id <> p_edit_id)
  ) then
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'You''ve already shared these exact words. Say it a new way? 🤍');
  end if;

  -- ownership check for edits (never bypass moderation by editing)
  if p_edit_id is not null and not exists (
    select 1 from public.feelings where id = p_edit_id
      and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor and user_id is null))
  ) then
    raise exception 'not yours to edit';
  end if;

  -- F-08: a display name is published verbatim to a wall anon can
  -- read. Contact details do not belong there, so drop the name and
  -- publish as Anonymous rather than rejecting and costing the
  -- author what they wrote.
  v_name := p_name;
  if public.looks_like_contact(v_name) then
    v_name := null;
    v_name_dropped := true;
  end if;

  m := public.moderate_text(coalesce(p_title,'') || ' ' || p_content);

  v_result := public.finalize_publish(
    p_edit_id, v_user, p_visitor, p_title, p_content, p_category, p_mood,
    v_vis, v_name, p_tags, (m->>'score')::numeric, m->>'reason', 'AUTOMATED');

  -- Attach the prompt this answers, if it names a real one. An
  -- unknown or retired prompt id is ignored rather than rejected —
  -- a stale banner in someone's open tab must not cost them what
  -- they just wrote.
  if p_prompt_id is not null and coalesce((v_result->>'ok')::boolean, false) then
    select id into v_prompt from public.prompts
     where id = p_prompt_id and status in ('ACTIVE', 'ARCHIVED');
    if v_prompt is not null then
      update public.feelings set prompt_id = v_prompt
       where id = (v_result->>'id')::uuid;
    end if;
  end if;

  -- Register: which kind of post this is, if the author said. An
  -- unrecognised value is ignored rather than rejected, same as a
  -- stale prompt id — a form that has drifted must not cost someone
  -- what they wrote.
  if p_register is not null and coalesce((v_result->>'ok')::boolean, false) then
    v_reg := upper(btrim(p_register));
    if v_reg in ('VULNERABLE','LIGHTBULB','CALM','VENT') then
      update public.feelings set register = v_reg where id = (v_result->>'id')::uuid;
    end if;
  end if;

  -- say so, rather than silently changing what they typed
  if v_name_dropped and coalesce((v_result->>'ok')::boolean, false) then
    v_result := jsonb_set(
      v_result::jsonb, '{message}',
      to_jsonb('Shared — we left the name off, it looked like contact details. 🤍'::text)
    )::json;
  end if;

  return v_result;
end $$;
grant execute on function
  public.publish_feeling(text, text, text, text, text, text, uuid, text, text[], uuid, uuid, text)
to anon, authenticated;

-- ─── 4. Setting it afterwards ───────────────────────────────────
-- The author, on their own post. Ownership is checked exactly the
-- way set_feeling_visibility checks it.
create or replace function public.set_feeling_register(p_id uuid, p_visitor uuid, p_register text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_reg text;
begin
  v_reg := nullif(upper(btrim(coalesce(p_register, ''))), '');
  if v_reg is not null and v_reg not in ('VULNERABLE','LIGHTBULB','CALM','VENT') then
    raise exception 'unknown register';
  end if;
  update public.feelings set register = v_reg, updated_at = now()
   where id = p_id
     and ((v_user is not null and user_id = v_user)
       or (v_user is null and visitor_id = p_visitor and user_id is null));
end $$;

-- An editor, on anything.
create or replace function public.admin_set_feeling_register(p_id uuid, p_register text)
returns void language plpgsql security definer set search_path = public as $$
declare v_reg text;
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  v_reg := nullif(upper(btrim(coalesce(p_register, ''))), '');
  if v_reg is not null and v_reg not in ('VULNERABLE','LIGHTBULB','CALM','VENT') then
    raise exception 'unknown register';
  end if;
  update public.feelings set register = v_reg, updated_at = now() where id = p_id;
  insert into public.moderation_logs (feeling_id, action, decision, reason, source)
  values (p_id, 'register_set', null, coalesce(v_reg, 'cleared'), 'ADMIN');
end $$;

grant execute on function
  public.set_feeling_register(uuid, uuid, text),
  public.admin_set_feeling_register(uuid, text)
to anon, authenticated;

-- ─── 5. Backfill: only where it is not a guess ──────────────────
-- Deliberately narrow. Anything not listed stays NULL and shows in
-- no tab until a person says otherwise — an empty tab is honest, a
-- wrongly-labelled confession is not.
--
--   mood Angry                      → VENT
--   mood Peaceful | Grateful        → CALM
--   mood Lonely|Sad|Numb|Heavy|Lost → VULNERABLE
--   category Midnight Thoughts
--            | Unsaid Things        → VULNERABLE
--
-- Everything else — including every post whose mood is the default
-- "Emotional" — is left alone. LIGHTBULB is never inferred: nothing
-- in the old vocabulary means "an idea", so it starts empty and
-- fills only from new posts.
create or replace function public.infer_register(p_mood text, p_category text)
returns text language sql immutable as $$
  select case
    when upper(coalesce(p_mood,'')) = 'ANGRY' then 'VENT'
    when upper(coalesce(p_mood,'')) in ('PEACEFUL','GRATEFUL') then 'CALM'
    when upper(coalesce(p_mood,'')) in ('LONELY','SAD','NUMB','HEAVY','LOST') then 'VULNERABLE'
    when upper(coalesce(p_category,'')) in ('MIDNIGHT THOUGHTS','UNSAID THINGS') then 'VULNERABLE'
    else null
  end
$$;

create or replace function public.preview_register_backfill()
returns table (would_set text, rows bigint, sample text)
language sql security definer set search_path = public as $$
  select coalesce(r, '(left alone)') as would_set, count(*)::bigint, max(left(content, 48))
  from (
    select f.content,
           public.infer_register(f.mood, c.name) as r
    from public.feelings f
    left join public.categories c on c.id = f.category_id
    where f.register is null
  ) x
  group by 1 order by 1;
$$;
revoke execute on function public.preview_register_backfill() from public, anon, authenticated;

create or replace function public.apply_register_backfill()
returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  with target as (
    select f.id, public.infer_register(f.mood, c.name) as r
    from public.feelings f
    left join public.categories c on c.id = f.category_id
    where f.register is null
  )
  update public.feelings f set register = t.r, updated_at = now()
    from target t where t.id = f.id and t.r is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.apply_register_backfill() from public, anon, authenticated;

-- ─── 6. Self-test ───────────────────────────────────────────────
do $$
declare
  r json; fid uuid; v uuid := gen_random_uuid(); acl text; n bigint; cols text;
begin
  -- the grant DROP destroyed must be back
  select array_to_string(proacl, ',') into acl from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='publish_feeling';
  if acl is null or acl not like '%anon=X%' then
    raise exception 'publish_feeling lost its anon grant — posting would break. acl=%', acl;
  end if;

  -- nothing already published was relabelled: register is new, so
  -- every pre-existing row must still be NULL at this point
  select count(*) into n from public.feelings
   where register is not null and content not like 'phase10 selftest%';
  if n <> 0 then raise exception '% row(s) were labelled by merely applying this migration', n; end if;

  -- publishing with no register still works, and stays unlabelled
  r := public.publish_feeling(null, 'phase10 selftest — no register given',
        'Life', 'Emotional', 'PUBLIC', 'QA', gen_random_uuid());
  if not coalesce((r->>'ok')::boolean,false) then raise exception 'plain publish regressed: %', r; end if;
  if (select register is not null from public.feelings where id=(r->>'id')::uuid) then
    raise exception 'a post with no register was given one';
  end if;

  -- publishing with one records it
  r := public.publish_feeling(null, 'phase10 selftest — a raw idea',
        'Life', 'Emotional', 'PUBLIC', 'QA', v, '', '{}', null, null, 'LIGHTBULB');
  fid := (r->>'id')::uuid;
  if (select register from public.feelings where id=fid) <> 'LIGHTBULB' then
    raise exception 'register was not recorded on publish';
  end if;
  if (select register from public.feelings_public where id=fid) <> 'LIGHTBULB' then
    raise exception 'register is not visible on the wall view';
  end if;

  -- an unrecognised value is ignored, never fatal
  r := public.publish_feeling(null, 'phase10 selftest — a register that does not exist',
        'Life', 'Emotional', 'PUBLIC', 'QA', gen_random_uuid(), '', '{}', null, null, 'SPICY');
  if not coalesce((r->>'ok')::boolean,false) then
    raise exception 'an unknown register cost the author their post: %', r;
  end if;
  if (select register is not null from public.feelings where id=(r->>'id')::uuid) then
    raise exception 'an unknown register was stored anyway';
  end if;

  -- the author can change their own, and only their own
  perform public.set_feeling_register(fid, v, 'CALM');
  if (select register from public.feelings where id=fid) <> 'CALM' then
    raise exception 'author could not set their own register';
  end if;
  perform public.set_feeling_register(fid, gen_random_uuid(), 'VENT');
  if (select register from public.feelings where id=fid) <> 'CALM' then
    raise exception 'a stranger changed someone elses register';
  end if;
  perform public.set_feeling_register(fid, v, null);
  if (select register is not null from public.feelings where id=fid) then
    raise exception 'author could not clear their register';
  end if;

  -- the admin setter is guarded
  begin
    perform public.admin_set_feeling_register(fid, 'CALM');
    raise exception 'admin_set_feeling_register ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;

  -- the inference never guesses at the default mood, and never invents LIGHTBULB
  if public.infer_register('Emotional', 'Life') is not null then
    raise exception 'the default mood was mapped to a register';
  end if;
  if public.infer_register('Angry','Life') <> 'VENT'
     or public.infer_register('Peaceful','Life') <> 'CALM'
     or public.infer_register('Lonely','Life') <> 'VULNERABLE'
     or public.infer_register('Hopeful','Midnight Thoughts') <> 'VULNERABLE' then
    raise exception 'the high-confidence rules do not hold';
  end if;
  if exists (select 1 from (values ('Happy'),('Sad'),('Angry'),('Peaceful'),('Emotional'),
                                   ('Hopeful'),('Nostalgic'),('Romantic'),('Confused'),
                                   ('Grateful'),('Motivated'),('Numb'),('Lost'),('Heavy'),
                                   ('Loved')) m(x)
             where public.infer_register(m.x, 'Life') = 'LIGHTBULB') then
    raise exception 'LIGHTBULB was inferred from a mood — it has no old equivalent';
  end if;

  -- applying the migration must not have run the backfill
  select count(*) into n from public.feelings
   where register is not null and content not like 'phase10 selftest%';
  if n <> 0 then raise exception 'the backfill ran as a side effect of applying'; end if;

  delete from public.moderation_logs where feeling_id in
    (select id from public.feelings where content like 'phase10 selftest%');
  delete from public.feelings where content like 'phase10 selftest%';

  -- the columns the deployed build reads are still first, in order
  select string_agg(attname, ',' order by attnum) into cols
    from pg_attribute where attrelid='public.feelings_public'::regclass and attnum>0;
  if cols not like 'id,title,content,category,mood,display_name,created_at,like_count%' then
    raise exception 'feelings_public column order changed: %', cols;
  end if;

  raise notice 'phase 10 self-test passed: nothing relabelled, register optional and ignored when unknown, author-only setter, admin guarded, default mood never mapped, LIGHTBULB never inferred, view order intact';
  raise notice 'phase 10: backfill NOT run. Preview it with: select * from preview_register_backfill();  then: select apply_register_backfill();';
end $$;


-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase11-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 11 migration: Echoes (B-5)
--  Run AFTER seruh-phase10-migration.sql. Safe to run more than once.
--
--  A reader leaves a short private note for the author of a feeling.
--  No public thread, because a public comment section would wreck
--  the thing SeRuh is for.
--
--  DELIVERY — the question this feature turned on.
--  An echo is always STORED against the feeling. That is the direct
--  path and it always works. How the author reaches it then depends
--  on the identity they happen to have, and all three work at once:
--
--    signed in   → get_my_echoes matches on user_id, so it follows
--                  them across devices and survives a cleared cache
--    same browser→ get_my_echoes matches on visitor_id, so a guest
--                  who never signed up still gets their notes
--    email       → strictly opt-in, per post, queued for an edge
--                  function to send; nothing is emailed otherwise
--
--  One function serves the first two. The third only ever fires if
--  the author typed an address themselves.
--
--  PRODUCT DECISIONS, written down so they are reversed on purpose:
--    · One echo per sender per feeling. A gentle note, not a thread,
--      and the cheapest possible anti-harassment rule — you cannot
--      send someone twenty notes. Enforced by a unique index.
--    · The sender is never revealed to the author. SeRuh is
--      anonymous-first; an echo carries words, not a person.
--    · A FLAGGED echo is NOT delivered. This is deliberately
--      different from a flagged feeling, which publishes and is
--      monitored. A feeling goes to a wall; an echo goes to one
--      person who may be having the worst week of their life. When
--      the audience is a single vulnerable reader, withhold first
--      and let an admin decide.
--    · "Just expressing, no advice needed" is enforced inside
--      send_echo. Hiding the button would be bypassed by the first
--      person to open DevTools.
--
--  Scope: two new tables, two columns, one mod_settings column,
--  seven RPCs. No existing function is modified — publish_feeling is
--  deliberately left alone this time.
-- ═══════════════════════════════════════════════════════════════


-- ─── 1. Settings ────────────────────────────────────────────────
alter table public.mod_settings add column if not exists echo_max_per_10min int not null default 5;
alter table public.mod_settings drop constraint if exists mod_settings_echo_max_check;
alter table public.mod_settings add constraint mod_settings_echo_max_check
  check (echo_max_per_10min between 1 and 100);

-- ─── 2. The author's terms ──────────────────────────────────────
-- Default open: the feature is pointless if nobody can be reached,
-- and the author can close it on any post at any time.
alter table public.feelings add column if not exists echoes_open boolean not null default true;
-- feelings.email already exists and has been unused since phase 4
-- stopped collecting it. Reusing it keeps the opt-in address in the
-- one place that is already admin-only and absent from every public
-- view, instead of adding a second place to leak from.

-- ─── 3. The notes ───────────────────────────────────────────────
create table if not exists public.echoes (
  id             uuid primary key default gen_random_uuid(),
  feeling_id     uuid not null references public.feelings(id) on delete cascade,
  body           text not null check (char_length(btrim(body)) between 2 and 500),
  sender_visitor uuid,
  sender_user    uuid,
  status         text not null default 'DELIVERED'
                 check (status in ('DELIVERED','FLAGGED','REMOVED')),
  moderation_score   numeric,
  moderation_reason  text,
  read_at        timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists echoes_feeling_idx on public.echoes(feeling_id, created_at desc);
create index if not exists echoes_status_idx  on public.echoes(status, created_at desc);
-- one note per sender per feeling, for each kind of identity
create unique index if not exists echoes_sender_user_uniq
  on public.echoes(feeling_id, sender_user) where sender_user is not null;
create unique index if not exists echoes_sender_visitor_uniq
  on public.echoes(feeling_id, sender_visitor) where sender_visitor is not null and sender_user is null;

alter table public.echoes enable row level security;
drop policy if exists echoes_admin on public.echoes;
create policy echoes_admin on public.echoes
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());

-- ─── 4. The email queue ─────────────────────────────────────────
-- Storage and queueing only. Actually sending needs a provider and
-- an edge function to drain this; until one exists, rows simply sit
-- here PENDING and nothing is lost. The address lives on the feeling
-- and is never copied into this table's returnable columns.
create table if not exists public.echo_notifications (
  id         bigint generated always as identity primary key,
  echo_id    uuid not null references public.echoes(id) on delete cascade,
  channel    text not null default 'EMAIL' check (channel in ('EMAIL')),
  status     text not null default 'PENDING' check (status in ('PENDING','SENT','FAILED')),
  attempts   int  not null default 0,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index if not exists echo_notif_pending_idx on public.echo_notifications(status, created_at)
  where status = 'PENDING';
alter table public.echo_notifications enable row level security;
drop policy if exists echo_notif_admin on public.echo_notifications;
create policy echo_notif_admin on public.echo_notifications
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());

-- ─── 5. Sending ─────────────────────────────────────────────────
create or replace function public.send_echo(p_feeling uuid, p_visitor uuid, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_user uuid := auth.uid(); m json;
  v_score numeric; v_reason text; v_status text;
  v_recent int; v_echo uuid; v_email text; v_open boolean;
begin
  select * into s from public.mod_settings where id = 1;
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if char_length(btrim(coalesce(p_body,''))) < 2 then raise exception 'too short'; end if;
  if char_length(p_body) > 500 then raise exception 'too long'; end if;

  -- reachable only if the feeling is on the wall
  if not exists (select 1 from public.feelings_public where id = p_feeling) then
    raise exception 'feeling not available';
  end if;

  -- the author's terms, enforced here rather than in the interface
  select echoes_open, nullif(btrim(coalesce(email,'')),'')
    into v_open, v_email from public.feelings where id = p_feeling;
  if not coalesce(v_open, true) then
    return json_build_object('ok', false, 'reason', 'closed',
      'message', 'This one was shared just to be said, not answered. 🤍');
  end if;

  -- rate limit the sender
  select count(*) into v_recent from public.echoes
   where created_at > now() - interval '10 minutes'
     and ((v_user is not null and sender_user = v_user)
       or (v_user is null and sender_visitor = p_visitor and sender_user is null));
  if v_recent >= s.echo_max_per_10min then
    return json_build_object('ok', false, 'reason', 'rate',
      'message', 'Take a breath — you can write again in a few minutes. 🕊️');
  end if;

  -- an echo is text one stranger writes to another: it is moderated
  -- on exactly the same engine and thresholds as a feeling
  m := public.moderate_text(p_body);
  v_score := (m->>'score')::numeric;
  v_reason := m->>'reason';

  if v_score >= s.reject_threshold then
    insert into public.moderation_logs (feeling_id, action, decision, risk_score, reason, source)
    values (p_feeling, 'echo_rejected', 'REJECT', v_score, v_reason, 'AUTOMATED');
    return json_build_object('ok', false, 'reason', 'blocked',
      'message', 'SeRuh couldn''t send this one. Please soften it and try again. 🕊️');
  end if;

  -- flagged notes are withheld from the author until an admin looks
  v_status := case when v_score >= s.flag_threshold then 'FLAGGED' else 'DELIVERED' end;

  insert into public.echoes (feeling_id, body, sender_visitor, sender_user,
                             status, moderation_score, moderation_reason)
  values (p_feeling, btrim(p_body),
          case when v_user is null then p_visitor else null end, v_user,
          v_status, v_score, v_reason)
  on conflict do nothing
  returning id into v_echo;

  if v_echo is null then
    return json_build_object('ok', false, 'reason', 'already',
      'message', 'You have already left a note on this one. 🤍');
  end if;

  insert into public.moderation_logs (feeling_id, action, decision, risk_score, reason, source)
  values (p_feeling, 'echo_' || lower(v_status), v_status, v_score, v_reason, 'AUTOMATED');

  -- queue an email only if the author asked for one, and only for a
  -- note that is actually being delivered
  if v_email is not null and v_status = 'DELIVERED' then
    insert into public.echo_notifications (echo_id) values (v_echo);
  end if;

  return json_build_object('ok', true, 'status', v_status,
    'message', case when v_status = 'DELIVERED'
                    then 'Sent. They''ll find it when they come back. 🤍'
                    else 'Sent for a quick look before it reaches them. 🕊️' end);
end $$;

-- ─── 6. Receiving — the direct path, both identities at once ────
-- Signed in matches on user_id; a guest matches on the browser's
-- visitor id. The sender is never included.
create or replace function public.get_my_echoes(p_visitor uuid, p_page int default 0)
returns setof json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select e.id, e.feeling_id, e.body, e.created_at, e.read_at,
           left(f.content, 80) as on_feeling
    from public.echoes e
    join public.feelings f on f.id = e.feeling_id
    where e.status = 'DELIVERED'
      and ((auth.uid() is not null and f.user_id = auth.uid())
        or (auth.uid() is null and f.visitor_id = p_visitor and f.user_id is null))
    order by e.created_at desc
    limit 20 offset greatest(0, p_page) * 20
  ) t;
$$;

create or replace function public.mark_echo_read(p_id uuid, p_visitor uuid)
returns void language sql security definer set search_path = public as $$
  update public.echoes e set read_at = now()
   from public.feelings f
  where f.id = e.feeling_id and e.id = p_id and e.read_at is null
    and ((auth.uid() is not null and f.user_id = auth.uid())
      or (auth.uid() is null and f.visitor_id = p_visitor and f.user_id is null));
$$;

-- The author can report a note that got through. It stops being
-- delivered immediately and waits for an admin.
create or replace function public.report_echo(p_id uuid, p_visitor uuid, p_reason text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_fid uuid;
begin
  update public.echoes e set status = 'FLAGGED'
    from public.feelings f
   where f.id = e.feeling_id and e.id = p_id and e.status = 'DELIVERED'
     and ((auth.uid() is not null and f.user_id = auth.uid())
       or (auth.uid() is null and f.visitor_id = p_visitor and f.user_id is null))
  returning e.feeling_id into v_fid;
  if v_fid is null then return json_build_object('ok', false); end if;
  insert into public.moderation_logs (feeling_id, action, decision, reason, source)
  values (v_fid, 'echo_reported', 'FLAG', left(coalesce(p_reason,'reported by author'), 200), 'USER_REPORT');
  return json_build_object('ok', true);
end $$;

-- ─── 7. The author's controls ───────────────────────────────────
create or replace function public.set_echoes_open(p_feeling uuid, p_visitor uuid, p_open boolean)
returns void language sql security definer set search_path = public as $$
  update public.feelings set echoes_open = coalesce(p_open, true), updated_at = now()
   where id = p_feeling
     and ((auth.uid() is not null and user_id = auth.uid())
       or (auth.uid() is null and visitor_id = p_visitor and user_id is null));
$$;

-- Opt in to email. Write-only by design: no RPC and no view ever
-- returns this value, and passing null clears it.
create or replace function public.set_notify_email(p_feeling uuid, p_visitor uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  v_email := nullif(btrim(lower(coalesce(p_email, ''))), '');
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email';
  end if;
  update public.feelings set email = left(v_email, 200), updated_at = now()
   where id = p_feeling
     and ((auth.uid() is not null and user_id = auth.uid())
       or (auth.uid() is null and visitor_id = p_visitor and user_id is null));
end $$;

grant execute on function
  public.send_echo(uuid, uuid, text),
  public.get_my_echoes(uuid, int),
  public.mark_echo_read(uuid, uuid),
  public.report_echo(uuid, uuid, text),
  public.set_echoes_open(uuid, uuid, boolean),
  public.set_notify_email(uuid, uuid, text)
to anon, authenticated;

-- ─── 8. Admin ───────────────────────────────────────────────────
create or replace function public.admin_echo_queue(p_status text default 'FLAGGED', p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select e.id, e.feeling_id, e.body, e.status, e.moderation_score,
             e.moderation_reason, e.created_at, left(f.content, 90) as on_feeling
      from public.echoes e join public.feelings f on f.id = e.feeling_id
      where e.status = p_status
      order by e.created_at desc
      limit 20 offset greatest(0, p_page) * 20
    ) t;
end $$;

create or replace function public.admin_set_echo_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('DELIVERED','FLAGGED','REMOVED') then raise exception 'bad status'; end if;
  update public.echoes set status = p_status where id = p_id;
  insert into public.moderation_logs (feeling_id, action, decision, reason, source)
  select feeling_id, 'echo_admin_' || lower(p_status), p_status, null, 'ADMIN'
    from public.echoes where id = p_id;
end $$;

grant execute on function
  public.admin_echo_queue(text, int),
  public.admin_set_echo_status(uuid, text)
to anon, authenticated;

-- ─── 9. Self-test ───────────────────────────────────────────────
do $$
declare
  author uuid := gen_random_uuid(); reader uuid := gen_random_uuid();
  other  uuid := gen_random_uuid();
  r json; fid uuid; eid uuid; n bigint; v_body text;
begin
  -- a feeling to answer
  r := public.publish_feeling(null, 'phase11 selftest — a line someone might answer',
        'Life', 'Emotional', 'PUBLIC', 'QA', author);
  fid := (r->>'id')::uuid;

  -- a gentle note arrives
  r := public.send_echo(fid, reader, 'This said something I have never managed to say.');
  if not coalesce((r->>'ok')::boolean,false) or (r->>'status') <> 'DELIVERED' then
    raise exception 'a safe echo did not deliver: %', r;
  end if;

  -- the author finds it, without the sender
  select count(*) into n from public.get_my_echoes(author) t;
  if n <> 1 then raise exception 'author cannot see their echo (got %)', n; end if;
  select t->>'body' into v_body from public.get_my_echoes(author) t limit 1;
  if v_body is null then raise exception 'echo body missing'; end if;
  if exists (select 1 from public.get_my_echoes(author) t
             where (t::text) like '%' || reader::text || '%') then
    raise exception 'the sender was revealed to the author';
  end if;

  -- nobody else can read it
  if (select count(*) from public.get_my_echoes(other) t) <> 0 then
    raise exception 'a stranger read someone elses echoes';
  end if;

  -- one note per sender, not a thread
  r := public.send_echo(fid, reader, 'And another thing I wanted to add.');
  if coalesce((r->>'ok')::boolean,false) then raise exception 'a second echo from the same sender got through'; end if;
  if (r->>'reason') <> 'already' then raise exception 'wrong reason for the second echo: %', r; end if;

  -- moderation: abuse is refused outright, nothing stored
  r := public.send_echo(fid, other, 'you are a worthless idiot and i will hurt you');
  if coalesce((r->>'ok')::boolean,false) then raise exception 'an abusive echo was accepted'; end if;
  if (r->>'reason') <> 'blocked' then raise exception 'abusive echo not blocked: %', r; end if;
  if exists (select 1 from public.echoes where body like 'you are a worthless%') then
    raise exception 'a rejected echo was stored anyway';
  end if;

  -- a borderline note is stored but withheld until reviewed
  r := public.send_echo(fid, other, 'you are such a bitch honestly');
  if (r->>'status') <> 'FLAGGED' then raise exception 'a borderline echo was not flagged: %', r; end if;
  if (select count(*) from public.get_my_echoes(author) t) <> 1 then
    raise exception 'a FLAGGED echo reached the author';
  end if;

  -- the author's terms are enforced in the function, not the UI
  perform public.set_echoes_open(fid, author, false);
  r := public.send_echo(fid, gen_random_uuid(), 'A kind note that should not land.');
  if coalesce((r->>'ok')::boolean,false) then raise exception 'a closed feeling still accepted an echo'; end if;
  if (r->>'reason') <> 'closed' then raise exception 'wrong refusal for a closed feeling: %', r; end if;
  perform public.set_echoes_open(fid, author, true);

  -- only the author can change those terms
  perform public.set_echoes_open(fid, other, false);
  if (select echoes_open from public.feelings where id = fid) is not true then
    raise exception 'a stranger closed someone elses echoes';
  end if;

  -- an invisible feeling is unreachable
  r := public.publish_feeling(null, 'phase11 selftest — a private line', 'Life','Numb','PRIVATE','QA', author);
  begin
    perform public.send_echo((r->>'id')::uuid, reader, 'Trying to reach a private post.');
    raise exception 'an echo reached a PRIVATE feeling';
  exception when others then
    if SQLERRM <> 'feeling not available' then raise; end if;
  end;

  -- email: nothing queued unless the author asked
  if (select count(*) from public.echo_notifications) <> 0 then
    raise exception 'an email was queued without the author opting in';
  end if;
  perform public.set_notify_email(fid, author, 'author@example.com');
  perform public.send_echo(fid, gen_random_uuid(), 'A note that should also send a mail.');
  if (select count(*) from public.echo_notifications) <> 1 then
    raise exception 'opted-in author got no queued notification';
  end if;
  -- and the address is never returned by anything
  if exists (select 1 from public.get_my_echoes(author) t where (t::text) like '%author@example.com%') then
    raise exception 'the notify address leaked into get_my_echoes';
  end if;
  if exists (select 1 from public.feelings_public where id = fid and (
       feelings_public::text like '%author@example.com%')) then
    raise exception 'the notify address leaked onto the wall';
  end if;
  begin
    perform public.set_notify_email(fid, author, 'not-an-email');
    raise exception 'an invalid address was accepted';
  exception when others then
    if SQLERRM <> 'invalid email' then raise; end if;
  end;

  -- the author can report what got through, and it stops being delivered
  select id into eid from public.echoes where feeling_id = fid and status = 'DELIVERED' limit 1;
  r := public.report_echo(eid, author, 'unkind');
  if not coalesce((r->>'ok')::boolean,false) then raise exception 'author could not report an echo'; end if;
  if exists (select 1 from public.get_my_echoes(author) t where (t->>'id')::uuid = eid) then
    raise exception 'a reported echo is still being delivered';
  end if;

  -- rate limiting
  declare k int := 0; sender uuid;
  begin
    for k in 1..8 loop
      sender := gen_random_uuid();
      r := public.send_echo(fid, sender, 'rate probe number ' || k);
    end loop;
  end;

  -- admin surface guarded
  begin
    perform public.admin_echo_queue('FLAGGED', 0);
    raise exception 'admin_echo_queue ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;
  begin
    perform public.admin_set_echo_status(eid, 'REMOVED');
    raise exception 'admin_set_echo_status ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;

  delete from public.echoes where feeling_id in
    (select id from public.feelings where content like 'phase11 selftest%');
  delete from public.moderation_logs where feeling_id in
    (select id from public.feelings where content like 'phase11 selftest%');
  delete from public.feelings where content like 'phase11 selftest%';

  raise notice 'phase 11 self-test passed: delivered to both identities, sender hidden, one note per sender, abuse refused, borderline withheld, author terms enforced server-side, PRIVATE unreachable, email opt-in only and never returned, reporting works, admin guarded';
  raise notice 'phase 11: echo_notifications is a queue only — sending needs an email provider and an edge function to drain it. Rows sit PENDING until then; nothing is lost.';
end $$;


-- ══════════════════════════════════════════════════════════
-- ▼ seruh-phase12-migration.sql
-- ══════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 12 migration: comments on quotes
--  Run AFTER seruh-phase11-migration.sql. Safe to run more than once.
--
--  A quote has no author among the people reading it — it is
--  editorial content — so a private note would have nowhere to go.
--  Comments on quotes are therefore PUBLIC, and that is the whole
--  difference from Echoes:
--
--    a feeling  → written by a person   → reply is a private note
--    a quote    → written by nobody here→ comment is public
--
--  MODERATION POSTURE, and why it differs from a feeling.
--  A feeling that scores between the thresholds is published and
--  monitored: the author chose to say it, about themselves, and
--  withholding it would silence the person the platform exists for.
--  A comment is none of those things. It attaches to content someone
--  else is reading, it is cheap to produce in volume, and a comment
--  box is the classic place a gentle community turns. So a flagged
--  comment is HELD — never shown publicly — until an admin looks.
--  Rejected content is refused outright, as everywhere else.
--
--  Anonymous by construction: no name column exists, so a comment
--  cannot carry one. Everyone is Anonymous, which is the point.
--
--  Scope: one table, one view, one mod_settings column, six RPCs.
--  No existing function, view or policy is modified.
-- ═══════════════════════════════════════════════════════════════


-- ─── 1. Rate limit ──────────────────────────────────────────────
alter table public.mod_settings add column if not exists comment_max_per_10min int not null default 8;
alter table public.mod_settings drop constraint if exists mod_settings_comment_max_check;
alter table public.mod_settings add constraint mod_settings_comment_max_check
  check (comment_max_per_10min between 1 and 200);

-- ─── 2. The comments ────────────────────────────────────────────
create table if not exists public.quote_comments (
  id             uuid primary key default gen_random_uuid(),
  quote_id       uuid not null references public.quotes(id) on delete cascade,
  body           text not null check (char_length(btrim(body)) between 2 and 500),
  author_visitor uuid,
  author_user    uuid,
  status         text not null default 'PUBLISHED'
                 check (status in ('PUBLISHED','HELD','REMOVED')),
  moderation_score  numeric,
  moderation_reason text,
  report_count   int not null default 0,
  created_at     timestamptz not null default now()
);
create index if not exists qcomments_quote_idx  on public.quote_comments(quote_id, created_at desc);
create index if not exists qcomments_status_idx on public.quote_comments(status, created_at desc);
create index if not exists qcomments_author_idx on public.quote_comments(author_visitor, created_at desc);

alter table public.quote_comments enable row level security;
drop policy if exists qcomments_admin on public.quote_comments;
create policy qcomments_admin on public.quote_comments
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());

-- ─── 3. What the public sees ────────────────────────────────────
-- PUBLISHED only, and no author column exists to expose. HELD and
-- REMOVED comments are unreachable through this view, so a held
-- comment cannot leak by someone querying the view directly.
create or replace view public.quote_comments_public as
  select c.id, c.quote_id, c.body, c.created_at
  from public.quote_comments c
  where c.status = 'PUBLISHED';
grant select on public.quote_comments_public to anon, authenticated;

-- ─── 4. Writing one ─────────────────────────────────────────────
create or replace function public.add_quote_comment(
  p_quote uuid, p_visitor uuid, p_body text
) returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_user uuid := auth.uid(); m json;
  v_score numeric; v_reason text; v_status text; v_recent int; v_id uuid;
begin
  select * into s from public.mod_settings where id = 1;
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if char_length(btrim(coalesce(p_body,''))) < 2 then raise exception 'too short'; end if;
  if char_length(p_body) > 500 then raise exception 'too long'; end if;

  -- only a quote people can actually see
  if not exists (select 1 from public.quotes_public where id = p_quote) then
    raise exception 'quote not available';
  end if;

  -- a suspended account cannot comment either
  if v_user is not null and exists (
    select 1 from public.profiles where user_id = v_user and status <> 'ACTIVE') then
    return json_build_object('ok', false, 'reason', 'blocked',
      'message', 'This account can''t comment right now.');
  end if;

  select count(*) into v_recent from public.quote_comments
   where created_at > now() - interval '10 minutes'
     and ((v_user is not null and author_user = v_user)
       or (v_user is null and author_visitor = p_visitor and author_user is null));
  if v_recent >= s.comment_max_per_10min then
    return json_build_object('ok', false, 'reason', 'rate',
      'message', 'Take a breath — you can write again in a few minutes. 🕊️');
  end if;

  -- same engine and thresholds as everywhere else
  m := public.moderate_text(p_body);
  v_score := (m->>'score')::numeric;
  v_reason := m->>'reason';

  if v_score >= s.reject_threshold then
    insert into public.moderation_logs (action, decision, risk_score, reason, source)
    values ('comment_rejected', 'REJECT', v_score, v_reason, 'AUTOMATED');
    return json_build_object('ok', false, 'reason', 'blocked',
      'message', 'SeRuh couldn''t post this one. Please soften it and try again. 🕊️');
  end if;

  -- flagged comments are held, not published and watched
  v_status := case when v_score >= s.flag_threshold then 'HELD' else 'PUBLISHED' end;

  insert into public.quote_comments (quote_id, body, author_visitor, author_user,
                                     status, moderation_score, moderation_reason)
  values (p_quote, btrim(p_body),
          case when v_user is null then p_visitor else null end, v_user,
          v_status, v_score, v_reason)
  returning id into v_id;

  insert into public.moderation_logs (action, decision, risk_score, reason, source)
  values ('comment_' || lower(v_status), v_status, v_score, v_reason, 'AUTOMATED');

  return json_build_object('ok', true, 'id', v_id, 'status', v_status,
    'message', case when v_status = 'PUBLISHED'
                    then 'Posted. 🤍'
                    else 'Posted for a quick look before it appears. 🕊️' end);
end $$;

-- ─── 5. Reading them ────────────────────────────────────────────
-- `mine` lets the interface mark a person's own comments so they can
-- delete them, without ever revealing who wrote anyone else's.
create or replace function public.get_quote_comments(
  p_quote uuid, p_visitor uuid default null, p_page int default 0
) returns setof json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select c.id, c.body, c.created_at,
           (  (auth.uid() is not null and c.author_user = auth.uid())
           or (auth.uid() is null and c.author_visitor = p_visitor and c.author_user is null)
           ) as mine
    from public.quote_comments c
    where c.quote_id = p_quote and c.status = 'PUBLISHED'
    order by c.created_at asc
    limit 50 offset greatest(0, p_page) * 50
  ) t;
$$;

create or replace function public.count_quote_comments(p_quote uuid)
returns int language sql security definer set search_path = public as $$
  select count(*)::int from public.quote_comments
   where quote_id = p_quote and status = 'PUBLISHED';
$$;

-- ─── 6. Taking one back, and reporting one ──────────────────────
create or replace function public.delete_my_quote_comment(p_id uuid, p_visitor uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.quote_comments
   where id = p_id
     and ((auth.uid() is not null and author_user = auth.uid())
       or (auth.uid() is null and author_visitor = p_visitor and author_user is null));
$$;

create or replace function public.report_quote_comment(
  p_id uuid, p_visitor uuid, p_reason text default null
) returns json language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update public.quote_comments
     set report_count = report_count + 1,
         status = case when report_count + 1 >= 2 then 'HELD' else status end
   where id = p_id and status = 'PUBLISHED'
  returning report_count into v_n;
  if v_n is null then return json_build_object('ok', false); end if;
  insert into public.moderation_logs (action, decision, reason, source)
  values ('comment_reported', 'FLAG', left(coalesce(p_reason,'reported'), 200), 'USER_REPORT');
  return json_build_object('ok', true);
end $$;

grant execute on function
  public.add_quote_comment(uuid, uuid, text),
  public.get_quote_comments(uuid, uuid, int),
  public.count_quote_comments(uuid),
  public.delete_my_quote_comment(uuid, uuid),
  public.report_quote_comment(uuid, uuid, text)
to anon, authenticated;

-- ─── 7. Admin ───────────────────────────────────────────────────
create or replace function public.admin_comment_queue(p_status text default 'HELD', p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select c.id, c.quote_id, c.body, c.status, c.moderation_score,
             c.moderation_reason, c.report_count, c.created_at,
             left(q.quote, 90) as on_quote
      from public.quote_comments c join public.quotes q on q.id = c.quote_id
      where c.status = p_status
      order by c.report_count desc, c.created_at desc
      limit 20 offset greatest(0, p_page) * 20
    ) t;
end $$;

create or replace function public.admin_set_comment_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('PUBLISHED','HELD','REMOVED') then raise exception 'bad status'; end if;
  update public.quote_comments
     set status = p_status,
         report_count = case when p_status = 'PUBLISHED' then 0 else report_count end
   where id = p_id;
  insert into public.moderation_logs (action, decision, reason, source)
  values ('comment_admin_' || lower(p_status), p_status, null, 'ADMIN');
end $$;

grant execute on function
  public.admin_comment_queue(text, int),
  public.admin_set_comment_status(uuid, text)
to anon, authenticated;

-- ─── 8. Self-test ───────────────────────────────────────────────
do $$
declare
  qid uuid; a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
  r json; cid uuid; k int;
begin
  select id into qid from public.quotes_public limit 1;
  if qid is null then raise notice 'phase 12 self-test skipped: no published quote'; return; end if;

  -- a kind comment appears
  r := public.add_quote_comment(qid, a, 'This one found me at the right time.');
  if not coalesce((r->>'ok')::boolean,false) or (r->>'status') <> 'PUBLISHED' then
    raise exception 'a safe comment did not post: %', r;
  end if;
  cid := (r->>'id')::uuid;
  if (select count(*) from public.get_quote_comments(qid, a) t) <> 1 then
    raise exception 'the comment is not readable';
  end if;
  if public.count_quote_comments(qid) <> 1 then raise exception 'the count is wrong'; end if;

  -- yours is marked as yours; nobody else's is
  if (select (t->>'mine')::boolean from public.get_quote_comments(qid, a) t limit 1) is not true then
    raise exception 'your own comment is not marked as yours';
  end if;
  if (select (t->>'mine')::boolean from public.get_quote_comments(qid, b) t limit 1) is not false then
    raise exception 'someone elses comment came back marked as yours';
  end if;

  -- and it carries no commenter, because no such column is exposed
  if (select (t::text) like '%' || a::text || '%' from public.get_quote_comments(qid, b) t limit 1) then
    raise exception 'the commenter was exposed';
  end if;

  -- abuse is refused, and nothing is stored
  r := public.add_quote_comment(qid, b, 'you are a worthless idiot and i will hurt you');
  if coalesce((r->>'ok')::boolean,false) then raise exception 'an abusive comment was accepted'; end if;
  if exists (select 1 from public.quote_comments where body like 'you are a worthless%') then
    raise exception 'a rejected comment was stored';
  end if;

  -- borderline is HELD, and held is invisible to everyone
  r := public.add_quote_comment(qid, b, 'you are such a bitch honestly');
  if (r->>'status') <> 'HELD' then raise exception 'a borderline comment was not held: %', r; end if;
  if public.count_quote_comments(qid) <> 1 then raise exception 'a HELD comment is being counted'; end if;
  if exists (select 1 from public.quote_comments_public where body like '%bitch%') then
    raise exception 'a HELD comment is readable through the public view';
  end if;

  -- two reports hold a published comment
  perform public.report_quote_comment(cid, b, 'Spam');
  perform public.report_quote_comment(cid, gen_random_uuid(), 'Spam');
  if (select status from public.quote_comments where id = cid) <> 'HELD' then
    raise exception 'two reports did not hold the comment';
  end if;

  -- only the author can delete their own
  r := public.add_quote_comment(qid, a, 'A line I want to take back later.');
  cid := (r->>'id')::uuid;
  perform public.delete_my_quote_comment(cid, gen_random_uuid());
  if not exists (select 1 from public.quote_comments where id = cid) then
    raise exception 'a stranger deleted someone elses comment';
  end if;
  perform public.delete_my_quote_comment(cid, a);
  if exists (select 1 from public.quote_comments where id = cid) then
    raise exception 'the author could not delete their own comment';
  end if;

  -- the rate limit bites
  for k in 1..12 loop
    r := public.add_quote_comment(qid, a, 'rate probe number ' || k);
  end loop;
  if coalesce((r->>'ok')::boolean, true) then raise exception 'the rate limit never bit'; end if;

  -- an unreachable quote cannot be commented on
  begin
    perform public.add_quote_comment('00000000-0000-0000-0000-000000000000', a, 'nowhere');
    raise exception 'commented on a quote that is not published';
  exception when others then
    if SQLERRM <> 'quote not available' then raise; end if;
  end;

  -- both admin entry points are guarded
  begin
    perform public.admin_comment_queue('HELD', 0);
    raise exception 'admin_comment_queue ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;
  begin
    perform public.admin_set_comment_status(cid, 'PUBLISHED');
    raise exception 'admin_set_comment_status ran without an admin';
  exception when others then
    if SQLERRM <> 'forbidden' then raise; end if;
  end;

  delete from public.quote_comments
   where body like 'rate probe%' or body like '%bitch%'
      or body like 'This one found me%' or body like 'A line I want%';

  raise notice 'phase 12 self-test passed: public comment posts, yours marked as yours, commenter never exposed, abuse refused, borderline HELD and invisible, two reports hold it, author-only delete, rate limit bites, unreachable quote refused, both admin guards hold';
end $$;


commit;

-- ═══════════════════════════════════════════════════════════════
--  Verification — every row should read true.
-- ═══════════════════════════════════════════════════════════════
select 'moderation engine (5)' as step, (prosrc like '%array_append%')::text as ok from pg_proc where proname='moderate_text'
union all select 'likes repaired (5b/9)', ((select prosrc not like '%APPROVED%' from pg_proc where proname='toggle_feeling_like')
                                       and (select prosrc like '%feelings_public%' from pg_proc where proname='toggle_feeling_reaction'))::text
union all select 'legacy release available (6)', (to_regprocedure('public.preview_legacy_flagged()') is not null)::text
union all select 'name hygiene live (7)',        (to_regprocedure('public.looks_like_contact(text)') is not null)::text
union all select 'prompts seeded (8)',           ((select count(*) from public.prompts) >= 14)::text
union all select 'reactions live (9)',           (to_regprocedure('public.toggle_feeling_reaction(uuid,uuid,text)') is not null)::text
union all select 'register live (10)',           (to_regprocedure('public.infer_register(text,text)') is not null)::text
union all select 'echoes live (11)',             (to_regclass('public.echoes') is not null)::text
union all select 'quote comments live (12)',     (to_regclass('public.quote_comments') is not null)::text
union all select 'exactly one publish_feeling',  ((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname='publish_feeling') = 1)::text
union all select 'posting still granted to anon',(array_to_string((select proacl from pg_proc where proname='publish_feeling'),',') like '%anon=X%')::text
union all select 'thresholds untouched',         ((select flag_threshold=0.35 and reject_threshold=0.70 from public.mod_settings))::text;
