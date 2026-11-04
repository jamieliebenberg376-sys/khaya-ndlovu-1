-- Khaya Ndlovu map: EVERYTHING IN ONE FILE (run this one, it replaces all the others)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run as many times as you like.
-- It sets up anything that is missing and updates the rest. It never changes your owner code, members, codes or sightings.
-- At the bottom you get a check table: every line should say YES.
create extension if not exists pgcrypto with schema extensions;


-- =====================================================================
-- BASE TABLES
-- =====================================================================
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
on conflict (id) do nothing;  -- never changes your existing owner code

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


-- =====================================================================
-- CODES AND MEMBERS
-- =====================================================================
-- Khaya Ndlovu map: ALL CODES IN ONE FILE (owner, admin, guest codes and owner/admin invites)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run as many times as you like.
-- This replaces guest_codes.sql, admin_members.sql and fix_guest_codes.sql. Run it LAST, after any of those.
-- At the end it runs a self-test inside your database (nothing is saved) and shows PASS / FAIL for each code type.
--
-- OWNER CODE = your invite code (e.g. KHAYA2026). ADMIN CODE = ADMIN + owner code (e.g. ADMINKHAYA2026), max 4 people.
-- Owners make guest codes and one-time owner invites. Admins also make admin invites.

-- ---------- tables and columns ----------
alter table public.members add column if not exists role text not null default 'owner';
alter table public.members add column if not exists code text;
alter table public.members add column if not exists expires_at timestamptz;
alter table public.members add column if not exists last_seen timestamptz;
alter table public.members add column if not exists invited_by text;
alter table public.members add column if not exists last_login timestamptz;
alter table public.members add column if not exists home_lat double precision;
alter table public.members add column if not exists home_lng double precision;

create table if not exists public.guest_codes (
  code text primary key,
  label text,
  created_by uuid references auth.users(id) on delete set null,
  created_by_name text,
  expires_at timestamptz not null,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.guest_codes add column if not exists kind text not null default 'guest';
alter table public.guest_codes add column if not exists uses int not null default 0;
alter table public.guest_codes enable row level security;
revoke all on public.guest_codes from anon, authenticated;

-- ---------- who is who ----------
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                 where user_id = auth.uid() and (role in ('owner', 'admin') or expires_at is null or expires_at > now()));
$$;
grant execute on function public.is_member() to authenticated;

create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where user_id = auth.uid() and role in ('owner', 'admin'));
$$;
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where user_id = auth.uid() and role = 'admin');
$$;
grant execute on function public.is_admin() to authenticated;

-- join with: ADMIN code, owner code, an owner/admin invite, or a guest code
create or replace function public.join_core(code text, display_name text)
returns json language plpgsql security definer set search_path = public, private as $$
#variable_conflict use_column
declare
  c text := upper(replace(trim(code), ' ', ''));
  nm text := left(coalesce(nullif(trim(display_name), ''), 'Member'), 40);
  cur public.members; g public.guest_codes; owner_code text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into cur from public.members where user_id = auth.uid();
  select upper(replace(invite_code, ' ', '')) into owner_code from private.config limit 1;

  -- master admin code: max 4 admins
  if c = 'ADMIN' || owner_code then
    if coalesce(cur.role, '') <> 'admin' and (select count(*) from public.members where role = 'admin') >= 4 then
      return json_build_object('ok', false, 'reason', 'full');
    end if;
    insert into public.members (user_id, name, role, code, expires_at, last_seen, invited_by)
    values (auth.uid(), nm, 'admin', null, null, now(), 'Admin code')
    on conflict (user_id) do update set name = excluded.name, role = 'admin', code = null, expires_at = null, last_seen = now();
    return json_build_object('ok', true, 'role', 'admin', 'expires_at', null);
  end if;

  -- owner code
  if c = owner_code then
    insert into public.members (user_id, name, role, code, expires_at, last_seen, invited_by)
    values (auth.uid(), nm, 'owner', null, null, now(), 'Owner code')
    on conflict (user_id) do update set name = excluded.name, last_seen = now(), code = null, expires_at = null,
      role = case when members.role = 'admin' then 'admin' else 'owner' end;
    return json_build_object('ok', true, 'role', (select role from public.members where user_id = auth.uid()), 'expires_at', null);
  end if;

  select * into g from public.guest_codes where upper(guest_codes.code) = c;
  if not found or g.revoked or g.expires_at <= now() then
    return json_build_object('ok', false, 'reason', case when not found then 'wrong' when g.revoked then 'revoked' else 'expired' end);
  end if;

  -- one-time owner / admin invite (never expires once used)
  if g.kind in ('owner', 'admin') then
    if g.uses >= 1 and coalesce(cur.code, '') <> g.code then return json_build_object('ok', false, 'reason', 'used'); end if;
    insert into public.members (user_id, name, role, code, expires_at, last_seen, invited_by)
    values (auth.uid(), nm, g.kind, g.code, null, now(), g.created_by_name)
    on conflict (user_id) do update set name = excluded.name, last_seen = now(), expires_at = null, code = excluded.code,
      invited_by = excluded.invited_by,
      role = case when members.role = 'admin' then 'admin' else excluded.role end;
    update public.guest_codes gc set uses = gc.uses + 1 where gc.code = g.code and coalesce(cur.code, '') <> g.code;
    -- a new owner starts with the home of the person who invited them (they can change it)
    update public.members m set home_lat = h.home_lat, home_lng = h.home_lng
      from public.members h where m.user_id = auth.uid() and m.home_lat is null and h.user_id = g.created_by and h.home_lat is not null;
    return json_build_object('ok', true, 'role', (select role from public.members where user_id = auth.uid()), 'expires_at', null);
  end if;

  -- guest code: one-time, like an owner invite (the same person can sign back in with it)
  if g.uses >= 1 and coalesce(cur.code, '') <> g.code then return json_build_object('ok', false, 'reason', 'used'); end if;
  insert into public.members (user_id, name, role, code, expires_at, last_seen, invited_by)
  values (auth.uid(), left(coalesce(nullif(trim(display_name), ''), 'Guest'), 40), 'guest', g.code, g.expires_at, now(), g.created_by_name)
  on conflict (user_id) do update set name = excluded.name, last_seen = now(),
    role = case when members.role in ('owner', 'admin') then members.role else 'guest' end,
    code = case when members.role in ('owner', 'admin') then members.code else excluded.code end,
    invited_by = case when members.role in ('owner', 'admin') then members.invited_by else excluded.invited_by end,
    expires_at = case when members.role in ('owner', 'admin') then members.expires_at else excluded.expires_at end;
  update public.guest_codes gc set uses = gc.uses + 1 where gc.code = g.code and coalesce(cur.code, '') <> g.code;
  return json_build_object('ok', true, 'role', (select role from public.members where user_id = auth.uid()),
                           'expires_at', (select expires_at from public.members where user_id = auth.uid()));
end $$;
revoke all on function public.join_core(text, text) from public, anon, authenticated;

-- the app calls this one: joins, then records the sign-in time
create or replace function public.join_reserve2(code text, display_name text)
returns json language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare r json;
begin
  r := public.join_core(code, display_name);
  if (r->>'ok')::boolean then update public.members set last_login = now(), last_seen = now() where user_id = auth.uid(); end if;
  return r;
end $$;
grant execute on function public.join_reserve2(text, text) to authenticated;

-- status check; also records when each person last opened the map. Owners/admins never expire.
drop function if exists public.my_status();
create function public.my_status()
returns json language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare m public.members; hl double precision; hg double precision; hn text;
begin
  select * into m from public.members where user_id = auth.uid();
  if not found then return json_build_object('member', false, 'active', false); end if;
  update public.members set last_seen = now() where user_id = auth.uid() and (last_seen is null or last_seen < now() - interval '2 minutes');
  if m.role in ('owner', 'admin') then
    return json_build_object('member', true, 'role', m.role, 'expires_at', null, 'active', true,
      'home', case when m.home_lat is null then null else json_build_object('lat', m.home_lat, 'lng', m.home_lng) end);
  end if;
  -- guests use the home of the owner who made their code
  select h.home_lat, h.home_lng, h.name into hl, hg, hn from public.guest_codes g join public.members h on h.user_id = g.created_by where g.code = m.code;
  return json_build_object('member', true, 'role', m.role, 'expires_at', m.expires_at,
    'home', case when hl is null then null else json_build_object('lat', hl, 'lng', hg, 'by', hn) end,
    'active', (m.expires_at is null or m.expires_at > now())
              and not exists (select 1 from public.guest_codes g where g.code = m.code and g.revoked));
end $$;
grant execute on function public.my_status() to authenticated;

-- owners and admins save their home point (their guests use it automatically). Pass nulls to remove it.
create or replace function public.set_my_home(p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  update public.members set home_lat = p_lat, home_lng = p_lng where user_id = auth.uid();
end $$;
grant execute on function public.set_my_home(double precision, double precision) to authenticated;

-- make a code: owners make guest codes and one-time owner invites; admins can also make admin invites
create or replace function public.create_code(p_label text, p_expires timestamptz, p_kind text)
returns text language plpgsql security definer set search_path = public, private as $$
#variable_conflict use_column
declare c text; tries int := 0; abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; k text := coalesce(p_kind, 'guest');
begin
  if k not in ('guest', 'owner', 'admin') then raise exception 'bad kind'; end if;
  if k in ('guest', 'owner') and not public.is_owner() then raise exception 'owners only'; end if;
  if k = 'admin' and not public.is_admin() then raise exception 'admins only'; end if;
  if k = 'guest' and p_expires <= now() then raise exception 'expiry must be in the future'; end if;
  loop
    select string_agg(substr(abc, 1 + floor(random() * length(abc))::int, 1), '') into c from generate_series(1, 6);
    exit when not exists (select 1 from public.guest_codes gc where gc.code = c);
    tries := tries + 1; if tries > 20 then raise exception 'try again'; end if;
  end loop;
  insert into public.guest_codes (code, label, created_by, created_by_name, expires_at, kind)
  values (c, left(nullif(trim(p_label), ''), 40), auth.uid(),
          (select name from public.members where user_id = auth.uid()),
          case when k = 'guest' then p_expires else now() + interval '14 days' end, k);
  return c;
end $$;
grant execute on function public.create_code(text, timestamptz, text) to authenticated;

-- keep the old name working
create or replace function public.create_guest_code(p_label text, p_expires timestamptz)
returns text language sql security definer set search_path = public as $$ select public.create_code(p_label, p_expires, 'guest') $$;
grant execute on function public.create_guest_code(text, timestamptz) to authenticated;

-- live codes only: expired, deleted and used-up codes are hidden (owner/admin invites only shown to admins)
create or replace function public.list_guest_codes()
returns json language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  return coalesce((select json_agg(row_to_json(x) order by x.created_at desc) from (
    select g.code, g.label, g.kind, g.uses,
      coalesce((select name from public.members o where o.user_id = g.created_by), g.created_by_name) as created_by_name,
      g.created_by = auth.uid() as mine, g.expires_at, g.revoked, g.created_at,
      (select count(*) from public.members m where m.code = g.code) as people,
      coalesce((select json_agg(json_build_object('name', m.name, 'joined_at', m.joined_at) order by m.joined_at)
                from public.members m where m.code = g.code), '[]'::json) as guests
    from public.guest_codes g
    where not g.revoked and g.expires_at > now()
      and (g.kind = 'guest' or (g.kind = 'owner' and g.uses = 0) or (g.kind = 'admin' and g.uses = 0 and public.is_admin()))) x), '[]'::json);
end $$;
grant execute on function public.list_guest_codes() to authenticated;

-- owners and admins: everyone on the map (expired guests are left out)
create or replace function public.list_members()
returns json language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  return coalesce((select json_agg(row_to_json(x) order by x.role_order, x.name) from (
    select m.user_id, m.name, m.role, m.joined_at,
           case when public.is_admin() or m.user_id = auth.uid() then m.last_seen end as last_seen,
           case when public.is_admin() or m.user_id = auth.uid() then m.last_login end as last_login,
           case when m.role = 'guest' then m.expires_at end as expires_at, m.code,
           m.user_id = auth.uid() as me,
           g.label as code_label,
           coalesce(m.invited_by, g.created_by_name) as added_by,
           case m.role when 'admin' then 0 when 'owner' then 1 else 2 end as role_order
    from public.members m left join public.guest_codes g on g.code = m.code
    where m.role <> 'guest' or (m.expires_at > now() and not coalesce(g.revoked, false))) x), '[]'::json);
end $$;
grant execute on function public.list_members() to authenticated;

-- admins: remove someone (they are logged out on their next check)
create or replace function public.remove_member(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  if p_user = auth.uid() then raise exception 'you cannot remove yourself'; end if;
  begin delete from public.live_locs where user_id = p_user; exception when undefined_table then null; end;
  delete from public.members where user_id = p_user;
end $$;
grant execute on function public.remove_member(uuid) to authenticated;

-- admins: make an owner an admin (no limit), or an admin back into an owner
create or replace function public.set_member_role(p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  if p_role not in ('owner', 'admin') then raise exception 'bad role'; end if;
  if p_user = auth.uid() then raise exception 'you cannot change yourself'; end if;
  update public.members set role = p_role, expires_at = null
   where user_id = p_user and role in ('owner', 'admin');
end $$;
grant execute on function public.set_member_role(uuid, text) to authenticated;

-- anyone: sign out = take yourself off the map completely (you disappear from the owners/guests list)
create or replace function public.leave_reserve()
returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.uid() is null then return; end if;
  begin delete from public.live_locs where user_id = auth.uid(); exception when undefined_table then null; end;
  delete from public.members where user_id = auth.uid();
end $$;
grant execute on function public.leave_reserve() to authenticated;


-- delete a code now (anyone using it is logged out on their next check)
create or replace function public.revoke_guest_code(p_code text)
returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  update public.guest_codes gc set revoked = true where gc.code = upper(trim(p_code));
  update public.members m set expires_at = now() where m.code = upper(trim(p_code)) and m.role = 'guest';
end $$;
grant execute on function public.revoke_guest_code(text) to authenticated;

-- change a guest code's end date
create or replace function public.extend_guest_code(p_code text, p_expires timestamptz)
returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  update public.guest_codes gc set expires_at = p_expires, revoked = false where gc.code = upper(trim(p_code));
  update public.members m set expires_at = p_expires where m.code = upper(trim(p_code)) and m.role = 'guest';
end $$;
grant execute on function public.extend_guest_code(text, timestamptz) to authenticated;

-- ---------- HANDOVER: stay signed in when you add the map to your Home Screen ----------
-- On iPhone the Home Screen app can't see the Safari login. After signing in, Safari gets a one-time pass in its link;
-- the Home Screen icon opens with that pass and takes over the same membership. Each pass works once.
create table if not exists public.handover (
  token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  used_at timestamptz
);
alter table public.handover enable row level security;
revoke all on public.handover from anon, authenticated;

create or replace function public.make_handover()
returns text language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare t text;
begin
  if auth.uid() is null or not exists (select 1 from public.members where user_id = auth.uid()) then return null; end if;
  select h.token into t from public.handover h where h.user_id = auth.uid() and h.used_at is null and h.created_at > now() - interval '30 days' limit 1;
  if t is not null then return t; end if;
  t := upper(left(md5(random()::text || clock_timestamp()::text || auth.uid()::text), 10) || left(md5(random()::text || auth.uid()::text), 10));
  insert into public.handover (token, user_id) values (t, auth.uid());
  return t;
end $$;
grant execute on function public.make_handover() to authenticated;

create or replace function public.use_handover(p_token text)
returns json language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare h public.handover; m public.members; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into h from public.handover where token = upper(trim(p_token)) for update;
  if not found then return json_build_object('ok', false, 'reason', 'wrong'); end if;
  if h.user_id = me then
    select * into m from public.members where user_id = me;
    if found then return json_build_object('ok', true, 'role', m.role, 'expires_at', m.expires_at, 'name', m.name); end if;
  end if;
  if h.used_at is not null then return json_build_object('ok', false, 'reason', 'used'); end if;
  if h.created_at < now() - interval '30 days' then return json_build_object('ok', false, 'reason', 'expired'); end if;
  select * into m from public.members where user_id = h.user_id;
  if not found then return json_build_object('ok', false, 'reason', 'gone'); end if;
  if m.role = 'guest' and m.expires_at is not null and m.expires_at <= now() then return json_build_object('ok', false, 'reason', 'expired'); end if;
  perform set_config('kn.handover', '1', true);
  insert into public.members (user_id, name, role, code, expires_at, last_seen, invited_by, last_login, home_lat, home_lng)
  values (me, m.name, m.role, m.code, m.expires_at, now(), m.invited_by, now(), m.home_lat, m.home_lng)
  on conflict (user_id) do update set name = excluded.name, role = excluded.role, code = excluded.code,
    expires_at = excluded.expires_at, invited_by = excluded.invited_by, last_seen = now(), last_login = now(),
    home_lat = excluded.home_lat, home_lng = excluded.home_lng;
  -- bring their sightings, reports and drives along, then retire the Safari login
  begin update public.sightings set user_id = me where user_id = h.user_id; exception when others then null; end;
  begin update public.reports set user_id = me where user_id = h.user_id; exception when others then null; end;
  begin update public.drives set user_id = me where user_id = h.user_id; exception when others then null; end;
  begin delete from public.live_locs where user_id = h.user_id; exception when others then null; end;
  begin update public.private_notes set user_id = me where user_id = h.user_id; exception when others then null; end;
  delete from public.members where user_id = h.user_id;
  update public.handover set used_at = now() where token = h.token;
  perform set_config('kn.handover', '', true);
  return json_build_object('ok', true, 'role', m.role, 'expires_at', m.expires_at, 'name', m.name);
end $$;
grant execute on function public.use_handover(text) to authenticated;

-- ---------- SELF-TEST: tries every kind of code inside your database, then undoes everything ----------
create or replace function public.kn_selftest()
returns table(test text, result text) language plpgsql security definer set search_path = public, auth as $$
#variable_conflict use_column
declare
  a uuid := gen_random_uuid(); o uuid := gen_random_uuid(); g1 uuid := gen_random_uuid(); o2 uuid := gen_random_uuid(); ad2 uuid := gen_random_uuid(); g2 uuid := gen_random_uuid(); h1 uuid := gen_random_uuid(); h2 uuid := gen_random_uuid(); tk text;
  oc text; r json; c_guest text; c_owner text; c_admin text; c_oguest text; c_oowner text; out text[] := '{}';
begin
  select 'ADMIN' || upper(replace(invite_code, ' ', '')) into oc from private.config limit 1;
  begin
    insert into auth.users (id) values (a), (o), (g1), (o2), (ad2), (g2), (h1), (h2);
    -- admin joins with the admin code
    perform set_config('request.jwt.claim.sub', a::text, true); perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true);
    r := public.join_reserve2(lower(oc), 'Test admin');
    out := out || array['Admin code joins', case when (r->>'ok')::boolean and r->>'role' = 'admin' then 'PASS' else 'FAIL ' || r::text end];
    c_guest := public.create_code('t', now() + interval '1 day', 'guest');
    c_owner := public.create_code('t', null, 'owner');
    c_admin := public.create_code('t', null, 'admin');
    out := out || array['Admin makes guest / owner / admin codes', 'PASS (' || c_guest || ', ' || c_owner || ', ' || c_admin || ')'];
    -- guest joins
    perform set_config('request.jwt.claim.sub', g1::text, true); perform set_config('request.jwt.claims', json_build_object('sub', g1)::text, true);
    r := public.join_reserve2(lower(c_guest), 'Test guest');
    out := out || array['Guest code from admin works', case when (r->>'ok')::boolean and r->>'role' = 'guest' then 'PASS' else 'FAIL ' || r::text end];
    -- owner invite joins
    perform set_config('request.jwt.claim.sub', o::text, true); perform set_config('request.jwt.claims', json_build_object('sub', o)::text, true);
    r := public.join_reserve2(c_owner, 'Test owner');
    out := out || array['Owner invite from admin works', case when (r->>'ok')::boolean and r->>'role' = 'owner' then 'PASS' else 'FAIL ' || r::text end];
    -- owner makes a guest code and an owner invite
    c_oguest := public.create_code('t', now() + interval '1 day', 'guest');
    c_oowner := public.create_code('t', null, 'owner');
    out := out || array['Owner makes guest + owner codes', 'PASS (' || c_oguest || ', ' || c_oowner || ')'];
    begin perform public.create_code('t', null, 'admin'); out := out || array['Owner blocked from admin invites', 'FAIL (owner made an admin invite)'];
    exception when others then out := out || array['Owner blocked from admin invites', 'PASS']; end;
    -- admin invite joins
    perform set_config('request.jwt.claim.sub', ad2::text, true); perform set_config('request.jwt.claims', json_build_object('sub', ad2)::text, true);
    r := public.join_reserve2(c_admin, 'Test admin 2');
    out := out || array['Admin invite works', case when (r->>'ok')::boolean and r->>'role' = 'admin' then 'PASS' else 'FAIL ' || r::text end];
    -- codes made by the owner
    perform set_config('request.jwt.claim.sub', g2::text, true); perform set_config('request.jwt.claims', json_build_object('sub', g2)::text, true);
    r := public.join_reserve2(c_oguest, 'Test guest 2');
    out := out || array['Guest code from owner works', case when (r->>'ok')::boolean and r->>'role' = 'guest' then 'PASS' else 'FAIL ' || r::text end];
    perform set_config('request.jwt.claim.sub', o2::text, true); perform set_config('request.jwt.claims', json_build_object('sub', o2)::text, true);
    r := public.join_reserve2(c_oowner, 'Test owner 2');
    out := out || array['Owner invite from owner works', case when (r->>'ok')::boolean and r->>'role' = 'owner' then 'PASS' else 'FAIL ' || r::text end];
    -- an invite can only be used once
    perform set_config('request.jwt.claim.sub', g2::text, true); perform set_config('request.jwt.claims', json_build_object('sub', g2)::text, true);
    r := public.join_reserve2(c_owner, 'Someone else');
    out := out || array['Used invite is refused', case when not (r->>'ok')::boolean then 'PASS' else 'FAIL ' || r::text end];
    r := public.join_reserve2(c_guest, 'Someone else');
    out := out || array['Used guest code is refused for someone new', case when not (r->>'ok')::boolean and r->>'reason' = 'used' then 'PASS' else 'FAIL ' || r::text end];
    -- the guest signs back in with their own code (same login): still works
    perform set_config('request.jwt.claim.sub', g1::text, true); perform set_config('request.jwt.claims', json_build_object('sub', g1)::text, true);
    r := public.join_reserve2(c_guest, 'Test guest');
    out := out || array['Same guest can sign back in', case when (r->>'ok')::boolean then 'PASS' else 'FAIL ' || r::text end];
    -- handover: guest in Safari makes a pass, the Home Screen app (new login) uses it
    tk := public.make_handover();
    perform set_config('request.jwt.claim.sub', h1::text, true); perform set_config('request.jwt.claims', json_build_object('sub', h1)::text, true);
    r := public.use_handover(tk);
    out := out || array['Home Screen app stays signed in (handover)', case when (r->>'ok')::boolean and r->>'role' = 'guest'
      and exists (select 1 from public.members where user_id = h1) and not exists (select 1 from public.members where user_id = g1) then 'PASS' else 'FAIL ' || r::text end];
    perform set_config('request.jwt.claim.sub', h2::text, true); perform set_config('request.jwt.claims', json_build_object('sub', h2)::text, true);
    r := public.use_handover(tk);
    out := out || array['Handover pass works only once', case when not (r->>'ok')::boolean then 'PASS' else 'FAIL ' || r::text end];
    perform set_config('request.jwt.claim.sub', a::text, true); perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true);
    tk := public.make_handover();
    perform set_config('request.jwt.claim.sub', h2::text, true); perform set_config('request.jwt.claims', json_build_object('sub', h2)::text, true);
    r := public.use_handover(tk);
    out := out || array['Admin handover keeps admin', case when (r->>'ok')::boolean and r->>'role' = 'admin' then 'PASS' else 'FAIL ' || r::text end];
    -- home points
    perform set_config('request.jwt.claim.sub', o::text, true); perform set_config('request.jwt.claims', json_build_object('sub', o)::text, true);
    perform public.set_my_home(-24.38, 30.96);
    c_oguest := public.create_code('home test', now() + interval '1 day', 'guest');
    perform set_config('request.jwt.claim.sub', h1::text, true); perform set_config('request.jwt.claims', json_build_object('sub', h1)::text, true);
    delete from public.members where user_id = h1;
    r := public.join_reserve2(c_oguest, 'Home guest');
    r := public.my_status();
    out := out || array['Guest gets the home of the owner who invited them', case when (r->'home'->>'lat')::float = -24.38 and r->'home'->>'by' = 'Test owner' then 'PASS' else 'FAIL ' || r::text end];
    begin perform public.set_my_home(-24.1, 30.1); out := out || array['Guests cannot set a home point', 'FAIL'];
    exception when others then out := out || array['Guests cannot set a home point', 'PASS']; end;
    r := public.join_reserve2('WRONG9', 'x');
    out := out || array['Wrong code is refused', case when not (r->>'ok')::boolean and r->>'reason' = 'wrong' then 'PASS' else 'FAIL ' || r::text end];
    raise exception 'kn_selftest_rollback';
  exception when others then
    if sqlerrm <> 'kn_selftest_rollback' then out := out || array['Test stopped with an error', 'FAIL: ' || sqlerrm]; end if;
  end;
  for i in 1 .. coalesce(array_length(out, 1), 0) / 2 loop test := out[i*2-1]; result := out[i*2]; return next; end loop;
end $$;
revoke all on function public.kn_selftest() from public, anon, authenticated;

notify pgrst, 'reload schema';



-- =====================================================================
-- PHOTOS AND STILL HERE
-- =====================================================================
-- Khaya Ndlovu map: sighting photos + "Still here"
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.

alter table public.sightings add column if not exists photo boolean not null default false;
alter table public.sightings add column if not exists still boolean not null default false;

-- private photo storage, members only
do $$ begin
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sightings', 'sightings', false, 3145728, array['image/jpeg'])
on conflict (id) do nothing;
exception when others then raise notice 'Photo bucket skipped: %', sqlerrm;
end $$;

do $$ begin
drop policy if exists kn_photo_read on storage.objects;
drop policy if exists kn_photo_add  on storage.objects;
drop policy if exists kn_photo_upd  on storage.objects;
create policy kn_photo_read on storage.objects for select to authenticated using (bucket_id = 'sightings' and public.is_member());
create policy kn_photo_add  on storage.objects for insert to authenticated with check (bucket_id = 'sightings' and public.is_member());
create policy kn_photo_upd  on storage.objects for update to authenticated using (bucket_id = 'sightings' and owner = auth.uid()) with check (bucket_id = 'sightings' and public.is_member());
exception when others then raise notice 'Photo storage permissions skipped: %', sqlerrm;
end $$;


-- =====================================================================
-- LIVE LOCATION
-- =====================================================================
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


-- =====================================================================
-- LIKELY SPOTS
-- =====================================================================
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


-- =====================================================================
-- NEWS
-- =====================================================================
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


-- =====================================================================
-- SOS
-- =====================================================================
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


-- =====================================================================
-- ADMIN TOOLS
-- =====================================================================
-- Khaya Ndlovu map: admin tools (delete any sightings)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.

create or replace function public.admin_delete_sightings(p_cids text[])
returns int language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare n int;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  delete from public.sightings s where s.client_id = any(p_cids);
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.admin_delete_sightings(text[]) to authenticated;


-- =====================================================================
-- SPOTIFY
-- =====================================================================
-- Spotify login hand-off for the Khaya Ndlovu map (needed on iPhone)
create table if not exists private.sp_relay (
  id text primary key,
  payload text not null,
  created_at timestamptz not null default now()
);
create or replace function public.sp_relay_put(p_id text, p_payload text)
returns void language sql security definer set search_path = private, public as $$
  delete from private.sp_relay where created_at < now() - interval '15 minutes';
  insert into private.sp_relay(id, payload) values (p_id, p_payload)
  on conflict (id) do update set payload = excluded.payload, created_at = now();
$$;
create or replace function public.sp_relay_take(p_id text)
returns text language plpgsql security definer set search_path = private, public as $$
declare v text;
begin
  delete from private.sp_relay where id = p_id and created_at > now() - interval '15 minutes' returning payload into v;
  return v;
end $$;
revoke all on function public.sp_relay_put(text, text) from public;
revoke all on function public.sp_relay_take(text) from public;
grant execute on function public.sp_relay_put(text, text) to anon, authenticated;
grant execute on function public.sp_relay_take(text) to anon, authenticated;


-- =====================================================================
-- BACKEND
-- =====================================================================
-- Khaya Ndlovu map: BACKEND (keep-alive, backups, cleanup, activity log, spam protection, animal history, road report votes)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run as many times as you like.
-- Run codes_all.sql before this one. At the end it runs a self-test (nothing is saved): every line should say PASS.

create extension if not exists pgcrypto with schema extensions;
alter table private.config add column if not exists last_daily timestamptz;
alter table private.config add column if not exists last_backup timestamptz;

-- ---------- helpers ----------
-- the map area (all roads plus about 1.5 km around them). Sightings and reports outside this are refused.
create or replace function public.kn_in_area(p_lat double precision, p_lng double precision)
returns boolean language sql immutable as $$ select p_lng between 30.884 and 31.004 and p_lat between -24.490 and -24.343 $$;

-- nearest gate within p_max metres (or null)
create or replace function public.kn_near_gate(p_lat double precision, p_lng double precision, p_max double precision)
returns text language sql immutable as $$
  select g.n from (values ('Main Gate', -24.3692966, 30.9660828), ('Northern Traverse Gate', -24.3645613, 30.9553299),
                          ('Southern Traverse Gate', -24.3928319, 30.9485677), ('Emergency Gate', -24.3866044, 30.9803489)) as g(n, la, lo)
  where sqrt(power((p_lat - g.la) * 111320, 2) + power((p_lng - g.lo) * 111320 * cos(radians(p_lat)), 2)) <= p_max
  order by power(p_lat - g.la, 2) + power(p_lng - g.lo, 2) limit 1 $$;

-- ---------- ACTIVITY LOG (admins see it under People > Activity) ----------
create table if not exists public.activity_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  who uuid,
  who_name text,
  kind text not null,
  detail text not null
);
create index if not exists activity_log_at on public.activity_log (at desc);
alter table public.activity_log enable row level security;
revoke all on public.activity_log from anon, authenticated;

create or replace function public.kn_log(p_kind text, p_detail text, p_who uuid default null, p_name text default null)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := coalesce(p_who, auth.uid()); nm text := p_name;
begin
  if nm is null and u is not null then select m.name into nm from public.members m where m.user_id = u; end if;
  insert into public.activity_log (who, who_name, kind, detail) values (u, coalesce(nm, 'System'), p_kind, left(p_detail, 300));
exception when others then null;  -- logging must never break the app
end $$;
revoke all on function public.kn_log(text, text, uuid, text) from public, anon, authenticated;

create or replace function public.kn_flag(k text) returns boolean language sql stable as $$ select coalesce(current_setting(k, true), '') = '1' $$;

-- codes made, cancelled, extended
create or replace function public.kn_trg_codes() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.kn_log('code', 'made ' || case new.kind when 'admin' then 'an admin invite ' when 'owner' then 'an owner invite ' else 'a guest code ' end
      || new.code || coalesce(' for ' || nullif(new.label, ''), '')
      || case when new.kind = 'guest' then ' (until ' || to_char(new.expires_at at time zone 'Africa/Johannesburg', 'DD Mon HH24:MI') || ')' else '' end);
  elsif tg_op = 'UPDATE' then
    if new.revoked and not old.revoked then perform public.kn_log('code', 'cancelled code ' || new.code);
    elsif new.expires_at is distinct from old.expires_at and not new.revoked then
      perform public.kn_log('code', 'changed code ' || new.code || ' to end ' || to_char(new.expires_at at time zone 'Africa/Johannesburg', 'DD Mon HH24:MI')); end if;
  end if;
  return null;
end $$;
drop trigger if exists kn_log_codes on public.guest_codes;
create trigger kn_log_codes after insert or update on public.guest_codes for each row execute function public.kn_trg_codes();

-- people joining, role changes, removals, guests ending
create or replace function public.kn_trg_members() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.kn_flag('kn.handover') then return null; end if;
  if tg_op = 'INSERT' then
    perform public.kn_log('join', new.name || ' joined as ' || case new.role when 'admin' then 'an admin' when 'guest' then 'a guest' else 'an owner' end
      || coalesce(' with code ' || new.code, '') || coalesce(', invited by ' || new.invited_by, ''), new.user_id, new.name);
  elsif tg_op = 'UPDATE' and new.role is distinct from old.role then
    if auth.uid() = new.user_id then perform public.kn_log('role', new.name || ' became ' || case new.role when 'admin' then 'an admin' when 'guest' then 'a guest' else 'an owner' end || ' (used a code)');
    else perform public.kn_log('role', 'made ' || new.name || ' ' || case new.role when 'admin' then 'an admin' when 'guest' then 'a guest' else 'an owner' end); end if;
  elsif tg_op = 'DELETE' then
    if public.kn_flag('kn.cleanup') then perform public.kn_log('end', old.name || '''s guest access ended', old.user_id, old.name);
    elsif auth.uid() = old.user_id then perform public.kn_log('leave', old.name || ' signed out', old.user_id, old.name);
    else perform public.kn_log('remove', 'removed ' || old.name); end if;
  end if;
  return null;
end $$;
drop trigger if exists kn_log_members on public.members;
create trigger kn_log_members after insert or update or delete on public.members for each row execute function public.kn_trg_members();

-- SOS raised and resolved
create or replace function public.kn_trg_sos() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then perform public.kn_log('sos', coalesce(new.name, 'Someone') || ' sent an SOS' || coalesce(' near ' || public.kn_near_gate(new.lat, new.lng, 1500), ''), new.user_id, new.name);
  elsif new.resolved and not old.resolved then perform public.kn_log('sos', 'SOS from ' || coalesce(new.name, 'someone') || ' resolved' || coalesce(' by ' || new.resolved_by, '')); end if;
  return null;
end $$;
do $$ begin
  drop trigger if exists kn_log_sos on public.sos;
  create trigger kn_log_sos after insert or update on public.sos for each row execute function public.kn_trg_sos();
exception when undefined_table then null; end $$;

-- cars coming in and leaving at a gate (from live location)
create or replace function public.kn_trg_live() returns trigger language plpgsql security definer set search_path = public as $$
declare g text;
begin
  if public.kn_flag('kn.cleanup') then return null; end if;
  if tg_op = 'INSERT' then
    g := public.kn_near_gate(new.lat, new.lng, 800);
    if g is not null and not exists (select 1 from public.activity_log a where a.who = new.user_id and a.kind = 'gate' and a.at > now() - interval '2 hours') then
      perform public.kn_log('gate', coalesce(new.name, 'Someone') || ' came in at ' || g, new.user_id, new.name); end if;
  elsif tg_op = 'DELETE' then
    g := public.kn_near_gate(old.lat, old.lng, 500);
    if g is not null and coalesce(old.status, '') like 'driving%' and not exists (select 1 from public.activity_log a where a.who = old.user_id and a.kind = 'gateout' and a.at > now() - interval '2 hours') then
      perform public.kn_log('gateout', coalesce(old.name, 'Someone') || ' left at ' || g, old.user_id, old.name); end if;
  end if;
  return null;
end $$;
do $$ begin
  drop trigger if exists kn_log_live on public.live_locs;
  create trigger kn_log_live after insert or delete on public.live_locs for each row execute function public.kn_trg_live();
exception when undefined_table then null; end $$;

-- news posts
create or replace function public.kn_trg_news() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.kn_log('news', 'posted news: ' || left(new.body, 80)); return null; end $$;
do $$ begin
  drop trigger if exists kn_log_news on public.announcements;
  create trigger kn_log_news after insert on public.announcements for each row execute function public.kn_trg_news();
exception when undefined_table then null; end $$;

-- admins delete any sightings (now also logged)
create or replace function public.admin_delete_sightings(p_cids text[])
returns int language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare n int;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  delete from public.sightings s where s.client_id = any(p_cids);
  get diagnostics n = row_count;
  delete from public.sightings_log l where l.client_id = any(p_cids);
  if n > 0 then perform public.kn_log('delete', 'deleted ' || n || case when n = 1 then ' sighting' else ' sightings' end); end if;
  return n;
end $$;
grant execute on function public.admin_delete_sightings(text[]) to authenticated;

create or replace function public.list_activity(p_limit int default 150)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  return coalesce((select json_agg(json_build_object('at', a.at, 'who', a.who_name, 'kind', a.kind, 'detail', a.detail) order by a.at desc)
    from (select * from public.activity_log order by at desc limit least(greatest(p_limit, 1), 500)) a), '[]'::json);
end $$;
grant execute on function public.list_activity(int) to authenticated;

-- ---------- ANIMAL HISTORY: every sighting is kept (small rows) so profiles, best time and likely spots learn from everything ----------
create table if not exists public.sightings_log (
  client_id text primary key,
  what text not null,
  lat double precision not null,
  lng double precision not null,
  created_at timestamptz not null,
  user_id uuid,
  still boolean not null default false,
  logged_at timestamptz not null default now()
);
create index if not exists sightings_log_t on public.sightings_log (created_at);
alter table public.sightings_log enable row level security;
revoke all on public.sightings_log from anon, authenticated;

create or replace function public.kn_trg_slog() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
  if tg_op = 'INSERT' then
    insert into public.sightings_log (client_id, what, lat, lng, created_at, user_id, still, photo, kill)
    values (new.client_id, new.what, new.lat, new.lng, new.created_at, new.user_id, coalesce((to_jsonb(new)->>'still')::boolean, false),
      coalesce((to_jsonb(new)->>'photo')::boolean, false), coalesce((to_jsonb(new)->>'kill')::boolean, false)) on conflict (client_id) do nothing;
  elsif tg_op = 'DELETE' and not public.kn_flag('kn.cleanup') then
    delete from public.sightings_log where client_id = old.client_id;  -- deleted on purpose: forget it. Expired: keep it.
  end if;
  exception when others then null;  -- the history must never stop a sighting from being shared
  end;
  return null;
end $$;
drop trigger if exists kn_slog on public.sightings;
create trigger kn_slog after insert or delete on public.sightings for each row execute function public.kn_trg_slog();
do $$ begin
  insert into public.sightings_log (client_id, what, lat, lng, created_at, user_id, still)
  select client_id, what, lat, lng, created_at, user_id, coalesce(still, false) from public.sightings on conflict (client_id) do nothing;
exception when undefined_column then
  insert into public.sightings_log (client_id, what, lat, lng, created_at, user_id)
  select client_id, what, lat, lng, created_at, user_id from public.sightings on conflict (client_id) do nothing;
end $$;

create or replace function public.sight_history(p_since timestamptz default null)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'members only'; end if;
  return coalesce((select json_agg(json_build_object('client_id', l.client_id, 'what', l.what, 'lat', round(l.lat::numeric, 5), 'lng', round(l.lng::numeric, 5), 'created_at', l.created_at) order by l.created_at)
    from (select * from public.sightings_log
          where not still and created_at > greatest(coalesce(p_since, now() - interval '400 days'), now() - interval '400 days')
          order by created_at desc limit 12000) l), '[]'::json);
end $$;
grant execute on function public.sight_history(timestamptz) to authenticated;

-- ---------- SPAM AND FAKE-SIGHTING PROTECTION ----------
create or replace function public.kn_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare n int; lim int; win interval;
begin
  if auth.uid() is null then return new; end if;  -- SQL editor / admin tools
  if not public.kn_in_area(new.lat, new.lng) then raise exception 'kn_reject: outside the reserve' using errcode = 'P0001'; end if;
  if new.created_at > now() + interval '10 minutes' then new.created_at := now(); end if;
  new.note := left(new.note, 300);
  if tg_table_name = 'sightings' then
    new.what := left(new.what, 30); lim := 10; win := interval '5 minutes';
    select count(*) into n from public.sightings s where s.user_id = auth.uid() and s.created_at between new.created_at - win and new.created_at + win;
  else
    new.kind := left(new.kind, 40); lim := 8; win := interval '10 minutes';
    select count(*) into n from public.reports r where r.user_id = auth.uid() and r.created_at between new.created_at - win and new.created_at + win;
  end if;
  if n >= lim then raise exception 'kn_reject: too many in a short time' using errcode = 'P0001'; end if;
  return new;
end $$;
drop trigger if exists guard_sightings on public.sightings;
create trigger guard_sightings before insert on public.sightings for each row execute function public.kn_guard();
drop trigger if exists guard_reports on public.reports;
create trigger guard_reports before insert on public.reports for each row execute function public.kn_guard();

-- ---------- ROAD REPORTS CONFIRMED BY OTHERS ----------
alter table public.reports add column if not exists confirms int not null default 0;
alter table public.reports add column if not exists clears int not null default 0;
alter table public.reports add column if not exists confirmed_at timestamptz;
create table if not exists public.report_votes (
  report_cid text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  still boolean not null,
  at timestamptz not null default now(),
  primary key (report_cid, user_id)
);
alter table public.report_votes enable row level security;
revoke all on public.report_votes from anon, authenticated;

-- only the person who reported it (or an admin) can edit a report directly; everyone else votes
drop policy if exists r_upd on public.reports;
create policy r_upd on public.reports for update to authenticated using (user_id = auth.uid() or public.is_admin()) with check (public.is_member());

-- "Still there" or "Road is clear". The reporter or an admin clears it straight away; otherwise 2 people in a row saying clear removes it.
create or replace function public.vote_report(p_cid text, p_still boolean)
returns json language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare r public.reports; c int; k int; last2 boolean[];
begin
  if not public.is_member() then raise exception 'members only'; end if;
  select * into r from public.reports where client_id = p_cid for update;
  if not found or r.resolved then return json_build_object('ok', true, 'resolved', true); end if;
  if not p_still and (r.user_id = auth.uid() or public.is_admin()) then
    update public.reports set resolved = true where client_id = p_cid;
    perform public.kn_log('road', 'cleared the report "' || r.kind || '"' || coalesce(' on ' || r.road, ''));
    return json_build_object('ok', true, 'resolved', true);
  end if;
  insert into public.report_votes (report_cid, user_id, still) values (p_cid, auth.uid(), p_still)
  on conflict (report_cid, user_id) do update set still = excluded.still, at = now();
  select count(*) filter (where still), count(*) filter (where not still) into c, k from public.report_votes where report_cid = p_cid;
  select array_agg(v.still) into last2 from (select still from public.report_votes where report_cid = p_cid order by at desc limit 2) v;
  if not p_still and k >= 2 and last2 = array[false, false] then
    update public.reports set resolved = true, clears = k, confirms = c where client_id = p_cid;
    perform public.kn_log('road', 'Road report "' || r.kind || '"' || coalesce(' on ' || r.road, '') || ' cleared by 2 people');
    return json_build_object('ok', true, 'resolved', true, 'confirms', c, 'clears', k);
  end if;
  update public.reports set confirms = c, clears = k,
    confirmed_at = case when p_still then now() else confirmed_at end,
    expires_at = case when p_still then greatest(expires_at, now() + interval '3 days') else expires_at end
  where client_id = p_cid;
  return json_build_object('ok', true, 'resolved', false, 'confirms', c, 'clears', k);
end $$;
grant execute on function public.vote_report(text, boolean) to authenticated;


-- ---------- LIVE ROUTES: where each car has driven in the last 3 hours ----------
-- Filled automatically from live location. Phones never send location within 400 m of home (unless you marked a sighting there),
-- so a route only starts 400 m from someone's house.
create table if not exists public.live_trail (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text,
  lat double precision not null,
  lng double precision not null,
  at timestamptz not null default now()
);
create index if not exists live_trail_u on public.live_trail (user_id, at);
alter table public.live_trail enable row level security;
revoke all on public.live_trail from anon, authenticated;

create or replace function public.kn_trg_trail() returns trigger language plpgsql security definer set search_path = public as $$
declare l public.live_trail;
begin
  if coalesce(new.status, '') = 'sos' then null; end if;
  select * into l from public.live_trail where user_id = new.user_id order by at desc limit 1;
  if l.id is null or l.at < now() - interval '20 seconds'
     or sqrt(power((new.lat - l.lat) * 111320, 2) + power((new.lng - l.lng) * 111320 * cos(radians(new.lat)), 2)) > 12 then
    insert into public.live_trail (user_id, name, lat, lng) values (new.user_id, new.name, new.lat, new.lng);
  end if;
  return null;
end $$;
do $$ begin
  drop trigger if exists kn_trail on public.live_locs;
  create trigger kn_trail after insert or update on public.live_locs for each row execute function public.kn_trg_trail();
exception when undefined_table then null; end $$;

create or replace function public.live_trails(p_hours double precision default 2)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('u', t.user_id, 'n', t.name, 'pts', t.pts)) from (
    select user_id, max(name) as name, json_agg(json_build_array(round(lng::numeric, 6), round(lat::numeric, 6), floor(extract(epoch from at))) order by at) as pts
    from public.live_trail where at > now() - make_interval(secs => least(greatest(p_hours, .1), 3) * 3600) and user_id <> auth.uid()
    group by user_id) t), '[]'::json);
end $$;
grant execute on function public.live_trails(double precision) to authenticated;


-- ---------- REQUIRED APP UPDATE ----------
-- which version of the app each person is running (phones report it when they open the map)
alter table public.members add column if not exists app_build int;
alter table public.members add column if not exists app_seen timestamptz;
create or replace function public.report_build(p_build int)
returns void language plpgsql security definer set search_path = public as $$
begin update public.members set app_build = p_build, app_seen = now() where user_id = auth.uid(); end $$;
grant execute on function public.report_build(int) to authenticated;

create or replace function public.member_versions()
returns json language plpgsql stable security definer set search_path = public, private as $$
begin
  if not public.is_owner() then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('u', user_id, 'v', app_build, 't', app_seen)) from public.members), '[]'::json);
end $$;
grant execute on function public.member_versions() to authenticated;

-- news that only people on an old version can see (old apps show news too, so this reaches everyone)
do $$ begin
  alter table public.announcements add column if not exists for_old_build int;
  drop policy if exists an_read on public.announcements;
  create policy an_read on public.announcements for select to authenticated using (public.is_member() and (for_old_build is null or public.is_admin()
    or coalesce((select m.app_build from public.members m where m.user_id = auth.uid()), 0) < for_old_build));
exception when undefined_table then null; end $$;

create or replace function public.announce_update()
returns int language plpgsql security definer set search_path = public, private as $$
declare b int; n int;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  select min_build into b from private.config limit 1;
  if coalesce(b, 0) = 0 then return 0; end if;
  update public.announcements set removed = true where for_old_build is not null and not removed;
  insert into public.announcements (client_id, body, expires_at, for_old_build)
  values ('upd-' || b || '-' || left(md5(random()::text || clock_timestamp()::text), 12),
    'Please update the map. A new version is out and your phone still has the old one, so you may miss sightings and alerts. ' ||
    'Close the map completely (swipe it away) and open it again where you have good signal, it updates by itself. ' ||
    'On iPhone, if it still looks the same after that: open the map, tap Update now and follow the steps. You stay signed in.',
    now() + interval '14 days', b);
  select count(*) into n from public.members where coalesce(app_build, 0) < b and (role <> 'guest' or expires_at > now());
  return n;
end $$;
grant execute on function public.announce_update() to authenticated;

-- An admin can require everyone to update. Phones running an older version are asked to update before they can use the map.
alter table private.config add column if not exists min_build int not null default 0;
create or replace function public.app_min_build()
returns int language sql stable security definer set search_path = public, private as $$ select coalesce((select min_build from private.config limit 1), 0) $$;
grant execute on function public.app_min_build() to anon, authenticated;
create or replace function public.set_min_build(p_build int)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set min_build = greatest(0, p_build);
  perform public.kn_log('update', 'asked everyone to update to version ' || p_build);
  perform public.announce_update();
end $$;
grant execute on function public.set_min_build(int) to authenticated;


-- ---------- KILL FLAG (predators on a kill stay on the map longer) ----------
alter table public.sightings add column if not exists kill boolean not null default false;
alter table public.sightings_log add column if not exists photo boolean not null default false;
alter table public.sightings_log add column if not exists kill boolean not null default false;

-- ---------- PHOTO ALBUM (photos kept 30 days) ----------
alter table private.config add column if not exists featured_photo text;
create or replace function public.photo_album(p_days int default 30)
returns json language plpgsql stable security definer set search_path = public, private as $$
begin
  if not public.is_member() then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('c', l.client_id, 'w', l.what, 'by', coalesce(m.name, 'Someone'), 't', l.created_at, 'lat', l.lat, 'lng', l.lng, 'k', l.kill) order by l.created_at desc)
    from (select * from public.sightings_log where photo and created_at > now() - make_interval(days => least(greatest(p_days, 1), 30)) order by created_at desc limit 300) l
    left join public.members m on m.user_id = l.user_id), '[]'::json);
end $$;
grant execute on function public.photo_album(int) to authenticated;
create or replace function public.featured_photo()
returns text language sql stable security definer set search_path = public, private as $$ select case when public.is_member() then (select featured_photo from private.config limit 1) end $$;
grant execute on function public.featured_photo() to authenticated;
create or replace function public.set_featured_photo(p_cid text)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set featured_photo = nullif(p_cid, '');
  if coalesce(p_cid, '') <> '' then perform public.kn_log('photo', 'picked the photo of the week'); end if;
end $$;
grant execute on function public.set_featured_photo(text) to authenticated;

-- ---------- PLACES (admins add, rename, move and remove places on the map) ----------
create table if not exists public.places (
  id text primary key,
  base text,                      -- name of a built-in place this changes (null for a new place)
  kind text not null default 'other',
  name text not null,
  note text,
  lat double precision not null,
  lng double precision not null,
  removed boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.places enable row level security;
drop policy if exists pl_read on public.places;
create policy pl_read on public.places for select to authenticated using (public.is_member());
revoke insert, update, delete on public.places from anon, authenticated;
grant select on public.places to authenticated;

create or replace function public.save_place(p_id text, p_base text, p_kind text, p_name text, p_note text, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public as $$
declare nm text := left(trim(coalesce(p_name, '')), 60); isnew boolean;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  if nm = '' then raise exception 'name needed'; end if;
  if not public.kn_in_area(p_lat, p_lng) then raise exception 'outside the reserve'; end if;
  isnew := not exists (select 1 from public.places where id = p_id);
  insert into public.places (id, base, kind, name, note, lat, lng, removed, updated_at, updated_by)
  values (p_id, nullif(p_base, ''), left(coalesce(p_kind, 'other'), 20), nm, left(nullif(trim(coalesce(p_note, '')), ''), 200), p_lat, p_lng, false, now(),
          (select name from public.members where user_id = auth.uid()))
  on conflict (id) do update set kind = excluded.kind, name = excluded.name, note = excluded.note, lat = excluded.lat, lng = excluded.lng,
    removed = false, updated_at = now(), updated_by = excluded.updated_by;
  perform public.kn_log('place', case when isnew and p_base is null then 'added the place ' when isnew then 'changed the place ' else 'changed the place ' end || nm);
end $$;
grant execute on function public.save_place(text, text, text, text, text, double precision, double precision) to authenticated;

create or replace function public.delete_place(p_id text, p_base text, p_name text, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  insert into public.places (id, base, kind, name, lat, lng, removed, updated_at, updated_by)
  values (p_id, nullif(p_base, ''), 'other', coalesce(nullif(p_name, ''), 'Place'), p_lat, p_lng, true, now(), (select name from public.members where user_id = auth.uid()))
  on conflict (id) do update set removed = true, updated_at = now(), updated_by = excluded.updated_by;
  perform public.kn_log('place', 'removed the place ' || coalesce(p_name, ''));
end $$;
grant execute on function public.delete_place(text, text, text, double precision, double precision) to authenticated;

-- ---------- CLOSED ROADS (navigation goes around them) ----------
create table if not exists public.road_closures (
  road text primary key,
  reason text,
  until timestamptz,
  by_name text,
  at timestamptz not null default now()
);
alter table public.road_closures enable row level security;
drop policy if exists rc_read on public.road_closures;
create policy rc_read on public.road_closures for select to authenticated using (public.is_member());
revoke insert, update, delete on public.road_closures from anon, authenticated;
grant select on public.road_closures to authenticated;

create or replace function public.close_road(p_road text, p_reason text, p_until timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  insert into public.road_closures (road, reason, until, by_name, at) values (p_road, left(nullif(trim(coalesce(p_reason, '')), ''), 120), p_until,
    (select name from public.members where user_id = auth.uid()), now())
  on conflict (road) do update set reason = excluded.reason, until = excluded.until, by_name = excluded.by_name, at = now();
  perform public.kn_log('road', 'closed ' || p_road || coalesce(' (' || nullif(trim(coalesce(p_reason, '')), '') || ')', ''));
end $$;
grant execute on function public.close_road(text, text, timestamptz) to authenticated;
create or replace function public.reopen_road(p_road text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  delete from public.road_closures where road = p_road;
  perform public.kn_log('road', 'reopened ' || p_road);
end $$;
grant execute on function public.reopen_road(text) to authenticated;

-- ---------- PRIVATE NOTES (only you can see yours) ----------
create table if not exists public.private_notes (
  client_id text primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (length(body) between 1 and 300),
  lat double precision not null,
  lng double precision not null,
  created_at timestamptz not null default now()
);
alter table public.private_notes enable row level security;
drop policy if exists pn_own on public.private_notes;
create policy pn_own on public.private_notes for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.private_notes to authenticated;

-- ---------- NIGHTLY CLEANUP ----------
create or replace function public.kn_cleanup()
returns json language plpgsql security definer set search_path = public, private as $$
declare n int; out jsonb := '{}';
begin
  perform set_config('kn.cleanup', '1', true);
  begin delete from public.sightings where expires_at < now() - interval '1 hour'; get diagnostics n = row_count; out := out || jsonb_build_object('sightings', n); exception when others then null; end;
  begin delete from public.reports where expires_at < now() or (resolved and created_at < now() - interval '1 day'); get diagnostics n = row_count; out := out || jsonb_build_object('reports', n); exception when others then null; end;
  begin delete from public.report_votes v where not exists (select 1 from public.reports r where r.client_id = v.report_cid); exception when others then null; end;
  begin delete from public.live_locs where updated_at < now() - interval '30 minutes'; get diagnostics n = row_count; out := out || jsonb_build_object('live', n); exception when others then null; end;
  begin delete from public.live_trail where at < now() - interval '3 hours'; exception when others then null; end;
  begin delete from public.road_closures where until is not null and until < now() - interval '1 day'; exception when others then null; end;
  begin delete from public.handover where (used_at is not null and used_at < now() - interval '7 days') or created_at < now() - interval '60 days'; exception when others then null; end;
  begin delete from public.members where role = 'guest' and expires_at < now() - interval '3 days'; get diagnostics n = row_count; out := out || jsonb_build_object('guests', n); exception when others then null; end;
  begin delete from public.guest_codes g where g.expires_at < now() - interval '30 days' and not exists (select 1 from public.members m where m.code = g.code); exception when others then null; end;
  begin delete from public.sos where resolved and updated_at < now() - interval '14 days'; exception when others then null; end;
  begin delete from public.animal_misses where created_at < now() - interval '45 days'; exception when others then null; end;
  begin delete from public.announcements where (removed or expires_at < now()) and created_at < now() - interval '30 days'; exception when others then null; end;
  begin delete from public.activity_log where at < now() - interval '1 year'; exception when others then null; end;
  begin delete from public.sightings_log where created_at < now() - interval '3 years'; exception when others then null; end;
  perform set_config('kn.cleanup', '', true);
  return out;
end $$;
revoke all on function public.kn_cleanup() from public, anon, authenticated;

-- called every day by the GitHub keep-alive job (and by phones). Keeps the free database awake and runs the cleanup once a day.
create or replace function public.kn_daily()
returns json language plpgsql security definer set search_path = public, private as $$
declare last timestamptz; r json;
begin
  select last_daily into last from private.config limit 1;
  if last is not null and last > now() - interval '20 hours' then return json_build_object('ok', true, 'cleanup', 'already ran today'); end if;
  update private.config set last_daily = now();
  r := public.kn_cleanup();
  return json_build_object('ok', true, 'cleanup', r);
end $$;
grant execute on function public.kn_daily() to anon, authenticated;

-- photos of sightings that are gone (the app deletes these files; the database is not allowed to)
create or replace function public.orphan_photos()
returns json language plpgsql stable security definer set search_path = public, storage as $$
begin
  if not public.is_member() then return '[]'::json; end if;
  return coalesce((select json_agg(o.name) from (select name from storage.objects
    where bucket_id = 'sightings' and not exists (select 1 from public.sightings s where s.client_id || '.jpg' = storage.objects.name)
      and not exists (select 1 from public.sightings_log l where l.client_id || '.jpg' = storage.objects.name and l.created_at > now() - interval '30 days') limit 200) o), '[]'::json);
end $$;
grant execute on function public.orphan_photos() to authenticated;
do $$ begin
  drop policy if exists kn_photo_del on storage.objects;
  create policy kn_photo_del on storage.objects for delete to authenticated using (bucket_id = 'sightings' and public.is_member()
    and (owner = auth.uid() or (not exists (select 1 from public.sightings s where s.client_id || '.jpg' = name)
      and not exists (select 1 from public.sightings_log l where l.client_id || '.jpg' = name and l.created_at > now() - interval '30 days'))));
exception when others then null; end $$;

-- ---------- ENCRYPTED BACKUP ----------
-- The whole map database, locked with a key only Jamie has (KHAYA-BACKUP-PRIVATE-KEY.asc). Anyone can ask for it, nobody else can open it.
create or replace function public.kn_backup_build()
returns text language plpgsql security definer set search_path = public, private, extensions as $$
declare j jsonb := jsonb_build_object('made_at', now(), 'app', 'khaya-ndlovu-map'); part jsonb; t text;
begin
  foreach t in array array['members', 'guest_codes', 'sightings', 'sightings_log', 'reports', 'report_votes', 'drives', 'announcements', 'sos', 'animal_misses', 'activity_log', 'map_data', 'places', 'road_closures', 'private_notes'] loop
    begin
      execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', t) into part;
      j := j || jsonb_build_object(t, part);
    exception when others then null; end;
  end loop;
  begin select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into part from private.config c; j := j || jsonb_build_object('config', part); exception when others then null; end;
  return armor(pgp_pub_encrypt(j::text, dearmor($k$-----BEGIN PGP PUBLIC KEY BLOCK-----

mQGNBGrrNMcBDADMJ/iAzm3g83j9AtPxSUHHFrOgQ8V0ljZjHO81kmNqPaad/Voy
m+Bk5wBJEospvwagQfq5a1ppv2f8Op6zA13LT4Z1IbbCIyk91FfOqx1GCGtbzwPb
JxXo4TTtn0hkUCdFR+dA+zR/PQTJqAMupjpJIz6vpMa4io4TebKV7xqSdg//POoA
qth45Oy9qvhiWqIpR/dO8ryKJwP6ZT971yBfCsLNUFzjHAP4kLImHVrUhlCcYlOb
l0LeezQHebK+elwz5ur2IPg72lxfQxhxTKowuW92x1XviFZkrIcIuVCFj6/PNX75
wW7WJcl898Q/ErpV6w/lF1otdnak03GVm94X9vuAsGMxkQWsh7v/wTA18MklWqfx
8ULBLkadBk6pG/rcfg/v3dmGOY8BPftUwra5IE7vwgwojRqZkY9eDAg9V0qcn8XW
78xiX6lUwWI3LFDHiXeA3a+bXupi0Nbi1UPkWNNPeZvoZhOxXwqM6ImBZlCUsfBG
0gVuhAf4K0uCNfEAEQEAAbQzS2hheWEgTmRsb3Z1IE1hcCBCYWNrdXAgPGJhY2t1
cEBraGF5YS1uZGxvdnUubG9jYWw+iQHSBBMBCgA8FiEENcderAGdqQbdoRDh/9+/
zZO8+r4FAmrrNMcDGy8EBQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJEP/f
v82TvPq+tc0L/iu5gr638yhDrSwyBlgvmoi97h7UbXtind6la00WC9gkGajHFmCC
AGLFKOEW9sVhqY3PY65I/Y/u5EBB0LA/h2QcI81R5778Z5Rxs1+SWPY6eZqHG+z2
/x74Tg7H+K35TC87iQ/WFMururO91gjwhagLX0uG1O381lwgkysj4J36sFEaHAjZ
S64kBQ8dc9gnWmvBYBkHUx+6mNvuHvvAPZIrJlnGfSOH2rvOoZNsUVn651KxVnop
GD/V8yCAGoQwrRwesoeo3M52Tf8VreyDlUHJqM36layMKl4SbxhgvZT8NFnBWcQL
SE0MdZrs5Uuo17ytS0vlBNBjgPwcXDz6RqSqBN5GTV5H1HI4zXMhHG6/Xn1WMXlB
MkOBjZKFyAEcrLCrhmwAQnjRySq+pAhHM/iI7nGMVlgv+OG8H7xIu6fzHgMwm/vA
cdUdeaMWuGmaKE3v1vN5OoAFm7EQR9szAo+8cq1E8gcwrZyMCQ1AbaH8xYQGqJMc
ITo1I/HmXP09fLkBjQRq6zTHAQwA20VHdXAWa3GuDUbNwtAcOLWblxA73dFhA1kE
Y13s+fN+Q5AaNEKoDDhHY9UHA7ctlbml21b42+temtwQZr+eHTwsXQYrFHMAM1Wk
ZBDbheksU6Plns6KxdttXM6orvrExDJEhC+Ti4B8KCNceKTctdP2y/BTbzTemTZl
OeFGKnHlcLYPbMUpHj+44n0T7HNrIGCuDCTgtWk8Ttr6eXPbDbe8jARisyF6ePig
DaazL70a2ROsmnJORXonWNuzNC6YNj2kO+oXelhu+6gdNjL1vr0WPXc7OFQlpMmu
zsPQvDuNk4O75N5Gu9xwkz7gl90usKup1CVUzWJ4kuYg2/Dk2KbsEbAvFzlKTTJt
XsGJhb3IAqcxQzcPuSmPfsNAq6QnHfiPslpwt8L0nXIil5VNoagCwruFUIstujgO
TQW3YRNExzjB49zvp1AlgfMo+o5Nc9dGST93iZNzGn7R1wMjcEEdKrHasYgwgIaz
ix9Ol1pJG1ULRqYEDBUO4YbqWJD5ABEBAAGJA2wEGAEKACAWIQQ1x16sAZ2pBt2h
EOH/37/Nk7z6vgUCaus0xwIbLgHACRD/37/Nk7z6vsD0IAQZAQoAHRYhBKjU6tKB
WVoZdMIo8UYdgnIje41ABQJq6zTHAAoJEEYdgnIje41AN1oL/2zFhe3RsLAi7aHN
LeHAkVC0JdJzfBQYprIxl3HWsKFBYEFNn8Dmmizbn8sc34BglLvAt5Ha6VI+7S4X
jcYAeNxMpAraDGHltVaqmHsdXHWter1PDUqa02urTrZ2BoRjiqj+LBBrjzpBa7Qa
A5sQOFiptDiOr58cutb2Hj21DvMURduoZuOuqDmsGGzczNTe151qG4Fi00JLpjT0
vmQOhAbXgbIzSFwlP7WTFF+DNvYSX6lP2qNorwTCEe+BCpsUElu3kkIdKMcoWTVx
IPwWWZL8ekms0xCXGVI5dTSIkeyI8b4mfXBo4zcF0G3iXeW6TvREydkyKvQj+p/z
x52H+V6/VDuugsOtLZ3az62ERRo5L6POIOOPnTgikdI8WKnxm0bWSEC4pHcCC/iU
vL7leE0gYWprzYkTxjOG52oW2+WIsEGKhGGDndiZ1kYGmfh9U5HKWww5mhkakDb/
m8DIxFgEaDYELkttE78Owid1xa/3/nD0mx87t1hW/WJtgovNbu6nC/9BoqsM1oLy
kYSeUdXtR+FZQOKioroOFM++eG+32K+rLL63hnpi3ncahPNfh/ob/Rivd8oRkq1W
zQNpg9lNoHF+8AuZijOD7PEMEIPi7dyu82oi5E+ICRQFlbV6a/aGPYGKHiwwVKOl
nF6GVrAz72E9Jn20K0Ad4OaOp1Ty4YuZ/DUBo1hvrg/yTlKpXlEzYhkg6M6U03Pt
7tExf6r7whe3q+981cgnx+Q67/dt48jFhX6w6rxr026udJQTm8HRl7d2V+0I/TW+
/dI3v5XawLzSG3KsExfvoMODsOt5V5KBaU2za5loUWIHjmWReoYssvek9jk0Q1bv
3AKliIdJfWlAtQ+2XyQfjeXAxbnBS6ITpoeIAUslOXsAhs5luspJ1QK3WYALET0r
5ptarC7u6mFwRZ3c3QDtP7bDK8cHNwTMIiTm34eVMFoNyiYchNDqutRtKV+VwArs
VgRTlcwaxEOxsfASIKV/BtTaGtM8206o/tLCGTPBlcAkamHNG+ImJB0=
=3nUb
-----END PGP PUBLIC KEY BLOCK-----$k$), 'compress-algo=2'));
end $$;
revoke all on function public.kn_backup_build() from public, anon, authenticated;

create or replace function public.kn_backup()
returns text language plpgsql security definer set search_path = public, private as $$
declare last timestamptz;
begin
  select last_backup into last from private.config limit 1;
  if last is not null and last > now() - interval '6 hours' then return null; end if;
  update private.config set last_backup = now();
  return public.kn_backup_build();
end $$;
grant execute on function public.kn_backup() to anon, authenticated;

-- ---------- SELF-TEST (nothing is saved) ----------
create or replace function public.kn_backend_selftest()
returns table(test text, result text) language plpgsql security definer set search_path = public, auth, private as $$
#variable_conflict use_column
declare a uuid := gen_random_uuid(); g uuid := gen_random_uuid(); h uuid := gen_random_uuid(); oc text; r json; c text; b text; n int; out text[] := '{}';
  ok boolean;
begin
  select 'ADMIN' || upper(replace(invite_code, ' ', '')) into oc from private.config limit 1;
  begin
    insert into auth.users (id) values (a), (g), (h);
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    r := public.join_reserve2(oc, 'T Admin');
    c := public.create_code('Visitor', now() + interval '1 day', 'guest');
    out := out || array['Activity log records new codes', case when exists (select 1 from public.activity_log where kind = 'code' and detail like '%' || c || '%') then 'PASS' else 'FAIL' end];
    perform set_config('request.jwt.claims', json_build_object('sub', g)::text, true); perform set_config('request.jwt.claim.sub', g::text, true);
    r := public.join_reserve2(c, 'T Guest');
    out := out || array['Activity log records people joining', case when exists (select 1 from public.activity_log where kind = 'join' and detail like 'T Guest joined%') then 'PASS' else 'FAIL' end];
    -- sightings inside / outside the reserve
    insert into public.sightings (client_id, what, lat, lng, created_at) values ('kt-1', 'Lion', -24.377, 30.963, now());
    out := out || array['Sighting on the reserve is accepted', 'PASS'];
    out := out || array['Every sighting kept in the animal history', case when exists (select 1 from public.sightings_log where client_id = 'kt-1') then 'PASS' else 'FAIL' end];
    begin insert into public.sightings (client_id, what, lat, lng, created_at) values ('kt-x', 'Lion', -26.2, 28.04, now());
      out := out || array['Sighting far away (Johannesburg) is refused', 'FAIL'];
    exception when others then out := out || array['Sighting far away (Johannesburg) is refused', case when sqlerrm like 'kn_reject%' then 'PASS' else 'FAIL ' || sqlerrm end]; end;
    ok := false;
    begin for i in 2 .. 12 loop insert into public.sightings (client_id, what, lat, lng, created_at) values ('kt-' || i, 'Zebra', -24.377, 30.963, now()); end loop;
    exception when others then ok := sqlerrm like 'kn_reject%'; end;
    out := out || array['Spam (11 sightings in 5 minutes) is stopped', case when ok then 'PASS' else 'FAIL' end];
    r := public.sight_history(null);
    out := out || array['Animal history comes back for members', case when json_array_length(r) >= 1 then 'PASS' else 'FAIL' end];
    -- road reports
    insert into public.reports (client_id, kind, lat, lng, created_at) values ('kr-1', 'Washed out', -24.377, 30.963, now());
    perform set_config('request.jwt.claims', json_build_object('sub', h)::text, true); perform set_config('request.jwt.claim.sub', h::text, true);
    insert into public.members (user_id, name, role) values (h, 'T Owner', 'owner');
    r := public.vote_report('kr-1', true);
    out := out || array['"Still there" confirms a report', case when (r->>'confirms')::int = 1 and not (r->>'resolved')::boolean then 'PASS' else 'FAIL ' || r::text end];
    r := public.vote_report('kr-1', false);
    out := out || array['One "Road is clear" is not enough', case when not (r->>'resolved')::boolean then 'PASS' else 'FAIL ' || r::text end];
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    insert into public.reports (client_id, kind, lat, lng, created_at) values ('kr-2', 'Muddy', -24.377, 30.963, now());
    perform set_config('request.jwt.claims', json_build_object('sub', h)::text, true); perform set_config('request.jwt.claim.sub', h::text, true);
    perform public.vote_report('kr-2', false);
    perform set_config('request.jwt.claims', json_build_object('sub', g)::text, true); perform set_config('request.jwt.claim.sub', g::text, true);
    r := public.vote_report('kr-2', false);
    out := out || array['Two people saying "Road is clear" removes it', case when (r->>'resolved')::boolean then 'PASS' else 'FAIL ' || r::text end];
    -- cleanup and history
    update public.sightings set expires_at = now() - interval '2 hours' where client_id = 'kt-1';
    perform public.kn_cleanup();
    out := out || array['Cleanup removes expired sightings', case when not exists (select 1 from public.sightings where client_id = 'kt-1') then 'PASS' else 'FAIL' end];
    out := out || array['...but keeps them in the animal history', case when exists (select 1 from public.sightings_log where client_id = 'kt-1') then 'PASS' else 'FAIL' end];
    -- activity for admins
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    r := public.list_activity(20);
    out := out || array['Admins can read the activity log', case when json_array_length(r) >= 2 then 'PASS' else 'FAIL' end];
    perform set_config('request.jwt.claims', json_build_object('sub', g)::text, true); perform set_config('request.jwt.claim.sub', g::text, true);
    begin r := public.list_activity(20); out := out || array['Guests cannot read the activity log', 'FAIL'];
    exception when others then out := out || array['Guests cannot read the activity log', 'PASS']; end;
    -- live routes
    perform set_config('request.jwt.claims', json_build_object('sub', h)::text, true); perform set_config('request.jwt.claim.sub', h::text, true);
    insert into public.live_locs (user_id, name, lat, lng, status) values (h, 'T Owner', -24.377, 30.963, 'driving');
    update public.live_locs set lat = -24.378, lng = 30.964, updated_at = now() where user_id = h;
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    r := public.live_trails(2);
    out := out || array['Other members see the route a car has driven', case when json_array_length(r) = 1 and json_array_length(r->0->'pts') = 2 then 'PASS' else 'FAIL ' || r::text end];
    -- versions + targeted news
    perform set_config('request.jwt.claims', json_build_object('sub', g)::text, true); perform set_config('request.jwt.claim.sub', g::text, true);
    perform public.report_build(50);
    perform set_config('request.jwt.claims', json_build_object('sub', h)::text, true); perform set_config('request.jwt.claim.sub', h::text, true);
    perform public.report_build(64);
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    -- required update
    perform public.set_min_build(60);
    out := out || array['Admins can require everyone to update', case when public.app_min_build() = 60 then 'PASS' else 'FAIL' end];
    out := out || array['Update news is posted automatically', case when exists (select 1 from public.announcements where for_old_build = 60 and not removed) then 'PASS' else 'FAIL' end];
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', g)::text, true); perform set_config('request.jwt.claim.sub', g::text, true);
    begin perform public.set_min_build(1); out := out || array['Guests cannot require an update', 'FAIL'];
    exception when others then out := out || array['Guests cannot require an update', 'PASS']; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    -- places, closed roads, kill flag
    perform set_config('request.jwt.claims', json_build_object('sub', a)::text, true); perform set_config('request.jwt.claim.sub', a::text, true);
    perform public.save_place('pt-1', null, 'hide', 'New bird hide', 'Best early', -24.376, 30.962);
    perform public.close_road('Hyena Road', 'Washed away', now() + interval '2 days');
    out := out || array['Admins add places and close roads', case when exists (select 1 from public.places where id = 'pt-1' and not removed) and exists (select 1 from public.road_closures where road = 'Hyena Road') then 'PASS' else 'FAIL' end];
    perform set_config('request.jwt.claims', json_build_object('sub', g)::text, true); perform set_config('request.jwt.claim.sub', g::text, true);
    begin perform public.save_place('pt-2', null, 'hide', 'Guest place', '', -24.376, 30.962); out := out || array['Guests cannot change places', 'FAIL'];
    exception when others then out := out || array['Guests cannot change places', 'PASS']; end;
    insert into public.sightings (client_id, what, lat, lng, created_at, kill) values ('kt-kill', 'Lion', -24.377, 30.963, now() - interval '20 minutes', true);
    out := out || array['Kill sightings are kept in the history', case when exists (select 1 from public.sightings_log where client_id = 'kt-kill' and kill) then 'PASS' else 'FAIL' end];
    -- backup
    b := public.kn_backup_build();
    out := out || array['Encrypted backup works', case when b like '-----BEGIN PGP MESSAGE-----%' then 'PASS (' || length(b) || ' characters, locked)' else 'FAIL' end];
    raise exception 'kn_rollback';
  exception when others then
    if sqlerrm <> 'kn_rollback' then out := out || array['Test stopped with an error', 'FAIL: ' || sqlerrm]; end if;
  end;
  for i in 1 .. coalesce(array_length(out, 1), 0) / 2 loop test := out[i*2-1]; result := out[i*2]; return next; end loop;
end $$;
revoke all on function public.kn_backend_selftest() from public, anon, authenticated;

notify pgrst, 'reload schema';


-- =====================================================================
-- PUSH THE UPDATE (version 70)
-- =====================================================================

alter table private.config add column if not exists min_build int not null default 0;
alter table public.members add column if not exists app_build int;
alter table public.members add column if not exists app_seen timestamptz;
alter table public.announcements add column if not exists for_old_build int;

create or replace function public.app_min_build()
returns int language sql stable security definer set search_path = public, private as $$ select coalesce((select min_build from private.config limit 1), 0) $$;
grant execute on function public.app_min_build() to anon, authenticated;

create or replace function public.report_build(p_build int)
returns void language plpgsql security definer set search_path = public as $$
begin update public.members set app_build = p_build, app_seen = now() where user_id = auth.uid(); end $$;
grant execute on function public.report_build(int) to authenticated;

create or replace function public.member_versions()
returns json language plpgsql stable security definer set search_path = public, private as $$
begin
  if not public.is_owner() then return '[]'::json; end if;
  return coalesce((select json_agg(json_build_object('u', user_id, 'v', app_build, 't', app_seen)) from public.members), '[]'::json);
end $$;
grant execute on function public.member_versions() to authenticated;

drop policy if exists an_read on public.announcements;
create policy an_read on public.announcements for select to authenticated using (public.is_member() and (for_old_build is null or public.is_admin()
  or coalesce((select m.app_build from public.members m where m.user_id = auth.uid()), 0) < for_old_build));

create or replace function public.announce_update()
returns int language plpgsql security definer set search_path = public, private as $$
declare b int; n int;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  select min_build into b from private.config limit 1;
  if coalesce(b, 0) = 0 then return 0; end if;
  update public.announcements set removed = true where for_old_build is not null and not removed;
  insert into public.announcements (client_id, body, expires_at, for_old_build)
  values ('upd-' || b || '-' || left(md5(random()::text || clock_timestamp()::text), 12),
    'Please update the map. A new version is out and your phone still has the old one, so you may miss sightings and alerts. ' ||
    'Close the map completely (swipe it away) and open it again where you have good signal, it updates by itself. ' ||
    'On iPhone, if it still looks the same after that: open the map, tap Update now and follow the steps. You stay signed in.',
    now() + interval '14 days', b);
  select count(*) into n from public.members where coalesce(app_build, 0) < b and (role <> 'guest' or expires_at > now());
  return n;
end $$;
grant execute on function public.announce_update() to authenticated;

create or replace function public.set_min_build(p_build int)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set min_build = greatest(0, p_build);
  begin perform public.kn_log('update', 'asked everyone to update to version ' || p_build); exception when others then null; end;
  perform public.announce_update();
end $$;
grant execute on function public.set_min_build(int) to authenticated;

-- push it now: require version 70 and post the news (as the first admin, so it shows who sent it)
update private.config set min_build = 70;
do $$
declare adm uuid := (select user_id from public.members where role = 'admin' order by joined_at limit 1);
begin
  if adm is null then raise notice 'No admin found, news not posted'; return; end if;
  perform set_config('request.jwt.claim.sub', adm::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm)::text, true);
  perform public.announce_update();
end $$;

notify pgrst, 'reload schema';


-- ===================== CHECK: every line should say YES =====================
select 'Tables: members, sightings, reports, drives, news, SOS, live location, places, notes' as "check",
  case when (select count(*) from information_schema.tables where table_schema = 'public' and table_name in ('members','sightings','reports','drives','announcements','sos','live_locs','animal_misses','places','road_closures','private_notes')) = 11 then 'YES' else 'NO' end as result
union all select 'Codes and logins self-test', case when (select count(*) from public.kn_selftest() where result not like 'PASS%') = 0 then 'YES' else 'NO: ' || (select string_agg(test, ', ') from public.kn_selftest() where result not like 'PASS%') end
union all select 'Backend self-test', case when (select count(*) from public.kn_backend_selftest() where result not like 'PASS%') = 0 then 'YES' else 'NO: ' || (select string_agg(test, ', ') from public.kn_backend_selftest() where result not like 'PASS%') end
union all select 'Everyone must be on version 70', case when (select min_build from private.config limit 1) = 70 then 'YES' else 'NO' end
union all select 'Update news posted (only old versions see it)', case when exists (select 1 from public.announcements where for_old_build = 70 and not removed) then 'YES' else 'NO' end
union all select 'Your owner code (unchanged)', (select upper(invite_code) from private.config limit 1)
union all select 'People who still need to update', (select count(*)::text from public.members where coalesce(app_build, 0) < 70 and (role <> 'guest' or expires_at > now()));
