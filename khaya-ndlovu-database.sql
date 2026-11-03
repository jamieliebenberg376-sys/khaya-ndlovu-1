-- Khaya Ndlovu Game Drive Map: shared database
-- Paste this whole file into Supabase > SQL Editor > New query, change the
-- invite code on the line marked CHANGE ME, then press Run.

create extension if not exists pgcrypto;

-- ---------- private config (not reachable from the app) ----------
create schema if not exists private;
create table if not exists private.config (
  id int primary key default 1 check (id = 1),
  invite_code text not null
);
insert into private.config (id, invite_code)
values (1, 'KHAYA2026')            -- CHANGE ME: the code owners type to join
on conflict (id) do update set invite_code = excluded.invite_code;

-- ---------- members ----------
create table if not exists public.members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  joined_at timestamptz not null default now()
);

create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where user_id = auth.uid());
$$;

-- join with the invite code (safe: the code itself is never readable)
create or replace function public.join_reserve(code text, display_name text)
returns boolean language plpgsql security definer set search_path = public, private as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from private.config where lower(invite_code) = lower(trim(code))) then
    return false;
  end if;
  insert into public.members (user_id, name)
  values (auth.uid(), left(coalesce(nullif(trim(display_name), ''), 'Owner'), 40))
  on conflict (user_id) do update set name = excluded.name;
  return true;
end $$;
revoke all on function public.join_reserve(text, text) from public;
grant execute on function public.join_reserve(text, text) to authenticated;
grant execute on function public.is_member() to authenticated;

-- ---------- shared tables ----------
create table if not exists public.sightings (
  id uuid primary key default gen_random_uuid(),
  client_id text unique not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  what text not null,
  note text,
  lat double precision not null,
  lng double precision not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '3 days'
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  client_id text unique not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  kind text not null,
  note text,
  road text,
  lat double precision not null,
  lng double precision not null,
  resolved boolean not null default false,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '5 days'
);

create table if not exists public.drives (
  id uuid primary key default gen_random_uuid(),
  client_id text unique not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  title text,
  len_m real,
  pts jsonb not null,
  created_at timestamptz not null default now()
);

-- map updates pushed by the map maker (newer version replaces the built-in map)
create table if not exists public.map_data (
  id int primary key default 1 check (id = 1),
  version int not null,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- stamp the author's name automatically
create or replace function public.stamp_author()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  new.name := (select m.name from public.members m where m.user_id = auth.uid());
  return new;
end $$;
drop trigger if exists stamp_sightings on public.sightings;
create trigger stamp_sightings before insert on public.sightings for each row execute function public.stamp_author();
drop trigger if exists stamp_reports on public.reports;
create trigger stamp_reports before insert on public.reports for each row execute function public.stamp_author();
drop trigger if exists stamp_drives on public.drives;
create trigger stamp_drives before insert on public.drives for each row execute function public.stamp_author();

-- ---------- row level security: members only ----------
alter table public.members   enable row level security;
alter table public.sightings enable row level security;
alter table public.reports   enable row level security;
alter table public.drives    enable row level security;
alter table public.map_data  enable row level security;

drop policy if exists m_read on public.members;
create policy m_read on public.members for select to authenticated using (public.is_member());

drop policy if exists s_read on public.sightings;
drop policy if exists s_add  on public.sightings;
drop policy if exists s_del  on public.sightings;
create policy s_read on public.sightings for select to authenticated using (public.is_member());
create policy s_add  on public.sightings for insert to authenticated with check (public.is_member());
create policy s_del  on public.sightings for delete to authenticated using (user_id = auth.uid());

drop policy if exists r_read on public.reports;
drop policy if exists r_add  on public.reports;
drop policy if exists r_upd  on public.reports;
drop policy if exists r_del  on public.reports;
create policy r_read on public.reports for select to authenticated using (public.is_member());
create policy r_add  on public.reports for insert to authenticated with check (public.is_member());
create policy r_upd  on public.reports for update to authenticated using (public.is_member()) with check (public.is_member());
create policy r_del  on public.reports for delete to authenticated using (user_id = auth.uid());

drop policy if exists d_read on public.drives;
drop policy if exists d_add  on public.drives;
drop policy if exists d_del  on public.drives;
create policy d_read on public.drives for select to authenticated using (public.is_member());
create policy d_add  on public.drives for insert to authenticated with check (public.is_member());
create policy d_del  on public.drives for delete to authenticated using (user_id = auth.uid());

drop policy if exists md_read on public.map_data;
create policy md_read on public.map_data for select to authenticated using (public.is_member());

-- only "resolved" can be changed on someone else's report
revoke update on public.reports from authenticated;
grant update (resolved) on public.reports to authenticated;

grant select on public.members to authenticated;
grant select, insert, delete on public.sightings, public.drives to authenticated;
grant select, insert, delete on public.reports to authenticated;
grant select on public.map_data to authenticated;

create index if not exists sightings_exp on public.sightings (expires_at);
create index if not exists reports_exp on public.reports (expires_at);
