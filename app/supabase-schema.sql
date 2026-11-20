-- ============================================================================
-- Nava Bhasha — The Nine Tongues League · Supabase schema (v2, hardened)
-- Run this once in your Supabase project: Dashboard → SQL Editor → New query
-- → paste → Run. Safe to re-run (guards use IF NOT EXISTS / OR REPLACE).
--
-- v2 (2026-11-19) — session-integrity hardening, from Perp's code review,
-- applied by Ganessa to the existing app (no interface changes):
--   1. Points are computed SERVER-SIDE by record_session(). Clients can no
--      longer write points directly — track_progress and sessions are
--      read-only for clients; all writes flow through the functions below.
--   2. Sessions are validated in the database: real track ids only, at most
--      two distinct satellites, known scripts only, no future dates,
--      minutes/points within sane bounds (CHECK constraints + RPC checks).
--   3. Duplicate protection: every submission carries a request UUID; a
--      retry returns the original session instead of double-counting.
--   4. Atomicity: the session row and the track totals it earns are written
--      in ONE transaction inside record_session(), so the two can never
--      drift apart.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- One row per signed-up user.
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now()
);

-- One row per user per language track (nine rows per user).
-- track ids: tamil, malayalam, telugu, hindi, german, spanish,
--            english_us, english_uk, english_core
create table if not exists public.track_progress (
  user_id        uuid not null references auth.users (id) on delete cascade,
  track          text not null check (track in (
                   'tamil','malayalam','telugu','hindi','german','spanish',
                   'english_us','english_uk','english_core')),
  level          int  not null default 0 check (level between 0 and 5),
  points         int  not null default 0 check (points >= 0),
  last_practiced date,
  primary key (user_id, track)
);

-- One row per logged session (a boss-fight record is also a session row,
-- with boss_fight set to 'win' or 'showed_up').
-- v2: validated columns + a request_id for idempotent submissions.
create table if not exists public.sessions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  session_date     date not null default current_date,
  anchor_track     text check (anchor_track is null or anchor_track in (
                     'tamil','malayalam','telugu','hindi','german','spanish',
                     'english_us','english_uk','english_core')),
  satellite_tracks text[] not null default '{}' check (
                     satellite_tracks <@ array[
                       'tamil','malayalam','telugu','hindi','german','spanish',
                       'english_us','english_uk','english_core']::text[]
                     and cardinality(satellite_tracks) <= 2),
  script           text check (script is null or script in (
                     'Tamil','Devanagari','Telugu','Malayalam')),
  minutes          int not null default 0 check (minutes between 0 and 120),
  points           int not null default 0 check (points between 0 and 1000),
  eclipse          boolean not null default false,
  boss_fight       text check (boss_fight in ('win', 'showed_up')),
  request_id       uuid,
  created_at       timestamptz not null default now()
);

-- If upgrading a database that already ran v1, add the new column in place.
alter table public.sessions
  add column if not exists request_id uuid;

-- Upgrade guards: on a database that already ran v1, the tables above were
-- created by the old script, so re-apply the v2 CHECK constraints by name.
-- (On a fresh install these duplicate the inline checks — harmless.)
alter table public.track_progress
  drop constraint if exists track_progress_points_nonneg;
alter table public.track_progress
  add constraint track_progress_points_nonneg check (points >= 0);

alter table public.sessions
  drop constraint if exists sessions_minutes_range;
alter table public.sessions
  add constraint sessions_minutes_range check (minutes between 0 and 120);

alter table public.sessions
  drop constraint if exists sessions_points_range;
alter table public.sessions
  add constraint sessions_points_range check (points between 0 and 1000);

alter table public.sessions
  drop constraint if exists sessions_anchor_track_valid;
alter table public.sessions
  add constraint sessions_anchor_track_valid check (
    anchor_track is null or anchor_track in (
      'tamil','malayalam','telugu','hindi','german','spanish',
      'english_us','english_uk','english_core'));

alter table public.sessions
  drop constraint if exists sessions_satellites_valid;
alter table public.sessions
  add constraint sessions_satellites_valid check (
    satellite_tracks <@ array[
      'tamil','malayalam','telugu','hindi','german','spanish',
      'english_us','english_uk','english_core']::text[]
    and cardinality(satellite_tracks) <= 2);

alter table public.sessions
  drop constraint if exists sessions_script_valid;
alter table public.sessions
  add constraint sessions_script_valid check (
    script is null or script in ('Tamil','Devanagari','Telugu','Malayalam'));

create index if not exists sessions_user_date_idx
  on public.sessions (user_id, session_date desc);

-- Idempotency: one stored session per (user, request).
create unique index if not exists sessions_user_request_uidx
  on public.sessions (user_id, request_id)
  where request_id is not null;

-- ---------------------------------------------------------------------------
-- Row Level Security — clients can READ their own rows and nothing else.
-- Every write goes through the security-definer functions further down,
-- which validate first and write as the database owner.
-- ---------------------------------------------------------------------------

alter table public.profiles       enable row level security;
alter table public.track_progress enable row level security;
alter table public.sessions       enable row level security;

-- profiles: read own row; update own display_name only (column grant below).
drop policy if exists "profiles: own row" on public.profiles;
drop policy if exists "profiles: read own" on public.profiles;
create policy "profiles: read own" on public.profiles
  for select
  using (auth.uid() = id);

drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

revoke update on public.profiles from authenticated;
grant update (display_name) on public.profiles to authenticated;

-- track_progress: read-only for clients (points/levels change via RPC only).
drop policy if exists "track_progress: own rows" on public.track_progress;
drop policy if exists "track_progress: read own" on public.track_progress;
create policy "track_progress: read own" on public.track_progress
  for select
  using (auth.uid() = user_id);

-- sessions: read-only for clients (new sessions are recorded via RPC only).
drop policy if exists "sessions: own rows" on public.sessions;
drop policy if exists "sessions: read own" on public.sessions;
create policy "sessions: read own" on public.sessions
  for select
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Signup bootstrap — when a new auth user is created, give them a profile
-- row and the nine track_progress rows (all Level 0 / Unplaced, 0 points).
-- The app ALSO calls ensure_my_profile() on first dashboard load, so the
-- app works even if this trigger is removed.
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'display_name',
      split_part(new.email, '@', 1)
    )
  )
  on conflict (id) do nothing;

  insert into public.track_progress (user_id, track)
  select new.id, t.track
  from (values
    ('tamil'), ('malayalam'), ('telugu'), ('hindi'), ('german'),
    ('spanish'), ('english_us'), ('english_uk'), ('english_core')
  ) as t(track)
  on conflict (user_id, track) do nothing;

  return new;
end;
$$;

-- The trigger calls this function; nobody should call it directly.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- ensure_my_profile() — idempotent backfill for the signed-in user:
-- creates the profile row and any missing track rows (all zeroed).
-- Replaces the app's old direct inserts into profiles / track_progress.
-- ---------------------------------------------------------------------------

create or replace function public.ensure_my_profile()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_name text;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;

  select coalesce(
           raw_user_meta_data ->> 'display_name',
           split_part(email, '@', 1)
         )
    into v_name
    from auth.users
   where id = v_uid;

  insert into public.profiles (id, display_name)
  values (v_uid, v_name)
  on conflict (id) do nothing;

  insert into public.track_progress (user_id, track)
  select v_uid, t.track
  from (values
    ('tamil'), ('malayalam'), ('telugu'), ('hindi'), ('german'),
    ('spanish'), ('english_us'), ('english_uk'), ('english_core')
  ) as t(track)
  on conflict (user_id, track) do nothing;
end;
$$;

revoke execute on function public.ensure_my_profile() from public, anon;
grant  execute on function public.ensure_my_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- set_track_level() — the ONLY way a client changes a level.
-- Validates the track id and the 0..5 range, then upserts the level.
-- ---------------------------------------------------------------------------

create or replace function public.set_track_level(p_track text, p_level int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if p_track not in (
       'tamil','malayalam','telugu','hindi','german','spanish',
       'english_us','english_uk','english_core') then
    raise exception 'unknown track: %', p_track;
  end if;
  if p_level is null or p_level < 0 or p_level > 5 then
    raise exception 'level out of range: %', p_level;
  end if;

  insert into public.track_progress (user_id, track, level)
  values (v_uid, p_track, p_level)
  on conflict (user_id, track)
  do update set level = excluded.level;
end;
$$;

revoke execute on function public.set_track_level(text, int) from public, anon;
grant  execute on function public.set_track_level(text, int) to authenticated;

-- ---------------------------------------------------------------------------
-- record_session() — the ONLY way a client records a session.
--
-- The client sends WHAT WAS DONE (which blocks were ticked), never points.
-- This function recomputes minutes and points from the league rules:
--   normal day : anchor 150 pts / 15 min · each satellite 50 / 5 ·
--                script sprint 50 / 5 (credited to the script's track)
--   eclipse day: anchor only, 100 pts / 10 min (streak-safe minimum)
--   boss fight : win 100 pts, showed up 25 pts, 10 min, on the chosen track
-- It then inserts the session row and adds the earned points to the track
-- totals in the SAME transaction, so history and totals cannot drift.
--
-- Idempotency: p_request_id is generated by the client per submission and
-- kept across retries; a repeated call returns the stored session without
-- applying points twice. A per-user advisory lock serializes submissions.
-- ---------------------------------------------------------------------------

create or replace function public.record_session(
  p_request_id       uuid,
  p_session_date     date,
  p_anchor_track     text default null,
  p_satellite_tracks text[] default '{}',
  p_script           text default null,
  p_eclipse          boolean default false,
  p_boss_fight       text default null
)
returns public.sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_existing public.sessions;
  v_row      public.sessions;
  v_date     date := coalesce(p_session_date, current_date);
  v_sats     text[] := coalesce(p_satellite_tracks, '{}');
  v_minutes  int := 0;
  v_points   int := 0;
  v_per      jsonb := '{}'::jsonb;
  v_track    text;
  v_pts      int;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required';
  end if;

  -- Serialize this user's submissions; makes the idempotency check race-safe.
  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  -- Idempotent retry: this request was already recorded.
  select * into v_existing
    from public.sessions
   where user_id = v_uid and request_id = p_request_id;
  if found then
    return v_existing;
  end if;

  -- ---- Validation ---------------------------------------------------------
  if v_date > current_date then
    raise exception 'session_date cannot be in the future';
  end if;
  if p_anchor_track is not null and p_anchor_track not in (
       'tamil','malayalam','telugu','hindi','german','spanish',
       'english_us','english_uk','english_core') then
    raise exception 'unknown anchor track: %', p_anchor_track;
  end if;
  if exists (select 1 from unnest(v_sats) as s(t)
              where s.t not in (
                'tamil','malayalam','telugu','hindi','german','spanish',
                'english_us','english_uk','english_core')) then
    raise exception 'unknown satellite track in %', v_sats;
  end if;
  if cardinality(v_sats) > 2 then
    raise exception 'at most two satellites per session';
  end if;
  if (select count(distinct s.t) from unnest(v_sats) as s(t))
       <> cardinality(v_sats) then
    raise exception 'duplicate satellite tracks';
  end if;
  if p_script is not null and p_script not in (
       'Tamil','Devanagari','Telugu','Malayalam') then
    raise exception 'unknown script: %', p_script;
  end if;
  if p_boss_fight is not null and p_boss_fight not in ('win','showed_up') then
    raise exception 'unknown boss fight result: %', p_boss_fight;
  end if;

  -- ---- Scoring (mirrors the app's computeSession rules) -------------------
  if p_boss_fight is not null then
    if p_anchor_track is null then
      raise exception 'a boss fight needs a track';
    end if;
    v_minutes := 10;
    v_pts := case when p_boss_fight = 'win' then 100 else 25 end;
    v_per := jsonb_build_object(p_anchor_track, v_pts);
  elsif coalesce(p_eclipse, false) then
    if p_anchor_track is null then
      raise exception 'an eclipse day still needs the anchor block';
    end if;
    v_minutes := 10;
    v_per := jsonb_build_object(p_anchor_track, 100);
  else
    if p_anchor_track is not null then
      v_minutes := v_minutes + 15;
      v_per := jsonb_set(v_per, array[p_anchor_track],
                 to_jsonb(coalesce((v_per ->> p_anchor_track)::int, 0) + 150));
    end if;
    foreach v_track in array v_sats loop
      v_minutes := v_minutes + 5;
      v_per := jsonb_set(v_per, array[v_track],
                 to_jsonb(coalesce((v_per ->> v_track)::int, 0) + 50));
    end loop;
    if p_script is not null then
      v_minutes := v_minutes + 5;
      v_track := case p_script
                   when 'Tamil'      then 'tamil'
                   when 'Devanagari' then 'hindi'
                   when 'Telugu'     then 'telugu'
                   when 'Malayalam'  then 'malayalam'
                 end;
      v_per := jsonb_set(v_per, array[v_track],
                 to_jsonb(coalesce((v_per ->> v_track)::int, 0) + 50));
    end if;
  end if;

  if v_minutes = 0 then
    raise exception 'an empty session is a skip, and skips are not logged';
  end if;

  select coalesce(sum(value::int), 0) into v_points
    from jsonb_each_text(v_per);

  -- ---- Write: session + track totals, one transaction ---------------------
  insert into public.sessions (
    user_id, session_date, anchor_track, satellite_tracks, script,
    minutes, points, eclipse, boss_fight, request_id
  ) values (
    v_uid, v_date, p_anchor_track, v_sats, p_script,
    v_minutes, v_points, coalesce(p_eclipse, false), p_boss_fight, p_request_id
  )
  returning * into v_row;

  for v_track, v_pts in
    select key, value::int from jsonb_each_text(v_per)
  loop
    insert into public.track_progress (user_id, track, points, last_practiced)
    values (v_uid, v_track, v_pts, v_date)
    on conflict (user_id, track)
    do update set
      points = public.track_progress.points + excluded.points,
      last_practiced = greatest(
        coalesce(public.track_progress.last_practiced, excluded.last_practiced),
        excluded.last_practiced);
  end loop;

  return v_row;
end;
$$;

revoke execute on function public.record_session(uuid, date, text, text[], text, boolean, text)
  from public, anon;
grant  execute on function public.record_session(uuid, date, text, text[], text, boolean, text)
  to authenticated;
