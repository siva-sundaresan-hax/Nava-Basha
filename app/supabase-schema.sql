-- ============================================================================
-- Nava Bhasha — The Nine Tongues League · Supabase schema
-- Run this once in your Supabase project: Dashboard → SQL Editor → New query
-- → paste → Run. Safe to re-run (guards use IF NOT EXISTS / OR REPLACE).
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
  points         int  not null default 0,
  last_practiced date,
  primary key (user_id, track)
);

-- One row per logged session (a boss-fight record is also a session row,
-- with boss_fight set to 'win' or 'showed_up').
create table if not exists public.sessions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  session_date     date not null default current_date,
  anchor_track     text,
  satellite_tracks text[] not null default '{}',
  script           text,
  minutes          int not null default 0,
  points           int not null default 0,
  eclipse          boolean not null default false,
  boss_fight       text check (boss_fight in ('win', 'showed_up')),
  created_at       timestamptz not null default now()
);

create index if not exists sessions_user_date_idx
  on public.sessions (user_id, session_date desc);

-- ---------------------------------------------------------------------------
-- Row Level Security — every user can only touch their own rows.
-- ---------------------------------------------------------------------------

alter table public.profiles       enable row level security;
alter table public.track_progress enable row level security;
alter table public.sessions       enable row level security;

-- profiles (keyed by id)
drop policy if exists "profiles: own row" on public.profiles;
create policy "profiles: own row" on public.profiles
  for all
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- track_progress (keyed by user_id)
drop policy if exists "track_progress: own rows" on public.track_progress;
create policy "track_progress: own rows" on public.track_progress
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- sessions (keyed by user_id)
drop policy if exists "sessions: own rows" on public.sessions;
create policy "sessions: own rows" on public.sessions
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Signup bootstrap — when a new auth user is created, give them a profile
-- row and the nine track_progress rows (all Level 0 / Unplaced, 0 points).
-- The app ALSO lazily creates any missing rows on first dashboard load, so
-- the app works even if this trigger is removed.
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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
