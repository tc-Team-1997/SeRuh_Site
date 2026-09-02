-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 4 migration: Direct Publishing & Automated Moderation
--  Run AFTER seruh-setup.sql and seruh-phase3-migration.sql.
--
--  What changes:
--   • Feelings publish IMMEDIATELY (no admin approval step).
--   • An automated moderation engine (spam / abuse / injection /
--     duplicate / rate-limit checks) screens every submission.
--   • Visibility: PUBLIC / ANONYMOUS / PRIVATE.
--   • New status model: PUBLISHED / FLAGGED / REMOVED / ARCHIVED /
--     UNDER_REVIEW  (old PENDING→FLAGGED, APPROVED→PUBLISHED,
--     REJECTED→REMOVED — nothing is deleted).
--   • User reports, moderation logs, configurable thresholds,
--     user suspend/restore. Admin reviews only exceptions.
-- ═══════════════════════════════════════════════════════════════

-- ─── 1. Moderation settings (admin-configurable) ────────────────

create table if not exists public.mod_settings (
  id                     int primary key default 1 check (id = 1),
  flag_threshold         numeric not null default 0.35 check (flag_threshold between 0 and 1),
  reject_threshold       numeric not null default 0.70 check (reject_threshold between 0 and 1),
  user_max_per_10min     int not null default 5  check (user_max_per_10min between 1 and 100),
  guest_max_per_10min    int not null default 3  check (guest_max_per_10min between 1 and 100),
  duplicate_window_hours int not null default 24 check (duplicate_window_hours between 1 and 720),
  max_content_len        int not null default 1000,
  max_title_len          int not null default 120,
  updated_at             timestamptz not null default now()
);
insert into public.mod_settings (id) values (1) on conflict (id) do nothing;
alter table public.mod_settings enable row level security;
create policy mod_settings_admin on public.mod_settings
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());

-- ─── 2. Feelings table: new columns + status/visibility model ───

alter table public.feelings add column if not exists title text check (char_length(title) <= 200);
alter table public.feelings add column if not exists visibility text not null default 'PUBLIC';
alter table public.feelings add column if not exists tags text[] not null default '{}';
alter table public.feelings add column if not exists moderation_score numeric;
alter table public.feelings add column if not exists moderation_decision text;
alter table public.feelings add column if not exists moderation_reason text;
alter table public.feelings add column if not exists report_count int not null default 0;
alter table public.feelings add column if not exists published_at timestamptz;
alter table public.feelings add column if not exists removed_at timestamptz;

-- migrate old lifecycle → new one (no data deleted)
alter table public.feelings drop constraint if exists feelings_status_check;
update public.feelings set status = 'PUBLISHED', published_at = coalesce(updated_at, created_at)
  where status = 'APPROVED';
update public.feelings set status = 'FLAGGED' where status = 'PENDING';
update public.feelings set status = 'REMOVED', removed_at = now() where status = 'REJECTED';
alter table public.feelings add constraint feelings_status_check
  check (status in ('PUBLISHED','FLAGGED','REMOVED','ARCHIVED','UNDER_REVIEW'));

update public.feelings set visibility = case when is_anonymous then 'ANONYMOUS' else 'PUBLIC' end
  where visibility = 'PUBLIC';
alter table public.feelings drop constraint if exists feelings_visibility_check;
alter table public.feelings add constraint feelings_visibility_check
  check (visibility in ('PUBLIC','ANONYMOUS','PRIVATE'));

create index if not exists feelings_wall_idx on public.feelings(status, visibility, created_at desc);
create index if not exists feelings_reports_idx on public.feelings(report_count desc);

-- ─── 3. Reports + moderation logs ───────────────────────────────

create table if not exists public.content_reports (
  id               uuid primary key default gen_random_uuid(),
  feeling_id       uuid not null references public.feelings(id) on delete cascade,
  reporter_user    uuid,
  reporter_visitor uuid,
  reason           text not null check (reason in
    ('Spam','Harassment / Abuse','Hate or Discrimination','Threatening Content',
     'Inappropriate Content','Copyright Concern','Other')),
  description      text check (char_length(description) <= 500),
  status           text not null default 'OPEN' check (status in ('OPEN','INVESTIGATING','RESOLVED','DISMISSED')),
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz,
  resolved_by      uuid,
  resolution       text
);
create unique index if not exists reports_user_uniq on public.content_reports(feeling_id, reporter_user)
  where reporter_user is not null;
create unique index if not exists reports_visitor_uniq on public.content_reports(feeling_id, reporter_visitor)
  where reporter_visitor is not null and reporter_user is null;
create index if not exists reports_status_idx on public.content_reports(status, created_at desc);
alter table public.content_reports enable row level security;
create policy reports_admin on public.content_reports
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());

create table if not exists public.moderation_logs (
  id         bigint generated always as identity primary key,
  feeling_id uuid,
  action     text not null,
  decision   text,
  risk_score numeric,
  reason     text,
  source     text not null default 'AUTOMATED' check (source in ('AUTOMATED','USER_REPORT','ADMIN','SYSTEM')),
  created_at timestamptz not null default now()
);
create index if not exists modlogs_time_idx on public.moderation_logs(created_at desc);
alter table public.moderation_logs enable row level security;
create policy modlogs_admin on public.moderation_logs
  for select to authenticated using (public.am_i_admin());

-- ─── 4. Automated moderation engine (heuristics, server-side) ───

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
    score := score + 0.95; cats := cats || 'malicious';
  elsif t ~ '<\s*[a-z]+[^>]*>' then
    score := score + 0.5; cats := cats || 'html';
  end if;
  if t ~ '(union\s+(all\s+)?select|insert\s+into\s+\w|drop\s+table|xp_cmdshell|;\s*delete\s+from)' then
    score := score + 0.9; cats := cats || 'malicious';
  end if;

  -- links & promotion (spam)
  links := (char_length(t) - char_length(replace(replace(t, 'http://', ''), 'https://', ''))) / 7;
  if links >= 2 then score := score + 0.6; cats := cats || 'spam';
  elsif links = 1 then score := score + 0.3; cats := cats || 'links';
  end if;
  if t ~ '(buy now|click here|limited offer|promo code|discount code|earn money|make \$|whatsapp me|call me at|dm for|follow me|subscribe to|free followers|crypto invest|loan approval)' then
    score := score + 0.55; cats := cats || 'spam';
  end if;

  -- severe abuse / threats / self-harm encouragement
  if t ~ '(kill yourself|kys\M|go die\M|you should die|i will kill|i''ll kill|rape you|deserve to be raped|behead|lynch)' then
    score := score + 0.95; cats := cats || 'abuse';
  end if;
  if t ~ '(bomb (the|a)|plant a bomb|shoot up|attack (the|a) (school|temple|mosque|church))' then
    score := score + 0.95; cats := cats || 'threat';
  end if;
  -- harassment-ish profanity (moderate)
  if t ~ '\m(bitch|bastard|asshole|chutiya|madarchod|behenchod|randi|kamina|haramzada|whore|slut)\M' then
    score := score + 0.45; cats := cats || 'profanity';
  end if;

  -- bot-ish noise
  if t ~ '(.)\1{7,}' then score := score + 0.15; cats := cats || 'noise'; end if;

  return json_build_object(
    'score', least(1.0, score),
    'categories', to_json(cats),
    'reason', case when array_length(cats,1) is null then null else array_to_string(cats, ', ') end
  );
end $$;

-- Shared publisher used by both the public RPC and the (optional)
-- AI edge function. NOT granted to anon/authenticated directly.
create or replace function public.finalize_publish(
  p_id uuid,               -- null = new feeling; not null = edit of own feeling (ownership pre-checked by caller)
  p_user uuid, p_visitor uuid,
  p_title text, p_content text, p_category text, p_mood text,
  p_visibility text, p_name text, p_tags text[],
  p_score numeric, p_categories text, p_source text
) returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_cat uuid; v_status text; v_decision text; v_row uuid; v_msg text;
begin
  select * into s from public.mod_settings where id = 1;

  if p_score >= s.reject_threshold then
    insert into public.moderation_logs (feeling_id, action, decision, risk_score, reason, source)
    values (p_id, case when p_id is null then 'submit_rejected' else 'edit_rejected' end, 'REJECT', p_score, p_categories, p_source);
    return json_build_object('ok', false, 'decision', 'REJECT',
      'message', 'SeRuh couldn''t publish this one. Please soften it and try again. 🕊️');
  end if;

  v_decision := case when p_score >= s.flag_threshold then 'FLAG' else 'ALLOW' end;
  v_status := 'PUBLISHED';

  select id into v_cat from public.categories where name = p_category and status = 'ACTIVE';

  if p_id is null then
    insert into public.feelings
      (title, content, category_id, mood, is_anonymous, name, visitor_id, user_id,
       visibility, tags, status, moderation_score, moderation_decision, moderation_reason, published_at)
    values
      (nullif(btrim(coalesce(p_title,'')),''), btrim(p_content), v_cat, left(coalesce(p_mood,'Emotional'),40),
       p_visibility = 'ANONYMOUS', nullif(left(btrim(coalesce(p_name,'')),80),''),
       p_visitor, p_user, p_visibility, coalesce(p_tags,'{}'),
       v_status, p_score, v_decision, p_categories, now())
    returning id into v_row;
  else
    update public.feelings set
      title = nullif(btrim(coalesce(p_title,'')),''), content = btrim(p_content),
      category_id = coalesce(v_cat, category_id), mood = left(coalesce(p_mood, mood),40),
      visibility = p_visibility, is_anonymous = (p_visibility = 'ANONYMOUS'),
      tags = coalesce(p_tags, tags),
      moderation_score = p_score, moderation_decision = v_decision, moderation_reason = p_categories,
      updated_at = now()
    where id = p_id
    returning id into v_row;
  end if;

  insert into public.moderation_logs (feeling_id, action, decision, risk_score, reason, source)
  values (v_row, case when p_id is null then 'published' else 'edited' end, v_decision, p_score, p_categories, p_source);

  v_msg := case
    when p_visibility = 'PRIVATE' then 'Kept just for you, in My SeRuh. 🤍'
    else 'Your words are out there now. ❤️'
  end;
  return json_build_object('ok', true, 'decision', v_decision, 'id', v_row, 'message', v_msg);
end $$;
revoke execute on function public.finalize_publish(uuid,uuid,uuid,text,text,text,text,text,text,text[],numeric,text,text) from public, anon, authenticated;

-- ─── 5. Public publish RPC (validation + spam guards + engine) ──

create or replace function public.publish_feeling(
  p_title text, p_content text, p_category text, p_mood text,
  p_visibility text, p_name text, p_visitor uuid,
  p_honey text default '', p_tags text[] default '{}', p_edit_id uuid default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_user uuid := auth.uid(); v_recent int; v_limit int; m json; v_vis text;
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

  m := public.moderate_text(coalesce(p_title,'') || ' ' || p_content);

  return public.finalize_publish(
    p_edit_id, v_user, p_visitor, p_title, p_content, p_category, p_mood,
    v_vis, p_name, p_tags, (m->>'score')::numeric, m->>'reason', 'AUTOMATED');
end $$;

-- keep the old name working (old builds route into the new flow)
create or replace function public.submit_feeling(
  p_content text, p_category text, p_mood text,
  p_anonymous boolean, p_name text, p_email text,
  p_visitor uuid, p_honey text default ''
) returns json language sql security definer set search_path = public as $$
  select public.publish_feeling(null, p_content, p_category, p_mood,
    case when coalesce(p_anonymous,false) then 'ANONYMOUS' else 'PUBLIC' end,
    p_name, p_visitor, p_honey, '{}', null);
$$;

-- ─── 6. Own-content management ──────────────────────────────────

create or replace function public.delete_my_feeling(p_id uuid, p_visitor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  delete from public.feelings where id = p_id
    and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor and user_id is null));
end $$;

create or replace function public.set_feeling_visibility(p_id uuid, p_visitor uuid, p_visibility text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if upper(p_visibility) not in ('PUBLIC','ANONYMOUS','PRIVATE') then raise exception 'bad visibility'; end if;
  update public.feelings set visibility = upper(p_visibility),
    is_anonymous = (upper(p_visibility) = 'ANONYMOUS'), updated_at = now()
  where id = p_id
    and ((v_user is not null and user_id = v_user) or (v_user is null and visitor_id = p_visitor and user_id is null));
end $$;

create or replace function public.get_my_submissions(p_visitor uuid)
returns setof json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  return query
    select row_to_json(t) from (
      select f.id, f.title, f.content, coalesce(c.name,'—') as category, f.mood,
             f.visibility, f.status, f.report_count > 0 as reported, f.created_at
      from public.feelings f
      left join public.categories c on c.id = f.category_id
      where ((v_user is not null and f.user_id = v_user)
          or (v_user is null and f.visitor_id = p_visitor and f.user_id is null))
      order by f.created_at desc limit 100
    ) t;
end $$;

-- ─── 7. Reporting ───────────────────────────────────────────────

create or replace function public.report_feeling(
  p_feeling uuid, p_visitor uuid, p_reason text, p_description text default null
) returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_inserted boolean := false;
begin
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if not exists (select 1 from public.feelings where id = p_feeling and status = 'PUBLISHED'
                 and visibility in ('PUBLIC','ANONYMOUS')) then
    raise exception 'not reportable';
  end if;

  insert into public.content_reports (feeling_id, reporter_user, reporter_visitor, reason, description)
  values (p_feeling, v_user, case when v_user is null then p_visitor else null end,
          p_reason, nullif(btrim(coalesce(p_description,'')),''))
  on conflict do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted then
    update public.feelings set report_count = report_count + 1 where id = p_feeling;
    insert into public.moderation_logs (feeling_id, action, decision, reason, source)
    values (p_feeling, 'reported', null, p_reason, 'USER_REPORT');
  end if;
  return json_build_object('ok', true, 'already', not v_inserted);
end $$;

-- ─── 8. Public wall view (titles + safe fields only) ────────────

drop view if exists public.feelings_public;
create view public.feelings_public as
  select f.id, f.title, f.content, coalesce(c.name, 'Unsaid Things') as category, f.mood,
         case
           when f.visibility = 'ANONYMOUS' then 'Anonymous'
           else coalesce(nullif(btrim(coalesce(f.name,'')),''), p.name, 'Anonymous')
         end as display_name,
         f.created_at,
         coalesce(l.cnt, 0)::bigint as like_count
  from public.feelings f
  left join public.categories c on c.id = f.category_id
  left join public.profiles p on p.user_id = f.user_id
  left join (select feeling_id, count(*) cnt from public.feeling_likes group by 1) l
    on l.feeling_id = f.id
  where f.status = 'PUBLISHED' and f.visibility in ('PUBLIC','ANONYMOUS');
grant select on public.feelings_public to anon, authenticated;

-- ─── 9. Admin: moderation & reports & users ─────────────────────

create or replace function public.admin_flagged_feelings(p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select f.id, f.title, f.content, coalesce(c.name,'—') as category, f.mood,
             f.visibility, f.status, f.moderation_score, f.moderation_decision,
             f.moderation_reason, f.report_count, f.name, f.email, f.created_at
      from public.feelings f left join public.categories c on c.id = f.category_id
      where f.status in ('FLAGGED','UNDER_REVIEW')
         or (f.status = 'PUBLISHED' and (f.moderation_decision = 'FLAG' or f.report_count > 0))
      order by f.report_count desc, f.created_at desc
      limit 20 offset greatest(0, p_page) * 20
    ) t;
end $$;

create or replace function public.admin_removed_feelings(p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select f.id, f.title, f.content, coalesce(c.name,'—') as category,
             f.visibility, f.status, f.report_count, f.removed_at, f.created_at
      from public.feelings f left join public.categories c on c.id = f.category_id
      where f.status in ('REMOVED','ARCHIVED')
      order by coalesce(f.removed_at, f.created_at) desc
      limit 20 offset greatest(0, p_page) * 20
    ) t;
end $$;

create or replace function public.admin_set_feeling_status(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('PUBLISHED','FLAGGED','REMOVED','ARCHIVED','UNDER_REVIEW') then raise exception 'bad status'; end if;
  update public.feelings set status = p_status,
    removed_at = case when p_status in ('REMOVED','ARCHIVED') then now() else null end,
    moderation_decision = case when p_status = 'PUBLISHED' then 'ALLOW' else moderation_decision end,
    report_count = case when p_status = 'PUBLISHED' then 0 else report_count end,
    updated_at = now()
  where id = p_id;
  insert into public.moderation_logs (feeling_id, action, decision, reason, source)
  values (p_id, 'admin_set_' || lower(p_status), p_status, p_note, 'ADMIN');
end $$;

create or replace function public.admin_reports(p_status text default 'OPEN', p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select r.id, r.feeling_id, r.reason, r.description, r.status, r.created_at,
             r.resolved_at, r.resolution,
             left(f.content, 160) as content, f.status as feeling_status, f.report_count
      from public.content_reports r
      join public.feelings f on f.id = r.feeling_id
      where r.status = p_status
      order by f.report_count desc, r.created_at desc
      limit 20 offset greatest(0, p_page) * 20
    ) t;
end $$;

create or replace function public.admin_resolve_report(p_id uuid, p_outcome text, p_resolution text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  if p_outcome not in ('RESOLVED','DISMISSED','INVESTIGATING') then raise exception 'bad outcome'; end if;
  update public.content_reports set status = p_outcome,
    resolved_at = case when p_outcome in ('RESOLVED','DISMISSED') then now() else null end,
    resolved_by = auth.uid(), resolution = p_resolution
  where id = p_id;
end $$;

create or replace function public.admin_moderation_logs(p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select l.id, l.feeling_id, l.action, l.decision, l.risk_score, l.reason, l.source, l.created_at,
             left(coalesce(f.content,''), 100) as content
      from public.moderation_logs l left join public.feelings f on f.id = l.feeling_id
      order by l.created_at desc
      limit 30 offset greatest(0, p_page) * 30
    ) t;
end $$;

create or replace function public.admin_list_users(p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select pr.user_id, pr.name, u.email, pr.status, pr.created_at, pr.last_login_at,
             (select count(*) from public.feelings fe where fe.user_id = pr.user_id) as feelings,
             (select count(*) from public.quote_likes ql where ql.user_id = pr.user_id) as likes,
             exists (select 1 from public.admins a where a.user_id = pr.user_id) as is_admin
      from public.profiles pr join auth.users u on u.id = pr.user_id
      order by pr.created_at desc
      limit 20 offset greatest(0, p_page) * 20
    ) t;
end $$;

create or replace function public.admin_set_user_status(p_user uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('ACTIVE','DISABLED') then raise exception 'bad status'; end if;
  if exists (select 1 from public.admins where user_id = p_user) and p_status = 'DISABLED' then
    raise exception 'cannot suspend an admin';
  end if;
  update public.profiles set status = p_status, updated_at = now() where user_id = p_user;
  insert into public.moderation_logs (action, decision, reason, source)
  values ('user_' || lower(p_status), p_status, p_user::text, 'ADMIN');
end $$;

-- ─── 10. Analytics overview (extended) ──────────────────────────

create or replace function public.admin_analytics_overview(p_from timestamptz, p_to timestamptz)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return json_build_object(
    'total_users',      (select count(*) from public.profiles),
    'new_users',        (select count(*) from public.profiles where created_at between p_from and p_to),
    'active_visitors',  (select count(distinct coalesce(user_id::text, visitor_id::text)) from public.analytics_events where created_at between p_from and p_to),
    'total_quotes',     (select count(*) from public.quotes),
    'total_likes',      (select count(*) from public.quote_likes),
    'likes_period',     (select count(*) from public.quote_likes where created_at between p_from and p_to),
    'total_saves',      (select count(*) from public.saved_quotes),
    'saves_period',     (select count(*) from public.saved_quotes where created_at between p_from and p_to),
    'total_feelings',   (select count(*) from public.feelings),
    'published_feelings',(select count(*) from public.feelings where status = 'PUBLISHED'),
    'anonymous_feelings',(select count(*) from public.feelings where visibility = 'ANONYMOUS' and status = 'PUBLISHED'),
    'private_feelings', (select count(*) from public.feelings where visibility = 'PRIVATE'),
    'flagged_feelings', (select count(*) from public.feelings where status in ('FLAGGED','UNDER_REVIEW')
                           or (status = 'PUBLISHED' and (moderation_decision = 'FLAG' or report_count > 0))),
    'removed_feelings', (select count(*) from public.feelings where status in ('REMOVED','ARCHIVED')),
    'open_reports',     (select count(*) from public.content_reports where status = 'OPEN'),
    'approved_feelings',(select count(*) from public.feelings where status = 'PUBLISHED'),
    'pending_feelings', (select count(*) from public.feelings where status in ('FLAGGED','UNDER_REVIEW')),
    'submissions_period',(select count(*) from public.feelings where created_at between p_from and p_to),
    'ai_total',         (select count(*) from public.ai_generations),
    'ai_period',        (select count(*) from public.ai_generations where created_at between p_from and p_to),
    'ai_failed_period', (select count(*) from public.ai_generations where status <> 'SUCCESS' and created_at between p_from and p_to),
    'ai_guest_period',  (select count(*) from public.ai_generations where user_id is null and created_at between p_from and p_to),
    'ai_user_period',   (select count(*) from public.ai_generations where user_id is not null and created_at between p_from and p_to),
    'ai_avg_ms',        (select coalesce(round(avg(duration_ms)), 0) from public.ai_generations where status = 'SUCCESS' and created_at between p_from and p_to),
    'users_generated',  (select count(distinct user_id) from public.ai_generations where user_id is not null and created_at between p_from and p_to),
    'users_saved',      (select count(distinct user_id) from public.saved_quotes where user_id is not null and created_at between p_from and p_to),
    'users_submitted',  (select count(distinct user_id) from public.feelings where user_id is not null and created_at between p_from and p_to)
  );
end $$;

-- ─── 11. Grants ─────────────────────────────────────────────────

grant execute on function
  public.publish_feeling(text, text, text, text, text, text, uuid, text, text[], uuid),
  public.delete_my_feeling(uuid, uuid),
  public.set_feeling_visibility(uuid, uuid, text),
  public.report_feeling(uuid, uuid, text, text),
  public.admin_flagged_feelings(int),
  public.admin_removed_feelings(int),
  public.admin_set_feeling_status(uuid, text, text),
  public.admin_reports(text, int),
  public.admin_resolve_report(uuid, text, text),
  public.admin_moderation_logs(int),
  public.admin_list_users(int),
  public.admin_set_user_status(uuid, text)
to anon, authenticated;

-- Done: feelings now publish instantly through automated moderation;
-- admins handle only flagged / reported exceptions. No data lost.
