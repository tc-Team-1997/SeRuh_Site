-- ═══════════════════════════════════════════════════════════════
--  SeRuh — Phase 5 migration: moderation engine repair
--  Run AFTER seruh-setup.sql, seruh-phase3-migration.sql and
--  seruh-phase4-migration.sql. Safe to run more than once.
--
--  Scope: public.moderate_text() ONLY.
--  No schema changes. No threshold changes. No other function,
--  view, policy or table is touched. mod_settings keeps its
--  configured flag_threshold (0.35) and reject_threshold (0.70).
--
--  What changes:
--   1. Category append no longer throws. `cats := cats || 'spam'`
--      was resolved by Postgres as anyarray || anyarray and raised
--      22P02 malformed array literal, so ANY content matching ANY
--      rule aborted the whole submission. Now array_append().
--   2. Directed abuse and threats are detected, in two tiers:
--        Tier 1 (+0.90, >= reject_threshold → blocked before insert)
--          unambiguous second-person threat or slur.
--        Tier 2 (+0.60, flag only → publishes, admin reviews)
--          phrases that also occur reflexively in genuine feelings
--          ("some days it feels like everyone hates you").
--      Both tiers are second-person only: a feeling about oneself
--      ("I feel worthless") must never be touched.
--   3. Contractions are matched. The alternation now carries its
--      own leading space — you( are|'re), i( will|'ll| am going to)
--      — because `you (are|'re)` only ever matched "you 're".
-- ═══════════════════════════════════════════════════════════════

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
    score := score + 0.95; cats := array_append(cats, 'malicious');
  elsif t ~ '<\s*[a-z]+[^>]*>' then
    score := score + 0.5; cats := array_append(cats, 'html');
  end if;
  if t ~ '(union\s+(all\s+)?select|insert\s+into\s+\w|drop\s+table|xp_cmdshell|;\s*delete\s+from)' then
    score := score + 0.9; cats := array_append(cats, 'malicious');
  end if;

  -- links & promotion (spam)
  links := (char_length(t) - char_length(replace(replace(t, 'http://', ''), 'https://', ''))) / 7;
  if links >= 2 then score := score + 0.6; cats := array_append(cats, 'spam');
  elsif links = 1 then score := score + 0.3; cats := array_append(cats, 'links');
  end if;
  if t ~ '(buy now|click here|limited offer|promo code|discount code|earn money|make \$|whatsapp me|call me at|dm for|follow me|subscribe to|free followers|crypto invest|loan approval)' then
    score := score + 0.55; cats := array_append(cats, 'spam');
  end if;

  -- severe abuse / threats / self-harm encouragement
  if t ~ '(kill yourself|kys\M|go die\M|you should die|i will kill|i''ll kill|rape you|deserve to be raped|behead|lynch)' then
    score := score + 0.95; cats := array_append(cats, 'abuse');
  end if;
  if t ~ '(bomb (the|a)|plant a bomb|shoot up|attack (the|a) (school|temple|mosque|church))' then
    score := score + 0.95; cats := array_append(cats, 'threat');
  end if;

  -- Tier 1 — directed threat or slur aimed at another person.
  -- Weighted to clear reject_threshold on its own: this content is
  -- blocked before insert and never reaches the public wall.
  if t ~ '(i( will|''ll| am going to) (hurt|beat) you|you( are|''re) (a |an |such a )?(worthless|stupid|pathetic|disgusting) (idiot|loser|person|trash|piece)|you( are|''re) (trash|garbage))' then
    score := score + 0.90; cats := array_append(cats, 'abuse');
  end if;

  -- Tier 2 — same register, but these phrasings also carry a
  -- reflexive/generic "you" in genuine emotional writing, so they
  -- flag for review rather than block. The guard drops the common
  -- consoling construction ("it is not that nobody wants you...").
  if t ~ '(everyone hates you|nobody (loves|likes|wants) you)'
     and t !~ '(not that|n''t that|not because) nobody (loves|likes|wants) you' then
    score := score + 0.60; cats := array_append(cats, 'abuse');
  end if;

  -- harassment-ish profanity (moderate)
  if t ~ '\m(bitch|bastard|asshole|chutiya|madarchod|behenchod|randi|kamina|haramzada|whore|slut)\M' then
    score := score + 0.45; cats := array_append(cats, 'profanity');
  end if;

  -- bot-ish noise
  if t ~ '(.)\1{7,}' then score := score + 0.15; cats := array_append(cats, 'noise'); end if;

  return json_build_object(
    'score', least(1.0, score),
    'categories', to_json(cats),
    'reason', case when array_length(cats,1) is null then null else array_to_string(cats, ', ') end
  );
end $$;

-- ─── Self-test: fails loudly rather than silently mis-scoring ───
-- Reads mod_settings so the assertions track the configured
-- thresholds instead of hard-coding 0.35 / 0.70.
do $$
declare
  reject numeric;
  flagat numeric;
  s      numeric;
  fails  text[] := '{}';

  procedure_note text;

  -- must be blocked outright (score >= reject_threshold)
  block_cases text[] := array[
    'You are a worthless idiot and I will hurt you. Everyone hates you, you stupid trash.',
    'i''ll hurt you if you keep talking',
    'i am going to beat you up',
    'you''re such a stupid loser',
    'you are trash and always will be',
    'you''re garbage, honestly',
    '<script>alert(document.cookie)</script> I feel sad',
    'Buy now! click here https://a.example https://b.example',
    'kill yourself you worthless person'
  ];

  -- must publish untouched (score < flag_threshold)
  allow_cases text[] := array[
    'I miss the person I used to be.',
    'I know I will find you again in another life.',
    'I will get you through this, I promise.',
    'You are nothing short of everything I never knew I needed.',
    'You are nothing but kind, even when I gave you no reason.',
    'It is not that nobody wants you - it is that you stopped asking.',
    'I feel worthless today, like nobody would notice if I disappeared for a while.',
    'I feel stupid for still waiting on someone who never looked back.',
    'Sometimes the thing you want to hold is the thing that hurts you the most.',
    'You are a person I keep writing letters to and never sending.',
    'you''re the reason I still believe in soft things'
  ];

  -- must publish, but be surfaced to an admin
  flag_cases text[] := array[
    'Some days it feels like everyone hates you and you cannot explain why.',
    'you are such a bitch and i hate you'
  ];
begin
  select reject_threshold, flag_threshold into reject, flagat from public.mod_settings where id = 1;

  foreach procedure_note in array block_cases loop
    s := (public.moderate_text(procedure_note) ->> 'score')::numeric;
    if s < reject then
      fails := array_append(fails, format('NOT BLOCKED (%s < %s): %s', s, reject, left(procedure_note, 44)));
    end if;
  end loop;

  foreach procedure_note in array allow_cases loop
    s := (public.moderate_text(procedure_note) ->> 'score')::numeric;
    if s >= flagat then
      fails := array_append(fails, format('FALSE POSITIVE (%s >= %s): %s', s, flagat, left(procedure_note, 44)));
    end if;
  end loop;

  foreach procedure_note in array flag_cases loop
    s := (public.moderate_text(procedure_note) ->> 'score')::numeric;
    if s < flagat or s >= reject then
      fails := array_append(fails, format('NOT FLAGGED (%s): %s', s, left(procedure_note, 44)));
    end if;
  end loop;

  if array_length(fails, 1) is not null then
    raise exception E'moderate_text self-test failed:\n%', array_to_string(fails, E'\n');
  end if;

  raise notice 'moderate_text self-test passed: % blocked, % allowed, % flagged (reject >= %, flag >= %)',
    array_length(block_cases, 1), array_length(allow_cases, 1), array_length(flag_cases, 1), reject, flagat;
end $$;
