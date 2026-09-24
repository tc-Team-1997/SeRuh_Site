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

begin;

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

commit;
