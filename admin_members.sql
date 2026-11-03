-- Khaya Ndlovu map: admin code, owner/admin invites, owners & guests list
-- Run AFTER guest_codes.sql. Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.
--
-- ADMIN CODE = the word ADMIN in front of your owner code. Owner code KHAYA2026 -> admin code ADMINKHAYA2026.
-- The shared admin code works for 4 people at most. After that, admins can make as many admins as they like:
-- tap Make admin on an owner, or send a one-time Admin invite.
-- Owners and admins never expire. Only an admin can remove them.

alter table public.members add column if not exists last_seen timestamptz;
alter table public.members add column if not exists invited_by text;

alter table public.guest_codes add column if not exists kind text not null default 'guest';
alter table public.guest_codes add column if not exists uses int not null default 0;

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
create or replace function public.join_reserve2(code text, display_name text)
returns json language plpgsql security definer set search_path = public, private as $$
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
    update public.guest_codes set uses = uses + 1 where code = g.code and coalesce(cur.code, '') <> g.code;
    return json_build_object('ok', true, 'role', (select role from public.members where user_id = auth.uid()), 'expires_at', null);
  end if;

  -- guest code
  insert into public.members (user_id, name, role, code, expires_at, last_seen, invited_by)
  values (auth.uid(), left(coalesce(nullif(trim(display_name), ''), 'Guest'), 40), 'guest', g.code, g.expires_at, now(), g.created_by_name)
  on conflict (user_id) do update set name = excluded.name, last_seen = now(),
    role = case when members.role in ('owner', 'admin') then members.role else 'guest' end,
    code = case when members.role in ('owner', 'admin') then members.code else excluded.code end,
    invited_by = case when members.role in ('owner', 'admin') then members.invited_by else excluded.invited_by end,
    expires_at = case when members.role in ('owner', 'admin') then members.expires_at else excluded.expires_at end;
  update public.guest_codes set uses = uses + 1 where code = g.code;
  return json_build_object('ok', true, 'role', (select role from public.members where user_id = auth.uid()),
                           'expires_at', (select expires_at from public.members where user_id = auth.uid()));
end $$;
grant execute on function public.join_reserve2(text, text) to authenticated;

-- status check; also records when each person last opened the map. Owners/admins never expire.
drop function if exists public.my_status();
create function public.my_status()
returns json language plpgsql volatile security definer set search_path = public as $$
declare m public.members;
begin
  select * into m from public.members where user_id = auth.uid();
  if not found then return json_build_object('member', false, 'active', false); end if;
  update public.members set last_seen = now() where user_id = auth.uid() and (last_seen is null or last_seen < now() - interval '2 minutes');
  if m.role in ('owner', 'admin') then
    return json_build_object('member', true, 'role', m.role, 'expires_at', null, 'active', true);
  end if;
  return json_build_object('member', true, 'role', m.role, 'expires_at', m.expires_at,
    'active', (m.expires_at is null or m.expires_at > now())
              and not exists (select 1 from public.guest_codes g where g.code = m.code and g.revoked));
end $$;
grant execute on function public.my_status() to authenticated;

-- make a code: owners make guest codes; admins can also make one-time owner or admin invites
create or replace function public.create_code(p_label text, p_expires timestamptz, p_kind text)
returns text language plpgsql security definer set search_path = public, private as $$
declare c text; tries int := 0; abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; k text := coalesce(p_kind, 'guest');
begin
  if k not in ('guest', 'owner', 'admin') then raise exception 'bad kind'; end if;
  if k = 'guest' and not public.is_owner() then raise exception 'owners only'; end if;
  if k <> 'guest' and not public.is_admin() then raise exception 'admins only'; end if;
  if k = 'guest' and p_expires <= now() then raise exception 'expiry must be in the future'; end if;
  loop
    select string_agg(substr(abc, 1 + floor(random() * length(abc))::int, 1), '') into c from generate_series(1, 6);
    exit when not exists (select 1 from public.guest_codes where code = c);
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

-- every code with who made it and who used it (owner/admin invites only shown to admins)
create or replace function public.list_guest_codes()
returns json language plpgsql stable security definer set search_path = public as $$
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
    where g.created_at > now() - interval '120 days'
      and (g.kind = 'guest' or public.is_admin())) x), '[]'::json);
end $$;
grant execute on function public.list_guest_codes() to authenticated;

-- owners and admins: everyone on the map (expired guests are left out)
create or replace function public.list_members()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  return coalesce((select json_agg(row_to_json(x) order by x.role_order, x.name) from (
    select m.user_id, m.name, m.role, m.joined_at, m.last_seen,
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
begin
  if auth.uid() is null then return; end if;
  begin delete from public.live_locs where user_id = auth.uid(); exception when undefined_table then null; end;
  delete from public.members where user_id = auth.uid();
end $$;
grant execute on function public.leave_reserve() to authenticated;

-- your codes:
select upper(invite_code) as "OWNER CODE", 'ADMIN' || upper(replace(invite_code, ' ', '')) as "ADMIN CODE (max 4 people)" from private.config;
