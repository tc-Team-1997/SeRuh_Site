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
