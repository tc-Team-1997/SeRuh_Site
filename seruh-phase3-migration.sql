-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 3 database migration (run AFTER seruh-setup.sql)
--
--  This is a MIGRATION: it only ADDS to the Phase 2 schema.
--  No existing quotes, feelings, likes, saves or admin data is
--  touched. Safe to run once on the live project.
--
--  Adds: user profiles & preferences, AI generations, analytics
--  events, AI settings, user-aware likes/saves, personalization,
--  account deletion, and admin analytics functions.
-- ═══════════════════════════════════════════════════════════════

-- ─── 1. Profiles (auto-created for every new auth user) ────────

create table if not exists public.profiles (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  name          text check (char_length(name) <= 80),
  status        text not null default 'ACTIVE' check (status in ('ACTIVE','DISABLED')),
  onboarding    jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  last_login_at timestamptz
);

create table if not exists public.user_preferences (
  user_id         uuid primary key references public.profiles(user_id) on delete cascade,
  preferred_mood  text check (char_length(preferred_mood) <= 40),
  preferred_style text check (char_length(preferred_style) <= 40),
  notifications   jsonb not null default '{}'::jsonb,
  updated_at      timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.user_preferences enable row level security;

create policy profiles_own on public.profiles
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy profiles_admin_read on public.profiles
  for select to authenticated using (public.am_i_admin());
create policy prefs_own on public.user_preferences
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- auto-create a profile row on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id, name)
  values (new.id, nullif(left(coalesce(new.raw_user_meta_data->>'name',''), 80), ''))
  on conflict (user_id) do nothing;
  insert into public.user_preferences (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─── 2. User-aware likes / saves / feelings ────────────────────

alter table public.quote_likes   add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.saved_quotes  add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.feeling_likes add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.feelings      add column if not exists user_id uuid references auth.users(id) on delete set null;

create unique index if not exists quote_likes_user_uniq   on public.quote_likes(quote_id, user_id)   where user_id is not null;
create unique index if not exists saved_quotes_user_uniq  on public.saved_quotes(quote_id, user_id)  where user_id is not null;
create unique index if not exists feeling_likes_user_uniq on public.feeling_likes(feeling_id, user_id) where user_id is not null;
create index if not exists feelings_user_idx on public.feelings(user_id);

-- ─── 3. AI settings (single configurable row, admin-managed) ───

create table if not exists public.ai_settings (
  id                int primary key default 1 check (id = 1),
  provider          text not null default 'gemini',
  model             text not null default 'gemini-2.0-flash',
  guest_daily_limit int  not null default 5  check (guest_daily_limit between 0 and 1000),
  user_daily_limit  int  not null default 25 check (user_daily_limit between 0 and 5000),
  max_input_length  int  not null default 500,
  max_output_words  int  not null default 60,
  temperature       numeric not null default 0.9 check (temperature between 0 and 2),
  updated_at        timestamptz not null default now()
);
insert into public.ai_settings (id) values (1) on conflict (id) do nothing;

alter table public.ai_settings enable row level security;
create policy ai_settings_admin on public.ai_settings
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());

-- ─── 4. AI generations ─────────────────────────────────────────

create table if not exists public.ai_generations (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid references auth.users(id) on delete cascade,
  visitor_id     uuid,
  input_text     text not null check (char_length(input_text) <= 1000),
  mood           text, style text, length text,
  generated_text text,
  model          text,
  status         text not null default 'SUCCESS' check (status in ('SUCCESS','FAILED','BLOCKED')),
  duration_ms    int,
  saved          boolean not null default false,
  created_at     timestamptz not null default now()
);
create index if not exists ai_gen_user_idx    on public.ai_generations(user_id, created_at desc);
create index if not exists ai_gen_visitor_idx on public.ai_generations(visitor_id, created_at desc);
create index if not exists ai_gen_created_idx on public.ai_generations(created_at desc);

alter table public.ai_generations enable row level security;
create policy ai_gen_admin_read on public.ai_generations
  for select to authenticated using (public.am_i_admin());
-- (users/guests access their own rows only through the RPCs below)

-- ─── 5. Analytics events (aggregate insights, minimal data) ────

create table if not exists public.analytics_events (
  id          bigint generated always as identity primary key,
  event       text not null check (char_length(event) <= 40),
  entity_type text check (char_length(entity_type) <= 30),
  entity_id   text check (char_length(entity_id) <= 60),
  visitor_id  uuid,
  user_id     uuid,
  meta        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists events_event_time_idx on public.analytics_events(event, created_at desc);
create index if not exists events_time_idx       on public.analytics_events(created_at desc);

alter table public.analytics_events enable row level security;
create policy events_admin_read on public.analytics_events
  for select to authenticated using (public.am_i_admin());

create or replace function public.track_event(
  p_event text, p_entity_type text default null, p_entity_id text default null,
  p_visitor uuid default null, p_meta jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare v_recent int;
begin
  if p_event is null or p_event !~ '^[a-z_]{2,40}$' then return; end if;
  select count(*) into v_recent from public.analytics_events
    where visitor_id = p_visitor and created_at > now() - interval '10 minutes';
  if v_recent > 300 then return; end if;   -- abuse guard, drop silently
  insert into public.analytics_events (event, entity_type, entity_id, visitor_id, user_id, meta)
  values (p_event, left(p_entity_type, 30), left(p_entity_id, 60), p_visitor, auth.uid(),
          case when jsonb_typeof(p_meta) = 'object' then p_meta else '{}'::jsonb end);
end $$;

-- ─── 6. Identity-aware toggle functions (guest OR logged-in) ───
--  Replaces the Phase 2 versions: same signatures, so the
--  existing frontend keeps working. auth.uid() wins over visitor.

create or replace function public.toggle_quote_like(p_quote uuid, p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_liked boolean; v_count bigint; v_user uuid := auth.uid();
begin
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if not exists (select 1 from public.quotes where id = p_quote and status = 'PUBLISHED') then
    raise exception 'quote not available';
  end if;

  if v_user is not null then
    delete from public.quote_likes where quote_id = p_quote and user_id = v_user;
  else
    delete from public.quote_likes where quote_id = p_quote and visitor_id = p_visitor and user_id is null;
  end if;

  if not found then
    insert into public.quote_likes (quote_id, visitor_id, user_id)
    values (p_quote, coalesce(p_visitor, gen_random_uuid()), v_user)
    on conflict do nothing;
    v_liked := true;
  else
    v_liked := false;
  end if;

  select count(*) into v_count from public.quote_likes where quote_id = p_quote;
  return json_build_object('liked', v_liked, 'count', v_count);
end $$;

create or replace function public.toggle_quote_save(p_quote uuid, p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_saved boolean; v_user uuid := auth.uid();
begin
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if not exists (select 1 from public.quotes where id = p_quote and status = 'PUBLISHED') then
    raise exception 'quote not available';
  end if;

  if v_user is not null then
    delete from public.saved_quotes where quote_id = p_quote and user_id = v_user;
  else
    delete from public.saved_quotes where quote_id = p_quote and visitor_id = p_visitor and user_id is null;
  end if;

  if not found then
    insert into public.saved_quotes (quote_id, visitor_id, user_id)
    values (p_quote, coalesce(p_visitor, gen_random_uuid()), v_user)
    on conflict do nothing;
    v_saved := true;
  else
    v_saved := false;
  end if;
  return json_build_object('saved', v_saved);
end $$;

create or replace function public.toggle_feeling_like(p_feeling uuid, p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_liked boolean; v_count bigint; v_user uuid := auth.uid();
begin
  if p_visitor is null and v_user is null then raise exception 'identity required'; end if;
  if not exists (select 1 from public.feelings where id = p_feeling and status = 'APPROVED') then
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

create or replace function public.get_my_activity(p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is not null then
    return json_build_object(
      'liked_quote_ids',
        coalesce((select json_agg(quote_id) from public.quote_likes where user_id = v_user), '[]'::json),
      'saved',
        coalesce((select json_agg(json_build_object('quote_id', quote_id, 'saved_at', created_at))
                  from public.saved_quotes where user_id = v_user), '[]'::json),
      'liked_feeling_ids',
        coalesce((select json_agg(feeling_id) from public.feeling_likes where user_id = v_user), '[]'::json)
    );
  end if;
  return json_build_object(
    'liked_quote_ids',
      coalesce((select json_agg(quote_id) from public.quote_likes where visitor_id = p_visitor and user_id is null), '[]'::json),
    'saved',
      coalesce((select json_agg(json_build_object('quote_id', quote_id, 'saved_at', created_at))
                from public.saved_quotes where visitor_id = p_visitor and user_id is null), '[]'::json),
    'liked_feeling_ids',
      coalesce((select json_agg(feeling_id) from public.feeling_likes where visitor_id = p_visitor and user_id is null), '[]'::json)
  );
end $$;

create or replace function public.get_saved_quotes(p_visitor uuid)
returns setof json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is not null then
    return query
      select row_to_json(t) from (
        select qp.id, qp.quote, qp.category, qp.mood, qp.author, qp.tags,
               qp.featured, qp.like_count, s.created_at as saved_at
        from public.saved_quotes s
        join public.quotes_public qp on qp.id = s.quote_id
        where s.user_id = v_user
        order by s.created_at desc
      ) t;
  else
    return query
      select row_to_json(t) from (
        select qp.id, qp.quote, qp.category, qp.mood, qp.author, qp.tags,
               qp.featured, qp.like_count, s.created_at as saved_at
        from public.saved_quotes s
        join public.quotes_public qp on qp.id = s.quote_id
        where s.visitor_id = p_visitor and s.user_id is null
        order by s.created_at desc
      ) t;
  end if;
end $$;

-- submissions carry the user when logged in
create or replace function public.submit_feeling(
  p_content text, p_category text, p_mood text,
  p_anonymous boolean, p_name text, p_email text,
  p_visitor uuid, p_honey text default ''
) returns json language plpgsql security definer set search_path = public as $$
declare v_cat uuid; v_recent int;
begin
  if coalesce(p_honey, '') <> '' then return json_build_object('ok', true); end if;
  if p_visitor is null then raise exception 'visitor required'; end if;
  if char_length(btrim(coalesce(p_content, ''))) < 3 then raise exception 'too short'; end if;
  if char_length(p_content) > 1000 then raise exception 'too long'; end if;
  if p_email is not null and p_email <> '' and p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email';
  end if;

  select count(*) into v_recent from public.feelings
    where visitor_id = p_visitor and created_at > now() - interval '1 hour';
  if v_recent >= 5 then raise exception 'rate limited — please slow down'; end if;

  select id into v_cat from public.categories where name = p_category and status = 'ACTIVE';

  insert into public.feelings (content, category_id, mood, is_anonymous, name, email, visitor_id, user_id, status)
  values (
    btrim(p_content), v_cat, left(coalesce(p_mood, 'Emotional'), 40),
    coalesce(p_anonymous, false),
    nullif(left(btrim(coalesce(p_name, '')), 80), ''),
    nullif(left(btrim(coalesce(p_email, '')), 200), ''),
    p_visitor, auth.uid(), 'PENDING'
  );
  return json_build_object('ok', true);
end $$;

-- ─── 7. Guest → account data merge ─────────────────────────────

create or replace function public.merge_visitor_data(p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_likes int := 0; v_saves int := 0;
begin
  if v_user is null then raise exception 'login required'; end if;
  if p_visitor is null then return json_build_object('ok', true); end if;

  -- drop guest rows that would duplicate the user's existing rows
  delete from public.quote_likes g
    where g.visitor_id = p_visitor and g.user_id is null
      and exists (select 1 from public.quote_likes u where u.quote_id = g.quote_id and u.user_id = v_user);
  update public.quote_likes set user_id = v_user
    where visitor_id = p_visitor and user_id is null;
  get diagnostics v_likes = row_count;

  delete from public.saved_quotes g
    where g.visitor_id = p_visitor and g.user_id is null
      and exists (select 1 from public.saved_quotes u where u.quote_id = g.quote_id and u.user_id = v_user);
  update public.saved_quotes set user_id = v_user
    where visitor_id = p_visitor and user_id is null;
  get diagnostics v_saves = row_count;

  delete from public.feeling_likes g
    where g.visitor_id = p_visitor and g.user_id is null
      and exists (select 1 from public.feeling_likes u where u.feeling_id = g.feeling_id and u.user_id = v_user);
  update public.feeling_likes set user_id = v_user
    where visitor_id = p_visitor and user_id is null;

  update public.feelings set user_id = v_user where visitor_id = p_visitor and user_id is null;
  update public.ai_generations set user_id = v_user where visitor_id = p_visitor and user_id is null;

  return json_build_object('ok', true, 'likes', v_likes, 'saves', v_saves);
end $$;

-- ─── 8. AI generation history (owner-only access) ──────────────

create or replace function public.get_my_generations(p_visitor uuid)
returns setof json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  return query
    select row_to_json(t) from (
      select id, input_text, mood, style, length, generated_text, saved, created_at
      from public.ai_generations
      where status = 'SUCCESS'
        and ((v_user is not null and user_id = v_user)
          or (v_user is null and visitor_id = p_visitor and user_id is null))
      order by created_at desc
      limit 100
    ) t;
end $$;

create or replace function public.set_generation_saved(p_id uuid, p_visitor uuid, p_saved boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  update public.ai_generations set saved = coalesce(p_saved, false)
  where id = p_id
    and ((v_user is not null and user_id = v_user)
      or (v_user is null and visitor_id = p_visitor and user_id is null));
end $$;

create or replace function public.delete_generation(p_id uuid, p_visitor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  delete from public.ai_generations
  where id = p_id
    and ((v_user is not null and user_id = v_user)
      or (v_user is null and visitor_id = p_visitor and user_id is null));
end $$;

-- ─── 9. My submissions / likes / activity feed ─────────────────

create or replace function public.get_my_submissions(p_visitor uuid)
returns setof json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  return query
    select row_to_json(t) from (
      select f.id, f.content, coalesce(c.name,'—') as category, f.mood,
             f.is_anonymous, f.status, f.created_at
      from public.feelings f
      left join public.categories c on c.id = f.category_id
      where ((v_user is not null and f.user_id = v_user)
          or (v_user is null and f.visitor_id = p_visitor and f.user_id is null))
      order by f.created_at desc
      limit 100
    ) t;
end $$;

create or replace function public.get_my_liked_quotes(p_visitor uuid)
returns setof json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  return query
    select row_to_json(t) from (
      select qp.id, qp.quote, qp.category, qp.mood, qp.author, qp.like_count, l.created_at as liked_at
      from public.quote_likes l
      join public.quotes_public qp on qp.id = l.quote_id
      where ((v_user is not null and l.user_id = v_user)
          or (v_user is null and l.visitor_id = p_visitor and l.user_id is null))
      order by l.created_at desc
      limit 100
    ) t;
end $$;

create or replace function public.get_my_activity_feed(p_visitor uuid)
returns setof json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  return query
    select row_to_json(t) from (
      (select 'liked a quote'::text as label, qp.quote as detail, l.created_at
         from public.quote_likes l join public.quotes_public qp on qp.id = l.quote_id
         where (v_user is not null and l.user_id = v_user) or (v_user is null and l.visitor_id = p_visitor and l.user_id is null))
      union all
      (select 'saved a quote', qp.quote, s.created_at
         from public.saved_quotes s join public.quotes_public qp on qp.id = s.quote_id
         where (v_user is not null and s.user_id = v_user) or (v_user is null and s.visitor_id = p_visitor and s.user_id is null))
      union all
      (select 'shared a feeling', left(f.content, 90), f.created_at
         from public.feelings f
         where (v_user is not null and f.user_id = v_user) or (v_user is null and f.visitor_id = p_visitor and f.user_id is null))
      union all
      (select 'turned a feeling into words', left(coalesce(g.generated_text,''), 90), g.created_at
         from public.ai_generations g
         where g.status = 'SUCCESS'
           and ((v_user is not null and g.user_id = v_user) or (v_user is null and g.visitor_id = p_visitor and g.user_id is null)))
      order by created_at desc
      limit 25
    ) t;
end $$;

-- ─── 10. Personalized recommendations (subtle, privacy-safe) ───

create or replace function public.get_recommended_quotes(p_visitor uuid, p_limit int default 3)
returns setof json language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  return query
    select row_to_json(t) from (
      with my_taste as (
        select qp.category, qp.mood
        from public.quote_likes l join public.quotes_public qp on qp.id = l.quote_id
        where (v_user is not null and l.user_id = v_user) or (l.visitor_id = p_visitor and l.user_id is null)
        union all
        select qp.category, qp.mood
        from public.saved_quotes s join public.quotes_public qp on qp.id = s.quote_id
        where (v_user is not null and s.user_id = v_user) or (s.visitor_id = p_visitor and s.user_id is null)
        union all
        select null, up.preferred_mood from public.user_preferences up
        where v_user is not null and up.user_id = v_user and up.preferred_mood is not null
      ),
      seen as (
        select quote_id from public.quote_likes
          where (v_user is not null and user_id = v_user) or (visitor_id = p_visitor and user_id is null)
        union
        select quote_id from public.saved_quotes
          where (v_user is not null and user_id = v_user) or (visitor_id = p_visitor and user_id is null)
      )
      select qp.id, qp.quote, qp.category, qp.mood, qp.author, qp.tags, qp.featured, qp.like_count
      from public.quotes_public qp
      where qp.id not in (select quote_id from seen)
      order by
        (qp.category in (select category from my_taste where category is not null)) desc,
        (qp.mood in (select mood from my_taste where mood is not null)) desc,
        random()
      limit greatest(1, least(coalesce(p_limit, 3), 12))
    ) t;
end $$;

-- ─── 11. Account deletion (permanent, anonymizing) ─────────────

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'login required'; end if;
  -- personal rows are removed; approved wall feelings stay but are fully anonymized
  delete from public.quote_likes    where user_id = v_user;
  delete from public.saved_quotes   where user_id = v_user;
  delete from public.feeling_likes  where user_id = v_user;
  delete from public.ai_generations where user_id = v_user;
  update public.feelings set user_id = null, name = null, email = null, is_anonymous = true
    where user_id = v_user;
  update public.analytics_events set user_id = null where user_id = v_user;
  delete from public.admins where user_id = v_user;
  delete from auth.users where id = v_user;   -- cascades profiles & preferences
end $$;

-- ─── 12. Admin analytics (aggregated, no raw private content) ──

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
    'approved_feelings',(select count(*) from public.feelings where status = 'APPROVED'),
    'pending_feelings', (select count(*) from public.feelings where status = 'PENDING'),
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

create or replace function public.admin_top_quotes(p_from timestamptz, p_to timestamptz, p_by text default 'likes', p_limit int default 10)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select q.id, left(q.quote, 120) as quote, c.name as category,
             (select count(*) from public.quote_likes l where l.quote_id = q.id and l.created_at between p_from and p_to) as likes,
             (select count(*) from public.saved_quotes s where s.quote_id = q.id and s.created_at between p_from and p_to) as saves,
             (select count(*) from public.analytics_events e where e.event = 'quote_share' and e.entity_id = q.id::text and e.created_at between p_from and p_to) as shares,
             (select count(*) from public.analytics_events e where e.event = 'quote_copy' and e.entity_id = q.id::text and e.created_at between p_from and p_to) as copies
      from public.quotes q join public.categories c on c.id = q.category_id
      where q.status = 'PUBLISHED'
      order by case when p_by = 'saves' then
          (select count(*) from public.saved_quotes s where s.quote_id = q.id and s.created_at between p_from and p_to)
        else
          (select count(*) from public.quote_likes l where l.quote_id = q.id and l.created_at between p_from and p_to)
        end desc
      limit greatest(1, least(coalesce(p_limit, 10), 50))
    ) t;
end $$;

create or replace function public.admin_category_stats(p_from timestamptz, p_to timestamptz)
returns setof json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return query
    select row_to_json(t) from (
      select c.name,
             count(distinct q.id) as quotes,
             (select count(*) from public.quote_likes l join public.quotes q2 on q2.id = l.quote_id
               where q2.category_id = c.id and l.created_at between p_from and p_to) as likes,
             (select count(*) from public.saved_quotes s join public.quotes q3 on q3.id = s.quote_id
               where q3.category_id = c.id and s.created_at between p_from and p_to) as saves
      from public.categories c
      left join public.quotes q on q.category_id = c.id
      where c.status = 'ACTIVE'
      group by c.id, c.name
      order by likes desc
    ) t;
end $$;

create or replace function public.admin_ai_stats(p_from timestamptz, p_to timestamptz)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.am_i_admin() then raise exception 'forbidden'; end if;
  return json_build_object(
    'by_mood',  coalesce((select json_agg(x) from (
                   select mood, count(*) as n from public.ai_generations
                   where created_at between p_from and p_to and mood is not null
                   group by mood order by n desc limit 12) x), '[]'::json),
    'by_style', coalesce((select json_agg(x) from (
                   select style, count(*) as n from public.ai_generations
                   where created_at between p_from and p_to and style is not null
                   group by style order by n desc limit 12) x), '[]'::json),
    'by_day',   coalesce((select json_agg(x) from (
                   select to_char(created_at::date, 'YYYY-MM-DD') as day, count(*) as n
                   from public.ai_generations
                   where created_at between p_from and p_to
                   group by 1 order by 1) x), '[]'::json)
  );
end $$;

-- ─── 13. Grants ─────────────────────────────────────────────────

grant execute on function
  public.track_event(text, text, text, uuid, jsonb),
  public.merge_visitor_data(uuid),
  public.get_my_generations(uuid),
  public.set_generation_saved(uuid, uuid, boolean),
  public.delete_generation(uuid, uuid),
  public.get_my_submissions(uuid),
  public.get_my_liked_quotes(uuid),
  public.get_my_activity_feed(uuid),
  public.get_recommended_quotes(uuid, int),
  public.delete_my_account(),
  public.admin_analytics_overview(timestamptz, timestamptz),
  public.admin_top_quotes(timestamptz, timestamptz, text, int),
  public.admin_category_stats(timestamptz, timestamptz),
  public.admin_ai_stats(timestamptz, timestamptz)
to anon, authenticated;

-- Done. Phase 2 data untouched; Phase 3 ready.
