-- Khaya Ndlovu map: live member locations (coloured dots for everyone driving on the reserve)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.
-- Only members can see or write locations. Each phone can only write its own dot.

create table if not exists public.live_locs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text,
  lat double precision not null,
  lng double precision not null,
  heading real,
  speed real,
  status text,
  updated_at timestamptz not null default now()
);
alter table public.live_locs enable row level security;

drop policy if exists ll_read on public.live_locs;
drop policy if exists ll_add  on public.live_locs;
drop policy if exists ll_upd  on public.live_locs;
drop policy if exists ll_del  on public.live_locs;
create policy ll_read on public.live_locs for select to authenticated using (public.is_member());
create policy ll_add  on public.live_locs for insert to authenticated with check (user_id = auth.uid() and public.is_member());
create policy ll_upd  on public.live_locs for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and public.is_member());
create policy ll_del  on public.live_locs for delete to authenticated using (user_id = auth.uid());
grant select, insert, update, delete on public.live_locs to authenticated;

-- the server always stamps the time, so nobody can fake an old or future dot
create or replace function public.ll_stamp() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists ll_stamp on public.live_locs;
create trigger ll_stamp before insert or update on public.live_locs for each row execute function public.ll_stamp();

-- instant updates to other phones
do $$ begin
  alter publication supabase_realtime add table public.live_locs;
exception when duplicate_object then null; when undefined_object then null;
end $$;
