-- Khaya Ndlovu map: PUSH THE UPDATE TO EVERYONE (version 119)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run as many times as you like.
-- It installs the update + version tracking, requires version 119, and posts an "please update" news message
-- that only people on an old version can see. At the bottom you get a check table: every line should say YES.

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

-- the "please update" news always comes from the database itself, never from a person
alter table public.announcements alter column user_id drop not null;
create or replace function public.kn_update_news(b int)
returns void language plpgsql security definer set search_path = public as $$
declare cid text := 'upd-' || b || '-' || left(md5(random()::text || clock_timestamp()::text), 12);
begin
  if coalesce(b, 0) = 0 then return; end if;
  update public.announcements set removed = true where for_old_build is not null and not removed;
  insert into public.announcements (client_id, body, expires_at, for_old_build)
  values (cid,
    'A new version of the map is out and your phone still has the old one, so you may miss sightings and alerts. ' ||
    'Tap Reinstall now below. Your settings, places and the map you were on come with you. Open the link, delete the old map icon, ' ||
    'then add the map to your Home Screen again. You are signed in straight away.',
    now() + interval '14 days', b);
  update public.announcements set user_id = null, name = 'Khaya Ndlovu database' where client_id = cid;
end $$;
revoke all on function public.kn_update_news(int) from public, anon, authenticated;

create or replace function public.announce_update()
returns int language plpgsql security definer set search_path = public, private as $$
declare b int; n int;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  select min_build into b from private.config limit 1;
  if coalesce(b, 0) = 0 then return 0; end if;
  perform public.kn_update_news(b);
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

-- push it now: require version 119 and post the news. It is sent by the database, not by any person.
update private.config set min_build = 119;
select public.kn_update_news(119);

notify pgrst, 'reload schema';

-- check: every line should say YES
select 'Update functions installed' as "check", case when count(*) = 6 then 'YES' else 'NO (' || count(*) || ' of 6)' end as result
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('app_min_build','report_build','member_versions','announce_update','set_min_build','is_admin')
union all select 'Everyone must be on version 119', case when (select min_build from private.config limit 1) = 119 then 'YES' else 'NO' end
union all select 'Update news posted (only old versions see it)', case when exists (select 1 from public.announcements where for_old_build = 119 and not removed) then 'YES' else 'NO' end
union all select 'People who still need to update', (select count(*)::text from public.members where coalesce(app_build, 0) < 119 and (role <> 'guest' or expires_at > now()));
