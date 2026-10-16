-- ============================================================
-- THINKAKAIN — Supabase schema (fresh start)
-- SAFE TO COMMIT: this file contains NO answers or secrets.
-- All answers live in seed.sql, which must NEVER be committed.
--
-- Run once in the Supabase SQL editor (Database → SQL → New query).
-- Wipes the previous build's tables first, so it's safe to run
-- on the existing project.
-- ============================================================

-- ---- clear the previous build (old floor_* names and current level_* names) ----
drop table if exists public.floor_marks;
drop table if exists public.floor_clears;
drop table if exists public.progress;
drop table if exists public.profiles;
drop table if exists public.floor_secrets;
drop table if exists public.level_clears;
drop table if exists public.level_secrets;

-- ---------------- tables ----------------

create table profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  username   text not null,
  created_at timestamptz not null default now()
);
-- usernames are unique case-insensitively ("Nopy" vs "nopy" collide)
create unique index profiles_username_lower_uidx
  on profiles (lower(username));

-- THE VAULT. RLS enabled, zero policies: no client access at all.
create table level_secrets (
  level       int primary key,
  answer      text,   -- passcode levels (NULL for hold / sequence levels)
  hold_answer text,   -- hold levels: word whose letter count = hold seconds
  sequence    int[],  -- sequence levels: correct id order
  clues       jsonb not null default '{}' -- public display data, never answers
);

create table progress (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  username      text,
  highest_level int not null default 1,
  updated_at    timestamptz not null default now()
);

-- Clears are written ONLY by the SECURITY DEFINER functions below.
create table level_clears (
  user_id    uuid not null references auth.users(id) on delete cascade,
  level      int  not null,
  cleared_at timestamptz not null default now(),
  primary key (user_id, level)
);

-- ---------------- Row Level Security ----------------

alter table profiles      enable row level security;
alter table level_secrets enable row level security;
alter table progress      enable row level security;
alter table level_clears  enable row level security;

create policy "profiles: owner read"
  on profiles for select using (auth.uid() = user_id);

create policy "progress: owner read"
  on progress for select using (auth.uid() = user_id);
create policy "progress: owner update"
  on progress for update using (auth.uid() = user_id);
-- NOTE: no INSERT policy on progress — rows are created by ensure_profile().

create policy "level_clears: owner read"
  on level_clears for select using (auth.uid() = user_id);

-- ---------------- helpers & RPC ----------------
-- The old build's functions used p_floor parameter names; Postgres
-- refuses CREATE OR REPLACE when parameter names change, so drop
-- the old signatures first.

drop function if exists _record_clear(integer);
drop function if exists get_floor_clues(integer);
drop function if exists validate_guess(integer, text);
drop function if exists validate_hold(integer, integer);
drop function if exists validate_sequence(integer, integer[]);
drop function if exists validate_boss(integer, text);
-- (in case of a partial earlier run)
drop function if exists get_level_clues(integer);

-- Record a clear and bump highest_level.
create or replace function _record_clear(p_level int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into level_clears (user_id, level)
    values (auth.uid(), p_level)
    on conflict do nothing;
  insert into progress (user_id, highest_level)
    values (auth.uid(), least(p_level + 1, 30))
    on conflict (user_id) do update set
      highest_level = greatest(progress.highest_level, least(p_level + 1, 30)),
      updated_at = now();
end;
$$;

-- Register / backfill the player's profile + progress rows.
-- Raises 'username taken' when the name belongs to someone else.
create or replace function ensure_profile(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := trim(p_username);
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if v_username !~ '^[A-Za-z0-9_]{3,16}$' then
    raise exception 'invalid username (3-16 chars: letters, numbers, underscore)';
  end if;
  if exists (select 1 from profiles
              where lower(username) = lower(v_username)
                and user_id <> auth.uid()) then
    raise exception 'username taken';
  end if;
  insert into profiles (user_id, username)
    values (auth.uid(), v_username)
    on conflict (user_id) do update set username = excluded.username;
  insert into progress (user_id, username)
    values (auth.uid(), v_username)
    on conflict (user_id) do update set username = excluded.username;
  return jsonb_build_object('username', v_username);
end;
$$;

-- Public per-level display data. Never includes answers.
create or replace function get_level_clues(p_level int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select clues into v from level_secrets where level = p_level;
  return coalesce(v, '{}'::jsonb);
end;
$$;

-- Passcode levels. Returns {correct}.
create or replace function validate_guess(p_level int, p_guess text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s  level_secrets%rowtype;
  ok boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from level_secrets where level = p_level;
  if s.answer is not null
     and upper(trim(coalesce(p_guess, ''))) = upper(trim(s.answer)) then
    ok := true;
    perform _record_clear(p_level);
  end if;
  return jsonb_build_object('correct', ok);
end;
$$;

-- Hold levels. Server knows the word; target = letters × 1000ms, ±400ms.
create or replace function validate_hold(p_level int, p_hold_ms int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s      level_secrets%rowtype;
  target int;
  ok     boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from level_secrets where level = p_level;
  if s.hold_answer is not null then
    target := char_length(s.hold_answer) * 1000;
    if abs(p_hold_ms - target) <= 400 then
      ok := true;
      perform _record_clear(p_level);
    end if;
  end if;
  return jsonb_build_object('correct', ok);
end;
$$;

-- Sequence levels. p_seq is the clicked ids, in order.
create or replace function validate_sequence(p_level int, p_seq int[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s  level_secrets%rowtype;
  ok boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from level_secrets where level = p_level;
  if s.sequence is not null and p_seq = s.sequence then
    ok := true;
    perform _record_clear(p_level);
  end if;
  return jsonb_build_object('correct', ok);
end;
$$;

-- Evaluate a simple arithmetic expression: non-negative integers
-- with x, +, - (no parentheses). Standard precedence (x before
-- +-). Returns NULL on malformed input.
create or replace function _eval_simple(p_expr text)
returns int
language plpgsql
immutable
as $$
declare
  nums int[]  := array[]::int[];
  ops  text[] := array[]::text[];
  cur  text := '';
  ch   text;
  i    int;
  n    int;
begin
  if p_expr is null or p_expr !~ '^[0-9]+([x+\-][0-9]+)*$' then
    return null;
  end if;

  for i in 1..char_length(p_expr) loop
    ch := substr(p_expr, i, 1);
    if ch ~ '[0-9]' then
      cur := cur || ch;
    else
      nums := nums || cur::int;
      ops  := ops || ch;
      cur  := '';
    end if;
  end loop;
  nums := nums || cur::int;

  -- multiplication first, left to right
  i := 1;
  while i <= coalesce(array_length(ops, 1), 0) loop
    if ops[i] = 'x' then
      nums[i] := nums[i] * nums[i+1];
      nums := (select coalesce(array_agg(v order by o), array[]::int[])
               from unnest(nums) with ordinality as t(v, o) where o <> i + 1);
      ops  := (select coalesce(array_agg(v order by o), array[]::text[])
               from unnest(ops) with ordinality as t(v, o) where o <> i);
    else
      i := i + 1;
    end if;
  end loop;

  -- then addition / subtraction, left to right
  n := nums[1];
  for i in 1..coalesce(array_length(ops, 1), 0) loop
    if ops[i] = '+' then n := n + nums[i+1];
    else n := n - nums[i+1]; end if;
  end loop;
  return n;
end;
$$;

-- Equation levels (e.g. tile-arranging). The player submits the full
-- arrangement; it passes when (a) it uses exactly the puzzle's tiles
-- (order-free multiset match against the stored answer) and (b) both
-- sides evaluate to the same value. Any true arrangement counts.
create or replace function validate_equation(p_level int, p_expr text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e     text := regexp_replace(coalesce(p_expr, ''), '\s+', '', 'g');
  s     level_secrets%rowtype;
  parts text[];
  lv    int;
  rv    int;
  ok    boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from level_secrets where level = p_level;
  if s.answer is null then
    return jsonb_build_object('correct', false);
  end if;
  if e !~ '^[0-9x+\-=]+$' then
    return jsonb_build_object('correct', false);
  end if;
  if (select string_agg(c, '' order by c) from regexp_split_to_table(e, '') as c)
     <> (select string_agg(c, '' order by c) from regexp_split_to_table(s.answer, '') as c) then
    return jsonb_build_object('correct', false);
  end if;
  parts := string_to_array(e, '=');
  if array_length(parts, 1) <> 2 then
    return jsonb_build_object('correct', false);
  end if;
  lv := _eval_simple(parts[1]);
  rv := _eval_simple(parts[2]);
  if lv is not null and rv is not null and lv = rv then
    ok := true;
    perform _record_clear(p_level);
  end if;
  return jsonb_build_object('correct', ok);
end;
$$;

-- Pouring levels (water jugs). The client submits the move list as
-- [[from_idx, to_idx], ...]; the server replays the physics from the
-- start state in clues and passes when the top amounts match the goal.
-- clues: {"caps": [...], "start": [...], "goal": [...]}
create or replace function validate_pours(p_level int, p_moves jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s     level_secrets%rowtype;
  caps  int[];
  state int[];
  goal  int[];
  m     jsonb;
  f     int;
  t     int;
  amt   int;
  srt   int[];
  ok    boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from level_secrets where level = p_level;
  if s.clues is null or jsonb_typeof(p_moves) <> 'array' then
    return jsonb_build_object('correct', false);
  end if;
  if jsonb_array_length(p_moves) < 1 or jsonb_array_length(p_moves) > 500 then
    return jsonb_build_object('correct', false);
  end if;
  select coalesce(array_agg(v order by o), array[]::int[]) into caps
    from (select (x::int) as v, o
          from jsonb_array_elements_text(s.clues->'caps') with ordinality as t(x, o)) sub;
  select coalesce(array_agg(v order by o), array[]::int[]) into state
    from (select (x::int) as v, o
          from jsonb_array_elements_text(s.clues->'start') with ordinality as t(x, o)) sub;
  select coalesce(array_agg(v order by o), array[]::int[]) into goal
    from (select (x::int) as v, o
          from jsonb_array_elements_text(s.clues->'goal') with ordinality as t(x, o)) sub;
  if array_length(caps, 1) is null or array_length(state, 1) is null
     or array_length(goal, 1) is null
     or array_length(caps, 1) <> array_length(state, 1) then
    return jsonb_build_object('correct', false);
  end if;

  for m in select * from jsonb_array_elements(p_moves) loop
    f := (m->>0)::int;
    t := (m->>1)::int;
    if f is null or t is null
       or f < 0 or t < 0
       or f >= array_length(caps, 1) or t >= array_length(caps, 1)
       or f = t then
      return jsonb_build_object('correct', false);
    end if;
    if state[f+1] <= 0 or state[t+1] >= caps[t+1] then
      return jsonb_build_object('correct', false);
    end if;
    amt := least(state[f+1], caps[t+1] - state[t+1]);
    state[f+1] := state[f+1] - amt;
    state[t+1] := state[t+1] + amt;
  end loop;

  select array_agg(v order by v desc) into srt from unnest(state) as v;
  if srt[1:array_length(goal, 1)] = goal then
    ok := true;
    perform _record_clear(p_level);
  end if;
  return jsonb_build_object('correct', ok);
end;
$$;

-- ============================================================
-- LEVEL DATA (everything below is secret)
-- ============================================================

-- Level 1 (Backwards): the reversed word on the page
insert into level_secrets (level, answer)
  values (1, 'MIRROR')
  on conflict (level) do update set answer = excluded.answer;

-- Level 2 (blackout): black text on black background
insert into level_secrets (level, answer)
  values (2, 'INVISIBLE')
  on conflict (level) do update set answer = excluded.answer;

-- Level 3 (equation): tile multiset reference — any true arrangement passes
insert into level_secrets (level, answer)
  values (3, '8x4=33+6-7')
  on conflict (level) do update set answer = excluded.answer;

-- Level 4 (keyboard): K,E,Y,W,O,R,D letters removed from Nopy's photo
insert into level_secrets (level, answer)
  values (4, 'KEYWORD')
  on conflict (level) do update set answer = excluded.answer;

-- Level 5 (water jugs): 14L full, 9L + 5L empty — goal is two 7s.
-- clues holds the physics; the server replays the submitted pours.
insert into level_secrets (level, clues)
  values (5, '{"caps": [14, 9, 5], "start": [14, 0, 0], "goal": [7, 7]}'::jsonb)
  on conflict (level) do update set clues = excluded.clues;

-- Level 6 (Snape): "Always."
insert into level_secrets (level, answer)
  values (6, 'ALWAYS')
  on conflict (level) do update set answer = excluded.answer;

-- Level 7 (morse): - .... .. -. -.-  = THINK
insert into level_secrets (level, answer)
  values (7, 'THINK')
  on conflict (level) do update set answer = excluded.answer;
