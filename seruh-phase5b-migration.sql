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
