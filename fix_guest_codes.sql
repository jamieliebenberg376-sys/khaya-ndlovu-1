-- FIX: guest codes / invite codes not working
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.
-- (The join step mixed up the word "code" and crashed for guest codes and owner/admin invites.)

alter table public.members add column if not exists last_seen timestamptz;
alter table public.members add column if not exists invited_by text;
alter table public.members add column if not exists last_login timestamptz;
alter table public.guest_codes add column if not exists kind text not null default 'guest';
alter table public.guest_codes add column if not exists uses int not null default 0;

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
  update public.guest_codes gc set uses = gc.uses + 1 where gc.code = g.code;
  return json_build_object('ok', true, 'role', (select role from public.members where user_id = auth.uid()),
                           'expires_at', (select expires_at from public.members where user_id = auth.uid()));
end $$;
revoke all on function public.join_core(text, text) from public, anon, authenticated;

-- the app calls this one: joins, then records the sign-in time
create or replace function public.join_reserve2(code text, display_name text)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  r := public.join_core(code, display_name);
  if (r->>'ok')::boolean then update public.members set last_login = now(), last_seen = now() where user_id = auth.uid(); end if;
  return r;
end $$;
grant execute on function public.join_reserve2(text, text) to authenticated;

-- check: this should list your live codes
select code, kind, expires_at, revoked, uses from public.guest_codes where not revoked and expires_at > now() order by created_at desc;
