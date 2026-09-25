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

begin;

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
