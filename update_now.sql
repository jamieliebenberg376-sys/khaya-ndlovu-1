-- Khaya Ndlovu map: PUSH THE UPDATE TO EVERYONE (version 101)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run as many times as you like.
-- It installs the update + version tracking, requires version 101, and posts an "please update" news message
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
    'A new version of the map is out and your phone still has the old one, so you may miss sightings and alerts. ' ||
    'Tap Reinstall now below. You get your own link with your name and access already in it: open it, delete the old map icon, ' ||
    'then add the map to your Home Screen again. You are signed in straight away and your old copy is removed.',
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

-- push it now: require version 101 and post the news (as the first admin, so it shows who sent it)
update private.config set min_build = 102;
do $$
declare adm uuid := (select user_id from public.members where role = 'admin' order by joined_at limit 1);
begin
  if adm is null then raise notice 'No admin found, news not posted'; return; end if;
  perform set_config('request.jwt.claim.sub', adm::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm)::text, true);
  perform public.announce_update();
end $$;

notify pgrst, 'reload schema';

-- check: every line should say YES
select 'Update functions installed' as "check", case when count(*) = 6 then 'YES' else 'NO (' || count(*) || ' of 6)' end as result
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('app_min_build','report_build','member_versions','announce_update','set_min_build','is_admin')
union all select 'Everyone must be on version 101', case when (select min_build from private.config limit 1) = 101 then 'YES' else 'NO' end
union all select 'Update news posted (only old versions see it)', case when exists (select 1 from public.announcements where for_old_build = 102 and not removed) then 'YES' else 'NO' end
union all select 'People who still need to update', (select count(*)::text from public.members where coalesce(app_build, 0) < 101 and (role <> 'guest' or expires_at > now()));
