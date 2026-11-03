-- Khaya Ndlovu map: admin announcements
-- Run AFTER admin_members.sql. Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.
-- Admins write anything; every member sees it as a pop-up the next time they open the map (or straight away if it is open).

create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  client_id text unique not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  body text not null check (length(body) between 1 and 1500),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  removed boolean not null default false
);

drop trigger if exists stamp_ann on public.announcements;
create trigger stamp_ann before insert on public.announcements for each row execute function public.stamp_author();

alter table public.announcements enable row level security;
drop policy if exists an_read on public.announcements;
drop policy if exists an_add  on public.announcements;
drop policy if exists an_upd  on public.announcements;
create policy an_read on public.announcements for select to authenticated using (public.is_member());
create policy an_add  on public.announcements for insert to authenticated with check (public.is_admin());
create policy an_upd  on public.announcements for update to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update on public.announcements to authenticated;
