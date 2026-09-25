-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 13 migration: comments on wall posts too
--  Run AFTER seruh-phase12-migration.sql. Safe to run more than once.
--
--  Phase 12 put public comments on quotes. This extends the same
--  table, the same moderation and the same guards to the feelings
--  people write, because a comment box that only works on the
--  editorial quotes is a comment box on the half nobody came for.
--
--  One table, not two. quote_id becomes nullable, feeling_id joins
--  it, and a constraint requires exactly one — so every rule already
--  written (HELD on flag, two reports hold, author-only delete, rate
--  limit, the admin queue) applies to both without being written
--  twice and without the two drifting apart.
--
--  A wall post now has both kinds of response, and they are not the
--  same thing:
--    · Echo    — a private note, only its author ever reads it
--    · Comment — public, under the post, everyone reads it
--  Both are moderated on the same engine. A flagged comment is HELD
--  rather than published-and-watched, and on a post someone wrote
--  about their own life that matters more, not less.
--
--  Only PUBLIC and ANONYMOUS posts can be commented on. A PRIVATE
--  feeling is not on the wall and never becomes commentable.
-- ═══════════════════════════════════════════════════════════════

begin;

-- ─── 1. One table, two kinds of parent ──────────────────────────
alter table public.quote_comments alter column quote_id drop not null;
alter table public.quote_comments add column if not exists feeling_id uuid
  references public.feelings(id) on delete cascade;

alter table public.quote_comments drop constraint if exists quote_comments_parent_check;
alter table public.quote_comments add constraint quote_comments_parent_check
  check (num_nonnulls(quote_id, feeling_id) = 1);

create index if not exists qcomments_feeling_idx
  on public.quote_comments(feeling_id, created_at desc) where feeling_id is not null;

-- ─── 2. The public view carries both ────────────────────────────
-- feeling_id is appended last, not slotted in beside quote_id:
-- CREATE OR REPLACE VIEW can add a column at the end but cannot
-- insert one in the middle — that reads as renaming every column
-- after it, and Postgres refuses.
create or replace view public.quote_comments_public as
  select c.id, c.quote_id, c.body, c.created_at, c.feeling_id
  from public.quote_comments c
  where c.status = 'PUBLISHED';
grant select on public.quote_comments_public to anon, authenticated;

-- ─── 3. Writing one on a wall post ──────────────────────────────
-- Deliberately a sibling of add_quote_comment rather than a
-- parameter on it: PostgREST resolves an RPC by argument name, so
-- two clear names beat one function with a nullable pair.
create or replace function public.add_feeling_comment(
  p_feeling uuid, p_visitor uuid, p_body text
) returns json language plpgsql security definer set search_path = public as $$
declare
  s record; v_user uuid := auth.uid(); m json;
  v_score numeric; v_reason text; v_status text; v_recent int; v_id uuid;
begin
  select * into s from public.mod_settings where id = 1;
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if char_length(btrim(coalesce(p_body,''))) < 2 then raise exception 'too short'; end if;
  if char_length(p_body) > 500 then raise exception 'too long'; end if;

  -- only a post that is actually on the wall; PRIVATE is unreachable
  if not exists (select 1 from public.feelings_public where id = p_feeling) then
    raise exception 'feeling not available';
  end if;

  if v_user is not null and exists (
    select 1 from public.profiles where user_id = v_user and status <> 'ACTIVE') then
    return json_build_object('ok', false, 'reason', 'blocked',
      'message', 'This account can''t comment right now.');
  end if;

  -- the rate limit counts a person's comments, wherever they left them
  select count(*) into v_recent from public.quote_comments
   where created_at > now() - interval '10 minutes'
     and ((v_user is not null and author_user = v_user)
       or (v_user is null and author_visitor = p_visitor and author_user is null));
  if v_recent >= s.comment_max_per_10min then
    return json_build_object('ok', false, 'reason', 'rate',
      'message', 'Take a breath — you can write again in a few minutes. 🕊️');
  end if;

  m := public.moderate_text(p_body);
  v_score := (m->>'score')::numeric;
  v_reason := m->>'reason';

  if v_score >= s.reject_threshold then
    insert into public.moderation_logs (feeling_id, action, decision, risk_score, reason, source)
    values (p_feeling, 'comment_rejected', 'REJECT', v_score, v_reason, 'AUTOMATED');
    return json_build_object('ok', false, 'reason', 'blocked',
      'message', 'SeRuh couldn''t post this one. Please soften it and try again. 🕊️');
  end if;

  v_status := case when v_score >= s.flag_threshold then 'HELD' else 'PUBLISHED' end;

  insert into public.quote_comments (feeling_id, body, author_visitor, author_user,
                                     status, moderation_score, moderation_reason)
  values (p_feeling, btrim(p_body),
          case when v_user is null then p_visitor else null end, v_user,
          v_status, v_score, v_reason)
  returning id into v_id;

  insert into public.moderation_logs (feeling_id, action, decision, risk_score, reason, source)
  values (p_feeling, 'comment_' || lower(v_status), v_status, v_score, v_reason, 'AUTOMATED');

  return json_build_object('ok', true, 'id', v_id, 'status', v_status,
    'message', case when v_status = 'PUBLISHED'
                    then 'Posted. 🤍'
                    else 'Posted for a quick look before it appears. 🕊️' end);
end $$;

-- ─── 4. Reading them ────────────────────────────────────────────
create or replace function public.get_feeling_comments(
  p_feeling uuid, p_visitor uuid default null, p_page int default 0
) returns setof json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select c.id, c.body, c.created_at,
           (  (auth.uid() is not null and c.author_user = auth.uid())
           or (auth.uid() is null and c.author_visitor = p_visitor and c.author_user is null)
           ) as mine
    from public.quote_comments c
    where c.feeling_id = p_feeling and c.status = 'PUBLISHED'
    order by c.created_at asc
    limit 50 offset greatest(0, p_page) * 50
  ) t;
$$;

create or replace function public.count_feeling_comments(p_feeling uuid)
returns int language sql security definer set search_path = public as $$
  select count(*)::int from public.quote_comments
   where feeling_id = p_feeling and status = 'PUBLISHED';
$$;

grant execute on function
  public.add_feeling_comment(uuid, uuid, text),
  public.get_feeling_comments(uuid, uuid, int),
  public.count_feeling_comments(uuid)
to anon, authenticated;

-- delete and report already work on any comment by id, so they need
-- nothing here — which is the point of keeping one table.

-- ─── 5. The admin queue shows both ──────────────────────────────
create or replace function public.admin_comment_queue(p_status text default 'HELD', p_page int default 0)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select c.id, c.quote_id, c.feeling_id, c.body, c.status, c.moderation_score,
             c.moderation_reason, c.report_count, c.created_at,
             coalesce(left(q.quote, 90), left(f.content, 90)) as on_content,
             case when c.quote_id is not null then 'quote' else 'feeling' end as on_kind
      from public.quote_comments c
      left join public.quotes q on q.id = c.quote_id
      left join public.feelings f on f.id = c.feeling_id
      where c.status = p_status
      order by c.report_count desc, c.created_at desc
      limit 20 offset greatest(0, p_page) * 20
    ) t;
end $$;

grant execute on function public.admin_comment_queue(text, int) to anon, authenticated;

-- ─── 6. Self-test ───────────────────────────────────────────────
do $$
declare
  fid uuid; qid uuid; priv uuid; a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
  r json; cid uuid; k int;
begin
  select id into qid from public.quotes_public limit 1;
  r := public.publish_feeling(null, 'phase13 selftest — a post people can answer',
        'Life', 'Emotional', 'PUBLIC', 'QA', a);
  fid := (r->>'id')::uuid;

  -- a comment lands on a wall post
  r := public.add_feeling_comment(fid, b, 'This is exactly how last Tuesday felt.');
  if not coalesce((r->>'ok')::boolean,false) or (r->>'status') <> 'PUBLISHED' then
    raise exception 'a safe comment did not post on a feeling: %', r;
  end if;
  cid := (r->>'id')::uuid;
  if public.count_feeling_comments(fid) <> 1 then raise exception 'feeling comment not counted'; end if;
  if (select count(*) from public.get_feeling_comments(fid, b) t) <> 1 then
    raise exception 'feeling comment not readable';
  end if;

  -- the two kinds stay apart
  if public.count_quote_comments(qid) <> 0 then
    raise exception 'a feeling comment leaked into a quote''s thread';
  end if;

  -- exactly one parent, always
  begin
    insert into public.quote_comments (quote_id, feeling_id, body) values (qid, fid, 'both');
    raise exception 'a comment with two parents was accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.quote_comments (body) values ('orphan');
    raise exception 'a comment with no parent was accepted';
  exception when check_violation then null;
  end;

  -- yours is marked, and the commenter is never exposed
  if (select (t->>'mine')::boolean from public.get_feeling_comments(fid, b) t limit 1) is not true then
    raise exception 'your own comment is not marked as yours';
  end if;
  if (select (t::text) like '%' || b::text || '%' from public.get_feeling_comments(fid, a) t limit 1) then
    raise exception 'the commenter was exposed';
  end if;

  -- moderation applies here too
  r := public.add_feeling_comment(fid, gen_random_uuid(), 'you are a worthless idiot and i will hurt you');
  if coalesce((r->>'ok')::boolean,false) then raise exception 'an abusive comment was accepted'; end if;
  r := public.add_feeling_comment(fid, gen_random_uuid(), 'you are such a bitch honestly');
  if (r->>'status') <> 'HELD' then raise exception 'a borderline comment was not held: %', r; end if;
  if public.count_feeling_comments(fid) <> 1 then raise exception 'a HELD comment is being counted'; end if;

  -- a PRIVATE post can never be commented on
  r := public.publish_feeling(null, 'phase13 selftest — a private one', 'Life','Numb','PRIVATE','QA', a);
  priv := (r->>'id')::uuid;
  begin
    perform public.add_feeling_comment(priv, b, 'trying to reach a private post');
    raise exception 'commented on a PRIVATE feeling';
  exception when others then
    if SQLERRM <> 'feeling not available' then raise; end if;
  end;

  -- delete and report work unchanged, because it is one table
  perform public.delete_my_quote_comment(cid, gen_random_uuid());
  if not exists (select 1 from public.quote_comments where id = cid) then
    raise exception 'a stranger deleted a feeling comment';
  end if;
  perform public.delete_my_quote_comment(cid, b);
  if exists (select 1 from public.quote_comments where id = cid) then
    raise exception 'the author could not delete their feeling comment';
  end if;

  -- the shared rate limit counts across both kinds
  for k in 1..12 loop
    r := public.add_feeling_comment(fid, a, 'rate probe number ' || k);
  end loop;
  if coalesce((r->>'ok')::boolean, true) then raise exception 'the rate limit never bit'; end if;

  delete from public.quote_comments where feeling_id = fid;
  delete from public.moderation_logs where feeling_id in (fid, priv);
  delete from public.feelings where id in (fid, priv);

  raise notice 'phase 13 self-test passed: comments land on wall posts, quote and feeling threads stay apart, exactly one parent enforced, commenter never exposed, moderation and HELD apply, PRIVATE unreachable, author-only delete, shared rate limit bites';
end $$;

commit;
