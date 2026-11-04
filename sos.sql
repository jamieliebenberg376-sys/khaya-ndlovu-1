-- Khaya Ndlovu map: SOS alerts
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.

create table if not exists public.sos (
  id uuid primary key default gen_random_uuid(),
  client_id text unique not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  lat double precision not null,
  lng double precision not null,
  acc real,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved boolean not null default false,
  resolved_at timestamptz,
  resolved_by text,
  responders jsonb not null default '[]'::jsonb
);
create index if not exists sos_open on public.sos (resolved, created_at);

drop trigger if exists stamp_sos on public.sos;
create trigger stamp_sos before insert on public.sos for each row execute function public.stamp_author();

alter table public.sos enable row level security;
drop policy if exists sos_read on public.sos;
drop policy if exists sos_add  on public.sos;
drop policy if exists sos_upd  on public.sos;
create policy sos_read on public.sos for select to authenticated using (public.is_member());
create policy sos_add  on public.sos for insert to authenticated with check (public.is_member());
create policy sos_upd  on public.sos for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.sos to authenticated;

-- "I'm on my way": any member can add themselves as a responder
create or replace function public.sos_respond(p_cid text)
returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare nm text;
begin
  if not public.is_member() then raise exception 'members only'; end if;
  select name into nm from public.members where user_id = auth.uid();
  update public.sos s set responders = s.responders || jsonb_build_array(jsonb_build_object('uid', auth.uid(), 'name', nm, 't', now())),
         updated_at = now()
   where s.client_id = p_cid and not s.resolved
     and not exists (select 1 from jsonb_array_elements(s.responders) e where e->>'uid' = auth.uid()::text);
end $$;
grant execute on function public.sos_respond(text) to authenticated;

-- "Safe now": the person who sent it, or an admin, can close it
create or replace function public.sos_resolve(p_cid text)
returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  update public.sos s set resolved = true, resolved_at = now(), updated_at = now(),
         resolved_by = (select name from public.members where user_id = auth.uid())
   where s.client_id = p_cid and (s.user_id = auth.uid() or public.is_admin());
end $$;
grant execute on function public.sos_resolve(text) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.sos;
exception when duplicate_object then null; when undefined_object then null;
end $$;
