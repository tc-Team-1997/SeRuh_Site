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

begin;

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

commit;
