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

-- your codes, then the self-test results (every line should say PASS):
select upper(invite_code) as "OWNER CODE", 'ADMIN' || upper(replace(invite_code, ' ', '')) as "ADMIN CODE (max 4 people)" from private.config;
select * from public.kn_selftest();
