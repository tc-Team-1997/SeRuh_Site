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

begin;

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

commit;
