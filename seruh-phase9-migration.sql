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

begin;

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

commit;
