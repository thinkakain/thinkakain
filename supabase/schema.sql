-- ============================================================
-- OVERTHINK — Supabase schema
-- SAFE TO COMMIT: this file contains NO answers, marks, or secrets.
-- All secrets live in seed.sql, which must NEVER be committed.
--
-- Run once in the Supabase SQL editor (Database → SQL → New query),
-- or apply with the Supabase CLI.
-- ============================================================

-- ---------------- tables ----------------

create table if not exists profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  username   text not null,
  created_at timestamptz not null default now()
);
-- usernames are unique case-insensitively ("Nopy" vs "nopy" collide)
create unique index if not exists profiles_username_lower_uidx
  on profiles (lower(username));

-- THE VAULT. Client code must never read this table.
create table if not exists floor_secrets (
  floor       int primary key,
  answer      text,   -- passcode floors (NULL for hold / sequence / boss floors)
  mark        char(1),-- mark letter awarded on clear (NULL for boss gates)
  hold_answer text,   -- hold floors: word whose letter count = hold seconds
  sequence    int[],  -- sequence floors: star ids in story order
  clues       jsonb not null default '{}' -- public per-floor display data (no answers)
);

create table if not exists progress (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  username      text,
  highest_floor int not null default 1,
  updated_at    timestamptz not null default now()
);

-- Marks are written ONLY by the SECURITY DEFINER functions below.
create table if not exists floor_marks (
  user_id   uuid not null references auth.users(id) on delete cascade,
  floor     int  not null,
  mark      char(1) not null,
  earned_at timestamptz not null default now(),
  primary key (user_id, floor)
);

create table if not exists floor_clears (
  user_id    uuid not null references auth.users(id) on delete cascade,
  floor      int  not null,
  cleared_at timestamptz not null default now(),
  primary key (user_id, floor)
);

-- ---------------- Row Level Security ----------------
-- floor_secrets gets NO policies at all: with RLS enabled and zero
-- policies, every client read/write is denied. The SECURITY DEFINER
-- functions below bypass RLS and are the only path to the answers.

alter table profiles      enable row level security;
alter table floor_secrets enable row level security;
alter table progress      enable row level security;
alter table floor_marks   enable row level security;
alter table floor_clears  enable row level security;

create policy "profiles: owner read"
  on profiles for select using (auth.uid() = user_id);

create policy "progress: owner read"
  on progress for select using (auth.uid() = user_id);
create policy "progress: owner update"
  on progress for update using (auth.uid() = user_id);
-- NOTE: no INSERT policy on progress — rows are created by ensure_profile().
-- Clients *can* UPDATE their own highest_floor (cosmetic unlock display),
-- but boss gates and marks are enforced server-side, so this grants no answers.

create policy "floor_marks: owner read"
  on floor_marks for select using (auth.uid() = user_id);

create policy "floor_clears: owner read"
  on floor_clears for select using (auth.uid() = user_id);

-- ---------------- helpers & RPC ----------------

-- Record a clear: mark (if any), clear row, and bump highest_floor.
create or replace function _record_clear(p_floor int, p_mark char(1))
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into floor_clears (user_id, floor)
    values (auth.uid(), p_floor)
    on conflict do nothing;
  if p_mark is not null then
    insert into floor_marks (user_id, floor, mark)
      values (auth.uid(), p_floor, p_mark)
      on conflict do nothing;
  end if;
  insert into progress (user_id, highest_floor)
    values (auth.uid(), least(p_floor + 1, 30))
    on conflict (user_id) do update set
      highest_floor = greatest(progress.highest_floor, least(p_floor + 1, 30)),
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

-- Public per-floor display data (ticker words, canvas word, story HTML…).
-- Never includes answers or marks.
create or replace function get_floor_clues(p_floor int)
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
  select clues into v from floor_secrets where floor = p_floor;
  return coalesce(v, '{}'::jsonb);
end;
$$;

-- Passcode floors. Returns {correct, mark} — mark only when correct.
create or replace function validate_guess(p_floor int, p_guess text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s  floor_secrets%rowtype;
  ok boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from floor_secrets where floor = p_floor;
  if s.answer is not null
     and upper(trim(coalesce(p_guess, ''))) = upper(trim(s.answer)) then
    ok := true;
    perform _record_clear(p_floor, s.mark);
  end if;
  return jsonb_build_object(
    'correct', ok,
    'mark', case when ok then s.mark else null end
  );
end;
$$;

-- Hold floors (F8). Server knows the riddle word; target = letters × 1000ms.
-- Accepts within ±400ms.
create or replace function validate_hold(p_floor int, p_hold_ms int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s      floor_secrets%rowtype;
  target int;
  ok     boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from floor_secrets where floor = p_floor;
  if s.hold_answer is not null then
    target := char_length(s.hold_answer) * 1000;
    if abs(p_hold_ms - target) <= 400 then
      ok := true;
      perform _record_clear(p_floor, s.mark);
    end if;
  end if;
  return jsonb_build_object(
    'correct', ok,
    'mark', case when ok then s.mark else null end
  );
end;
$$;

-- Sequence floors (F9). p_seq is the clicked star ids, in click order.
create or replace function validate_sequence(p_floor int, p_seq int[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s  floor_secrets%rowtype;
  ok boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from floor_secrets where floor = p_floor;
  if s.sequence is not null and p_seq = s.sequence then
    ok := true;
    perform _record_clear(p_floor, s.mark);
  end if;
  return jsonb_build_object(
    'correct', ok,
    'mark', case when ok then s.mark else null end
  );
end;
$$;

-- Boss gates (floors 5, 10, …). Compares the player's letters against the
-- marks THEY earned on the previous four floors (server-side records).
create or replace function validate_boss(p_floor int, p_letters text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  lo       int := p_floor - 4;
  hi       int := p_floor - 1;
  expected text;
  cnt      int;
  ok       boolean := false;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select string_agg(m.mark, '' order by m.floor), count(*)
    into expected, cnt
    from floor_marks m
   where m.user_id = auth.uid()
     and m.floor between lo and hi;
  if cnt = 4 and expected is not null
     and upper(trim(coalesce(p_letters, ''))) = upper(expected) then
    ok := true;
    perform _record_clear(p_floor, null); -- boss gates award no mark
  end if;
  return jsonb_build_object('correct', ok);
end;
$$;
