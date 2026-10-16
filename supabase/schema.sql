-- ============================================================
-- THINKAKAIN — Supabase schema (fresh start)
-- SAFE TO COMMIT: this file contains NO answers or secrets.
-- All answers live in seed.sql, which must NEVER be committed.
--
-- Run once in the Supabase SQL editor (Database → SQL → New query).
-- Wipes the previous build's tables first, so it's safe to run
-- on the existing project.
-- ============================================================

-- ---- clear the previous build ----
drop table if exists public.floor_marks;
drop table if exists public.floor_clears;
drop table if exists public.progress;
drop table if exists public.profiles;
drop table if exists public.floor_secrets;

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
