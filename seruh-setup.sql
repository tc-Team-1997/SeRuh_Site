-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 2 database setup (Supabase / PostgreSQL)
--
--  How to use:
--   1. Supabase dashboard → SQL Editor → New query
--   2. Paste this ENTIRE file → Run
--   3. Authentication → Users → Add user → create your admin
--      (email + password, "Auto confirm" ON)
--   4. Run the small snippet at the VERY BOTTOM of this file
--      (replace the email) to grant that user admin access.
--
--  Security model:
--   • RLS is enabled on every table with NO public policies,
--     so anonymous users cannot touch tables directly.
--   • The public reads only through safe views (no emails,
--     no visitor ids, only APPROVED/PUBLISHED content).
--   • All public writes go through validated SECURITY DEFINER
--     functions (duplicate-protected, rate-limited, honeypot).
--   • Admin access requires a logged-in user present in the
--     `admins` table (checked inside the database, not the UI).
-- ═══════════════════════════════════════════════════════════════

-- ─── Tables ─────────────────────────────────────────────────────

create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(name) between 2 and 40),
  description text not null default '',
  status      text not null default 'ACTIVE' check (status in ('ACTIVE','INACTIVE')),
  sort        int  not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.quotes (
  id          uuid primary key default gen_random_uuid(),
  quote       text not null check (char_length(quote) between 3 and 1000),
  category_id uuid not null references public.categories(id),
  mood        text not null default 'Emotional' check (char_length(mood) <= 40),
  author      text not null default 'SeRuh' check (char_length(author) <= 80),
  tags        text[] not null default '{}',
  status      text not null default 'PUBLISHED' check (status in ('PUBLISHED','DRAFT','ARCHIVED')),
  featured    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists quotes_status_idx   on public.quotes(status);
create index if not exists quotes_category_idx on public.quotes(category_id);
create index if not exists quotes_created_idx  on public.quotes(created_at desc);
create index if not exists quotes_featured_idx on public.quotes(featured) where featured;

create table if not exists public.feelings (
  id           uuid primary key default gen_random_uuid(),
  content      text not null check (char_length(content) between 3 and 1000),
  category_id  uuid references public.categories(id),
  mood         text not null default 'Emotional' check (char_length(mood) <= 40),
  is_anonymous boolean not null default false,
  name         text check (char_length(name) <= 80),
  email        text check (char_length(email) <= 200),
  visitor_id   uuid,
  status       text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','ARCHIVED')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists feelings_status_idx  on public.feelings(status);
create index if not exists feelings_created_idx on public.feelings(created_at desc);
create index if not exists feelings_visitor_idx on public.feelings(visitor_id, created_at);

create table if not exists public.quote_likes (
  id         bigint generated always as identity primary key,
  quote_id   uuid not null references public.quotes(id) on delete cascade,
  visitor_id uuid not null,
  created_at timestamptz not null default now(),
  unique (quote_id, visitor_id)            -- duplicate-like protection
);
create index if not exists quote_likes_quote_idx   on public.quote_likes(quote_id);
create index if not exists quote_likes_visitor_idx on public.quote_likes(visitor_id);

create table if not exists public.saved_quotes (
  id         bigint generated always as identity primary key,
  quote_id   uuid not null references public.quotes(id) on delete cascade,
  visitor_id uuid not null,
  created_at timestamptz not null default now(),
  unique (quote_id, visitor_id)            -- duplicate-save protection
);
create index if not exists saved_quotes_visitor_idx on public.saved_quotes(visitor_id);

create table if not exists public.feeling_likes (
  id         bigint generated always as identity primary key,
  feeling_id uuid not null references public.feelings(id) on delete cascade,
  visitor_id uuid not null,
  created_at timestamptz not null default now(),
  unique (feeling_id, visitor_id)
);
create index if not exists feeling_likes_feeling_idx on public.feeling_likes(feeling_id);

create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ─── Row Level Security: everything locked by default ──────────

alter table public.categories    enable row level security;
alter table public.quotes        enable row level security;
alter table public.feelings      enable row level security;
alter table public.quote_likes   enable row level security;
alter table public.saved_quotes  enable row level security;
alter table public.feeling_likes enable row level security;
alter table public.admins        enable row level security;

-- Admin check (SECURITY DEFINER so it can read `admins` regardless of RLS)
create or replace function public.am_i_admin()
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- Admin policies (full control for admins, nothing for everyone else)
create policy admin_all_categories on public.categories
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());
create policy admin_all_quotes on public.quotes
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());
create policy admin_all_feelings on public.feelings
  for all to authenticated using (public.am_i_admin()) with check (public.am_i_admin());
create policy admin_read_quote_likes on public.quote_likes
  for select to authenticated using (public.am_i_admin());
create policy admin_read_saved_quotes on public.saved_quotes
  for select to authenticated using (public.am_i_admin());
create policy admin_read_feeling_likes on public.feeling_likes
  for select to authenticated using (public.am_i_admin());
create policy admin_read_self on public.admins
  for select to authenticated using (user_id = auth.uid());

-- ─── Public read views (safe columns only) ──────────────────────

create or replace view public.categories_public as
  select name, sort from public.categories
  where status = 'ACTIVE'
  order by sort;

create or replace view public.quotes_public as
  select q.id, q.quote, c.name as category, q.mood, q.author, q.tags,
         q.featured, q.created_at,
         coalesce(l.cnt, 0)::bigint as like_count,
         (q.quote || ' ' || c.name || ' ' || q.mood || ' ' || q.author
            || ' ' || array_to_string(q.tags, ' ')) as search_text
  from public.quotes q
  join public.categories c on c.id = q.category_id
  left join (select quote_id, count(*) cnt from public.quote_likes group by 1) l
    on l.quote_id = q.id
  where q.status = 'PUBLISHED' and c.status = 'ACTIVE';

create or replace view public.feelings_public as
  select f.id, f.content, coalesce(c.name, 'Unsaid Things') as category, f.mood,
         case when f.is_anonymous or f.name is null or btrim(f.name) = ''
              then 'Anonymous' else f.name end as display_name,
         f.created_at,
         coalesce(l.cnt, 0)::bigint as like_count
  from public.feelings f
  left join public.categories c on c.id = f.category_id
  left join (select feeling_id, count(*) cnt from public.feeling_likes group by 1) l
    on l.feeling_id = f.id
  where f.status = 'APPROVED';

grant select on public.categories_public, public.quotes_public, public.feelings_public
  to anon, authenticated;

-- ─── Public functions (validated, duplicate-safe, rate-limited) ─

create or replace function public.get_random_quote(p_exclude uuid default null)
returns json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select id, quote, category, mood, author, tags, featured, like_count
    from public.quotes_public
    where p_exclude is null or id <> p_exclude
    order by random() limit 1
  ) t;
$$;

-- Featured quotes first; stable choice for the whole day; falls back
-- to any published quote if nothing is featured.
create or replace function public.get_todays_feeling()
returns json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select id, quote, category, mood, author, tags, featured, like_count
    from public.quotes_public
    order by featured desc, md5(id::text || current_date::text)
    limit 1
  ) t;
$$;

create or replace function public.get_my_activity(p_visitor uuid)
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'liked_quote_ids',
      coalesce((select json_agg(quote_id) from public.quote_likes where visitor_id = p_visitor), '[]'::json),
    'saved',
      coalesce((select json_agg(json_build_object('quote_id', quote_id, 'saved_at', created_at))
                from public.saved_quotes where visitor_id = p_visitor), '[]'::json),
    'liked_feeling_ids',
      coalesce((select json_agg(feeling_id) from public.feeling_likes where visitor_id = p_visitor), '[]'::json)
  );
$$;

create or replace function public.toggle_quote_like(p_quote uuid, p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_liked boolean; v_count bigint;
begin
  if p_visitor is null then raise exception 'visitor required'; end if;
  if not exists (select 1 from public.quotes where id = p_quote and status = 'PUBLISHED') then
    raise exception 'quote not available';
  end if;

  delete from public.quote_likes where quote_id = p_quote and visitor_id = p_visitor;
  if not found then
    insert into public.quote_likes (quote_id, visitor_id) values (p_quote, p_visitor)
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
declare v_saved boolean;
begin
  if p_visitor is null then raise exception 'visitor required'; end if;
  if not exists (select 1 from public.quotes where id = p_quote and status = 'PUBLISHED') then
    raise exception 'quote not available';
  end if;

  delete from public.saved_quotes where quote_id = p_quote and visitor_id = p_visitor;
  if not found then
    insert into public.saved_quotes (quote_id, visitor_id) values (p_quote, p_visitor)
      on conflict do nothing;
    v_saved := true;
  else
    v_saved := false;
  end if;
  return json_build_object('saved', v_saved);
end $$;

create or replace function public.get_saved_quotes(p_visitor uuid)
returns setof json language sql security definer set search_path = public as $$
  select row_to_json(t) from (
    select qp.id, qp.quote, qp.category, qp.mood, qp.author, qp.tags,
           qp.featured, qp.like_count, s.created_at as saved_at
    from public.saved_quotes s
    join public.quotes_public qp on qp.id = s.quote_id
    where s.visitor_id = p_visitor
    order by s.created_at desc
  ) t;
$$;

create or replace function public.toggle_feeling_like(p_feeling uuid, p_visitor uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_liked boolean; v_count bigint;
begin
  if p_visitor is null then raise exception 'visitor required'; end if;
  if not exists (select 1 from public.feelings where id = p_feeling and status = 'APPROVED') then
    raise exception 'feeling not available';
  end if;

  delete from public.feeling_likes where feeling_id = p_feeling and visitor_id = p_visitor;
  if not found then
    insert into public.feeling_likes (feeling_id, visitor_id) values (p_feeling, p_visitor)
      on conflict do nothing;
    v_liked := true;
  else
    v_liked := false;
  end if;

  select count(*) into v_count from public.feeling_likes where feeling_id = p_feeling;
  return json_build_object('liked', v_liked, 'count', v_count);
end $$;

-- Anonymous submission: honeypot + validation + rate limit,
-- always lands as PENDING (never auto-published).
create or replace function public.submit_feeling(
  p_content text, p_category text, p_mood text,
  p_anonymous boolean, p_name text, p_email text,
  p_visitor uuid, p_honey text default ''
) returns json language plpgsql security definer set search_path = public as $$
declare v_cat uuid; v_recent int;
begin
  if coalesce(p_honey, '') <> '' then
    return json_build_object('ok', true);          -- silently drop bots
  end if;
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

  insert into public.feelings (content, category_id, mood, is_anonymous, name, email, visitor_id, status)
  values (
    btrim(p_content), v_cat, left(coalesce(p_mood, 'Emotional'), 40),
    coalesce(p_anonymous, false),
    nullif(left(btrim(coalesce(p_name, '')), 80), ''),
    nullif(left(btrim(coalesce(p_email, '')), 200), ''),
    p_visitor, 'PENDING'
  );
  return json_build_object('ok', true);
end $$;

grant execute on function
  public.am_i_admin(),
  public.get_random_quote(uuid),
  public.get_todays_feeling(),
  public.get_my_activity(uuid),
  public.toggle_quote_like(uuid, uuid),
  public.toggle_quote_save(uuid, uuid),
  public.get_saved_quotes(uuid),
  public.toggle_feeling_like(uuid, uuid),
  public.submit_feeling(text, text, text, boolean, text, text, uuid, text)
to anon, authenticated;

-- ─── Seed: categories ───────────────────────────────────────────

insert into public.categories (name, sort) values
  ('Love', 10), ('Midnight Thoughts', 20), ('Friendship', 30), ('Life', 40),
  ('Heartfelt', 50), ('Healing', 60), ('Hope', 70), ('Unsaid Things', 80),
  ('Memories', 90), ('Random Thoughts', 100)
on conflict (name) do nothing;

-- ─── Seed: quotes (original SeRuh content) ──────────────────────

insert into public.quotes (quote, category_id, mood, tags, featured) values
  (E'Loving you was never loud.\nIt was the quietest thing I ever did\nwith my whole heart.', (select id from categories where name='Love'), 'Romantic', '{love,quiet,devotion}', false),
  ('Some people touch your life like light through a window — softly, and everywhere at once.', (select id from categories where name='Love'), 'Grateful', '{love,light,presence}', false),
  ('You are my favourite thought to return to.', (select id from categories where name='Love'), 'Romantic', '{love,thoughts,home}', false),
  ('I never learned the language you loved in — but I answered anyway, every time.', (select id from categories where name='Love'), 'Emotional', '{love,language,understanding}', false),
  ('Not every silence is empty.', (select id from categories where name='Midnight Thoughts'), 'Thoughtful', '{silence,night,depth}', true),
  (E'3 a.m. doesn''t ask questions.\nIt just sits with you while you remember.', (select id from categories where name='Midnight Thoughts'), 'Lonely', '{night,memories,missing}', false),
  ('The night knows every version of me the day has never met.', (select id from categories where name='Midnight Thoughts'), 'Thoughtful', '{night,identity,hidden}', false),
  ('Some thoughts only surface when the world stops watching.', (select id from categories where name='Midnight Thoughts'), 'Peaceful', '{night,thoughts,solitude}', false),
  ('The best friendships are the ones where silence feels like conversation.', (select id from categories where name='Friendship'), 'Peaceful', '{friendship,silence,comfort}', false),
  (E'You didn''t fix anything.\nYou just stayed.\nThat was everything.', (select id from categories where name='Friendship'), 'Grateful', '{friendship,staying,support}', false),
  ('Old friends are proof that some chapters never really close.', (select id from categories where name='Friendship'), 'Nostalgic', '{friendship,time,chapters}', false),
  (E'Life rarely announces its important days.\nThey arrive dressed as ordinary ones.', (select id from categories where name='Life'), 'Thoughtful', '{life,moments,ordinary}', false),
  ('We spend years learning to be someone — and the rest, learning to be ourselves.', (select id from categories where name='Life'), 'Thoughtful', '{life,self,growth}', false),
  ('Growing up is realising the small moments were the big ones.', (select id from categories where name='Life'), 'Nostalgic', '{life,growing,moments}', false),
  ('You are allowed to outgrow the life you once prayed for.', (select id from categories where name='Life'), 'Hopeful', '{life,growth,permission}', false),
  (E'Some feelings stay quiet,\nnot because they are small,\nbut because they are too deep for words.', (select id from categories where name='Heartfelt'), 'Emotional', '{feelings,depth,quiet}', true),
  (E'I carry conversations we never had,\nand somehow, they still hurt.', (select id from categories where name='Heartfelt'), 'Sad', '{unsaid,missing,ache}', false),
  ('The heart keeps a guest room ready for people who are never coming back.', (select id from categories where name='Heartfelt'), 'Lonely', '{missing,longing,heart}', false),
  (E'Healing is not forgetting.\nIt is remembering without drowning.', (select id from categories where name='Healing'), 'Hopeful', '{healing,memory,strength}', false),
  (E'One day the ache became a scar,\nand the scar became a story I could finally tell.', (select id from categories where name='Healing'), 'Emotional', '{healing,scars,stories}', false),
  ('Be gentle with yourself — you are still learning to live with what you survived.', (select id from categories where name='Healing'), 'Peaceful', '{healing,gentleness,self}', false),
  ('Some wounds close faster when you stop asking them to explain themselves.', (select id from categories where name='Healing'), 'Thoughtful', '{healing,acceptance,wounds}', false),
  ('Even the longest night keeps a little dawn in its pocket.', (select id from categories where name='Hope'), 'Hopeful', '{hope,night,dawn}', false),
  ('Hope is the quietest voice in the room — and somehow the last one standing.', (select id from categories where name='Hope'), 'Hopeful', '{hope,quiet,strength}', false),
  (E'Begin again.\nSoftly counts.', (select id from categories where name='Hope'), 'Peaceful', '{hope,beginnings,gentle}', false),
  ('The heaviest words are the ones we swallow.', (select id from categories where name='Unsaid Things'), 'Emotional', '{unsaid,words,weight}', false),
  (E'I wrote you a hundred letters.\nThe paper never knew.', (select id from categories where name='Unsaid Things'), 'Lonely', '{unsaid,letters,missing}', false),
  ('Between what I said and what I meant, there is a whole unlived life.', (select id from categories where name='Unsaid Things'), 'Thoughtful', '{unsaid,meaning,distance}', false),
  ('Some goodbyes happen in complete sentences no one ever speaks.', (select id from categories where name='Unsaid Things'), 'Sad', '{unsaid,goodbye,silence}', false),
  ('Memory is the only place where nothing ever has to end.', (select id from categories where name='Memories'), 'Nostalgic', '{memories,time,forever}', false),
  ('Some songs are time machines wearing melodies.', (select id from categories where name='Memories'), 'Nostalgic', '{memories,music,time}', false),
  (E'We never really leave the places that made us.\nWe just visit them less.', (select id from categories where name='Memories'), 'Nostalgic', '{memories,places,belonging}', false),
  ('Maybe the pause between two thoughts is where we actually live.', (select id from categories where name='Random Thoughts'), 'Thoughtful', '{thoughts,pause,presence}', false),
  ('Chai always tastes better when someone else remembers how you take it.', (select id from categories where name='Random Thoughts'), 'Happy', '{chai,care,small joys}', false),
  ('Rain is just the sky thinking out loud.', (select id from categories where name='Random Thoughts'), 'Peaceful', '{rain,sky,thoughts}', false),
  ('Half of growing older is missing versions of people who still exist.', (select id from categories where name='Random Thoughts'), 'Nostalgic', '{missing,time,people}', false);

-- ─── Seed: a few approved anonymous feelings for the wall ───────

insert into public.feelings (content, category_id, mood, is_anonymous, status) values
  (E'I still check my phone sometimes, knowing there won''t be a message.', (select id from categories where name='Unsaid Things'), 'Lonely', true, 'APPROVED'),
  ('I forgave you long ago. I just never found a reason to tell you.', (select id from categories where name='Healing'), 'Peaceful', true, 'APPROVED'),
  ('Some days I miss the person I was before I learned to be careful.', (select id from categories where name='Memories'), 'Nostalgic', true, 'APPROVED'),
  ('I hope the version of me you remember is kind to you.', (select id from categories where name='Heartfelt'), 'Emotional', true, 'APPROVED');

-- ═══════════════════════════════════════════════════════════════
--  FINAL STEP — grant admin access (run AFTER creating your user
--  in Authentication → Users → Add user). Replace the email:
--
--  insert into public.admins (user_id)
--  select id from auth.users where email = 'aapka-email@example.com'
--  on conflict do nothing;
-- ═══════════════════════════════════════════════════════════════
