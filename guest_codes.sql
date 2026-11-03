-- Khaya Ndlovu map: owner and guest codes
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.
-- Your existing invite code (private.config) becomes the OWNER code.

alter table public.members add column if not exists role text not null default 'owner';
alter table public.members add column if not exists code text;
alter table public.members add column if not exists expires_at timestamptz;

create table if not exists public.guest_codes (
  code text primary key,
  label text,
  created_by uuid references auth.users(id) on delete set null,
  created_by_name text,
  expires_at timestamptz not null,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.guest_codes enable row level security;
revoke all on public.guest_codes from anon, authenticated;

-- a member only counts while their access hasn't expired
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                 where user_id = auth.uid() and (expires_at is null or expires_at > now()));
$$;

create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where user_id = auth.uid() and role = 'owner');
$$;
grant execute on function public.is_owner() to authenticated;

-- join with the owner code or a guest code; returns {ok, role, expires_at}
create or replace function public.join_reserve2(code text, display_name text)
returns json language plpgsql security definer set search_path = public, private as $$
declare c text := upper(trim(code)); g public.guest_codes;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if exists (select 1 from private.config where upper(invite_code) = c) then
    insert into public.members (user_id, name, role, code, expires_at)
    values (auth.uid(), left(coalesce(nullif(trim(display_name), ''), 'Owner'), 40), 'owner', null, null)
    on conflict (user_id) do update set name = excluded.name, role = 'owner', code = null, expires_at = null;
    return json_build_object('ok', true, 'role', 'owner', 'expires_at', null);
  end if;
  select * into g from public.guest_codes where upper(guest_codes.code) = c;
  if not found or g.revoked or g.expires_at <= now() then
    return json_build_object('ok', false, 'reason', case when not found then 'wrong' when g.revoked then 'revoked' else 'expired' end);
  end if;
  insert into public.members (user_id, name, role, code, expires_at)
  values (auth.uid(), left(coalesce(nullif(trim(display_name), ''), 'Guest'), 40), 'guest', g.code, g.expires_at)
  on conflict (user_id) do update set name = excluded.name,
    role = case when members.role = 'owner' then 'owner' else 'guest' end,
    code = case when members.role = 'owner' then members.code else excluded.code end,
    expires_at = case when members.role = 'owner' then members.expires_at else excluded.expires_at end;
  return json_build_object('ok', true, 'role', 'guest', 'expires_at', g.expires_at);
end $$;
grant execute on function public.join_reserve2(text, text) to authenticated;

-- the app checks this on every sync; guests whose code ended get logged out
create or replace function public.my_status()
returns json language sql stable security definer set search_path = public as $$
  select coalesce((select json_build_object('member', true, 'role', m.role, 'expires_at', m.expires_at,
      'active', (m.expires_at is null or m.expires_at > now())
                and not exists (select 1 from public.guest_codes g where g.code = m.code and g.revoked))
    from public.members m where m.user_id = auth.uid()), json_build_object('member', false, 'active', false));
$$;
grant execute on function public.my_status() to authenticated;

-- owners: create a guest code
create or replace function public.create_guest_code(p_label text, p_expires timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare c text; tries int := 0; abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  if p_expires <= now() then raise exception 'expiry must be in the future'; end if;
  loop
    select string_agg(substr(abc, 1 + floor(random() * length(abc))::int, 1), '') into c from generate_series(1, 6);
    exit when not exists (select 1 from public.guest_codes where code = c)
          and not exists (select 1 from private.config where upper(invite_code) = c);
    tries := tries + 1; if tries > 20 then raise exception 'try again'; end if;
  end loop;
  insert into public.guest_codes (code, label, created_by, created_by_name, expires_at)
  values (c, left(nullif(trim(p_label), ''), 40), auth.uid(),
          (select name from public.members where user_id = auth.uid()), p_expires);
  return c;
end $$;
grant execute on function public.create_guest_code(text, timestamptz) to authenticated;

-- owners: list every owner's guest codes, who made each one, and the guests on it
create or replace function public.list_guest_codes()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  return coalesce((select json_agg(row_to_json(x) order by x.created_at desc) from (
    select g.code, g.label, coalesce((select name from public.members o where o.user_id = g.created_by), g.created_by_name) as created_by_name,
      g.created_by = auth.uid() as mine, g.expires_at, g.revoked, g.created_at,
      (select count(*) from public.members m where m.code = g.code) as people,
      coalesce((select json_agg(json_build_object('name', m.name, 'joined_at', m.joined_at) order by m.joined_at)
                from public.members m where m.code = g.code), '[]'::json) as guests
    from public.guest_codes g where g.created_at > now() - interval '120 days') x), '[]'::json);
end $$;
grant execute on function public.list_guest_codes() to authenticated;

-- owners: end a guest code now (everyone on it is logged out on their next check)
create or replace function public.revoke_guest_code(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  update public.guest_codes set revoked = true where code = upper(p_code);
  update public.members set expires_at = now() where code = upper(p_code) and role = 'guest';
end $$;
grant execute on function public.revoke_guest_code(text) to authenticated;

-- owners: change a code's end date
create or replace function public.extend_guest_code(p_code text, p_expires timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'owners only'; end if;
  update public.guest_codes set expires_at = p_expires, revoked = false where code = upper(p_code);
  update public.members set expires_at = p_expires where code = upper(p_code) and role = 'guest';
end $$;
grant execute on function public.extend_guest_code(text, timestamptz) to authenticated;
