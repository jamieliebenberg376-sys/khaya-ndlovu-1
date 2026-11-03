-- Khaya Ndlovu map: "Not here" checks for the likely animal spots
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.
-- When someone checks a likely spot and the animal isn't there, it's saved here and the spot disappears for everyone.

create table if not exists public.animal_misses (
  id uuid primary key default gen_random_uuid(),
  client_id text unique not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  what text not null,
  lat double precision not null,
  lng double precision not null,
  created_at timestamptz not null default now()
);
create index if not exists animal_misses_t on public.animal_misses (created_at);

drop trigger if exists stamp_misses on public.animal_misses;
create trigger stamp_misses before insert on public.animal_misses for each row execute function public.stamp_author();

alter table public.animal_misses enable row level security;
drop policy if exists am_read on public.animal_misses;
drop policy if exists am_add  on public.animal_misses;
create policy am_read on public.animal_misses for select to authenticated using (public.is_member());
create policy am_add  on public.animal_misses for insert to authenticated with check (public.is_member());
grant select, insert on public.animal_misses to authenticated;
