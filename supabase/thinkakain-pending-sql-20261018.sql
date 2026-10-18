-- THINKAKAIN pending SQL — 2026-10-18 (Sunday morning)
-- One clean run covers everything still outstanding:
--   1. Fixed validate_magnet (L16) and validate_life (L19) — they now save progress, so clearing 16 unlocks 17.
--   2. Level 20 answer: yesterday
--   3. Level 21 answer: missyou
--   4. Level 22 answer: jesuswept
-- Every statement is idempotent (create or replace / on conflict do update) — safe to run even if some already ran.

create or replace function validate_magnet(p_level int, p_moves text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s       level_secrets%rowtype;
  v_size  int;
  v_wall  boolean[][];
  v_r     int[] := array[0,0,0];
  v_c     int[] := array[0,0,0];
  v_tr    int[] := array[0,0,0];
  v_tc    int[] := array[0,0,0];
  v_occ   boolean[][];
  v_order int[];
  v_dr int; v_dc int;
  v_ch text;
  v_i int; v_j int; v_k int; v_t int;
  v_nr int; v_nc int;
  v_tmp int;
  v_score int;
  w jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select * into s from level_secrets where level = p_level;
  if s.clues is null or p_moves is null then
    return jsonb_build_object('correct', false);
  end if;
  if length(p_moves) < 1 or length(p_moves) > 200 then
    return jsonb_build_object('correct', false);
  end if;

  v_size := coalesce((s.clues->>'size')::int, 7);
  v_wall := array_fill(false, array[v_size, v_size]);
  for w in select * from jsonb_array_elements(s.clues->'walls') loop
    v_wall[(w->>0)::int + 1][(w->>1)::int + 1] := true;
  end loop;
  for v_i in 0..2 loop
    v_r[v_i+1] := ((s.clues->'starts')->v_i->>0)::int;
    v_c[v_i+1] := ((s.clues->'starts')->v_i->>1)::int;
    v_tr[v_i+1] := ((s.clues->'targets')->v_i->>0)::int;
    v_tc[v_i+1] := ((s.clues->'targets')->v_i->>1)::int;
  end loop;

  for v_k in 1..length(p_moves) loop
    v_ch := substr(p_moves, v_k, 1);
    if v_ch = 'U' then v_dr := -1; v_dc := 0;
    elsif v_ch = 'D' then v_dr := 1; v_dc := 0;
    elsif v_ch = 'L' then v_dr := 0; v_dc := -1;
    elsif v_ch = 'R' then v_dr := 0; v_dc := 1;
    else return jsonb_build_object('correct', false);
    end if;

    v_order := array[1,2,3];
    for v_i in 1..2 loop
      for v_j in v_i+1..3 loop
        if (-(v_r[v_order[v_i]]*v_dr + v_c[v_order[v_i]]*v_dc)) >
           (-(v_r[v_order[v_j]]*v_dr + v_c[v_order[v_j]]*v_dc)) then
          v_tmp := v_order[v_i]; v_order[v_i] := v_order[v_j]; v_order[v_j] := v_tmp;
        end if;
      end loop;
    end loop;

    v_occ := array_fill(false, array[v_size, v_size]);
    for v_i in 1..3 loop
      v_occ[v_r[v_i]+1][v_c[v_i]+1] := true;
    end loop;

    for v_t in 1..3 loop
      v_i := v_order[v_t];
      v_occ[v_r[v_i]+1][v_c[v_i]+1] := false;
      loop
        v_nr := v_r[v_i] + v_dr; v_nc := v_c[v_i] + v_dc;
        exit when v_nr < 0 or v_nr >= v_size or v_nc < 0 or v_nc >= v_size;
        exit when v_wall[v_nr+1][v_nc+1];
        exit when v_occ[v_nr+1][v_nc+1];
        v_r[v_i] := v_nr; v_c[v_i] := v_nc;
      end loop;
      v_occ[v_r[v_i]+1][v_c[v_i]+1] := true;
    end loop;
  end loop;

  for v_i in 1..3 loop
    if v_r[v_i] <> v_tr[v_i] or v_c[v_i] <> v_tc[v_i] then
      return jsonb_build_object('correct', false);
    end if;
  end loop;
  perform _record_clear(p_level);
  return jsonb_build_object('correct', true);
end;
$$;

-- Level 19 life-stages validation: replays clicks, checks for nine teens.
create or replace function validate_life(p_level int, p_clicks int[])
returns jsonb
language plpgsql
security definer
as $$
declare
  v_boys int[];
  v_stages int[] := array[0,0,0,0,0,0,0,0,0,0];
  v_click int;
  v_teens int;
  v_clues jsonb;
begin
  select clues into v_clues from level_secrets where level = p_level;
  if v_clues is null then
    return jsonb_build_object('correct', false);
  end if;
  -- boys array from clues, e.g. {"boys":[0,2,5,7,9]}
  select array_agg(x::int) into v_boys
    from jsonb_array_elements_text(v_clues->'boys') as x;
  if v_boys is null then v_boys := array[]::int[]; end if;

  foreach v_click in array p_clicks loop
    if v_click < 0 or v_click > 9 then
      return jsonb_build_object('correct', false);
    end if;
    v_stages[v_click+1] := (v_stages[v_click+1] + 1) % 5;
    select count(*) into v_teens
      from unnest(v_stages) as s where s = 2;
    if v_teens = 9 then
      perform _record_clear(p_level);
      return jsonb_build_object('correct', true);
    end if;
  end loop;
  return jsonb_build_object('correct', false);
end;
$$;

-- Level 20 (newspaper: Beatles QR + Help! headline + Track 13 poster = Yesterday)
insert into level_secrets (level, answer)
  values (20, 'yesterday')
  on conflict (level) do update set answer = excluded.answer;

-- Level 21 (diary lipogram: no letter U in the whole page)
insert into level_secrets (level, answer)
  values (21, 'missyou')
  on conflict (level) do update set answer = excluded.answer;

-- Level 22 (desk: John nameplate + 11:35 clock = John 11:35, "Jesus wept")
insert into level_secrets (level, answer)
  values (22, 'jesuswept')
  on conflict (level) do update set answer = excluded.answer;
