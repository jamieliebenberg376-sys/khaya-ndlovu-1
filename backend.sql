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
            and (public.is_admin() or user_id = auth.uid() or not public.kn_hidden_animal(what))
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
    'A new version of the map is out and your phone still has the old one, so you may miss sightings and alerts. ' ||
    'Tap Reinstall now below. You get your own link with your name and access already in it: open it, delete the old map icon, ' ||
    'then add the map to your Home Screen again. You are signed in straight away and your old copy is removed.',
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
    from (select * from public.sightings_log where photo and created_at > now() - make_interval(days => least(greatest(p_days, 1), 30)) and (public.is_admin() or user_id = auth.uid() or not public.kn_hidden_animal(what)) order by created_at desc limit 300) l
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



-- ---------- STAY SIGNED IN: device keys and recovery codes ----------
-- Every phone keeps a secret device key. If its sign-in is ever lost (phone slept mid-refresh, storage hiccup),
-- it gets a fresh sign-in and the device key reconnects it to the exact same membership, silently.
-- Owners and admins can also make a personal recovery code that brings their account back on any phone.
alter table public.members add column if not exists dev_hash text;
alter table public.members add column if not exists rec_hash text;
create index if not exists members_dev_hash on public.members (dev_hash);
create index if not exists members_rec_hash on public.members (rec_hash);
create table if not exists public.recovery_tries (user_id uuid, at timestamptz not null default now());
alter table public.recovery_tries enable row level security;
revoke all on public.recovery_tries from anon, authenticated;

create or replace function public.kn_hash(t text) returns text language sql immutable as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')), 'hex') $$;

-- move a membership (and everything it owns) to the person calling, the same way a reinstall handover does
create or replace function public.kn_take_over(p_old uuid)
returns json language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare m public.members; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into m from public.members where user_id = p_old;
  if not found then return json_build_object('ok', false, 'reason', 'gone'); end if;
  if m.role = 'guest' and m.expires_at is not null and m.expires_at <= now() then return json_build_object('ok', false, 'reason', 'expired'); end if;
  if p_old = me then return json_build_object('ok', true, 'role', m.role, 'expires_at', m.expires_at, 'name', m.name, 'locked', m.locked); end if;
  perform set_config('kn.handover', '1', true);
  insert into public.members (user_id, name, role, code, expires_at, last_seen, invited_by, last_login, home_lat, home_lng, locked, dev_hash, rec_hash)
  values (me, m.name, m.role, m.code, m.expires_at, now(), m.invited_by, now(), m.home_lat, m.home_lng, m.locked, m.dev_hash, m.rec_hash)
  on conflict (user_id) do update set name = excluded.name, role = excluded.role, code = excluded.code, expires_at = excluded.expires_at,
    invited_by = excluded.invited_by, last_seen = now(), last_login = now(), home_lat = excluded.home_lat, home_lng = excluded.home_lng,
    locked = excluded.locked, dev_hash = excluded.dev_hash, rec_hash = excluded.rec_hash;
  begin update public.sightings set user_id = me where user_id = p_old; exception when others then null; end;
  begin update public.reports set user_id = me where user_id = p_old; exception when others then null; end;
  begin update public.drives set user_id = me where user_id = p_old; exception when others then null; end;
  begin update public.private_notes set user_id = me where user_id = p_old; exception when others then null; end;
  begin update public.direct_msgs set to_user = me where to_user = p_old; exception when others then null; end;
  begin delete from public.live_locs where user_id = p_old; exception when others then null; end;
  delete from public.members where user_id = p_old;
  perform set_config('kn.handover', '', true);
  return json_build_object('ok', true, 'role', m.role, 'expires_at', m.expires_at, 'name', m.name, 'locked', m.locked);
end $$;
revoke all on function public.kn_take_over(uuid) from public, anon, authenticated;

create or replace function public.set_device_key(p_key text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(coalesce(p_key, '')) < 24 then raise exception 'bad key'; end if;
  update public.members set dev_hash = public.kn_hash(p_key) where user_id = auth.uid();
end $$;
grant execute on function public.set_device_key(text) to authenticated;

create or replace function public.recover_device(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid; r json;
begin
  if auth.uid() is null or char_length(coalesce(p_key, '')) < 24 then return json_build_object('ok', false, 'reason', 'none'); end if;
  select user_id into o from public.members where dev_hash = public.kn_hash(p_key) order by last_seen desc nulls last limit 1;
  if o is null then return json_build_object('ok', false, 'reason', 'none'); end if;
  r := public.kn_take_over(o);
  if (r->>'ok')::boolean and o <> auth.uid() then perform public.kn_log('login', (r->>'name') || '''s phone reconnected by itself after losing its sign-in'); end if;
  return r;
end $$;
grant execute on function public.recover_device(text) to authenticated;

create or replace function public.make_recovery_code()
returns text language plpgsql security definer set search_path = public as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text := ''; i int;
begin
  if not exists (select 1 from public.members where user_id = auth.uid() and role in ('owner', 'admin')) then raise exception 'owners only'; end if;
  for i in 1..16 loop c := c || substr(a, 1 + floor(random() * 32)::int, 1); end loop;
  update public.members set rec_hash = public.kn_hash(c) where user_id = auth.uid();
  perform public.kn_log('code', 'made a new personal recovery code (the old one stops working)');
  return substr(c, 1, 4) || '-' || substr(c, 5, 4) || '-' || substr(c, 9, 4) || '-' || substr(c, 13, 4);
end $$;
grant execute on function public.make_recovery_code() to authenticated;

create or replace function public.has_recovery_code()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select rec_hash is not null from public.members where user_id = auth.uid()), false) $$;
grant execute on function public.has_recovery_code() to authenticated;

create or replace function public.use_recovery_code(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare o uuid; r json;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if (select count(*) from public.recovery_tries where user_id = auth.uid() and at > now() - interval '1 hour') >= 8 then
    return json_build_object('ok', false, 'reason', 'tries'); end if;
  select user_id into o from public.members where rec_hash = public.kn_hash(p_code) and rec_hash is not null limit 1;
  if o is null then insert into public.recovery_tries (user_id) values (auth.uid()); return json_build_object('ok', false, 'reason', 'wrong'); end if;
  r := public.kn_take_over(o);
  if (r->>'ok')::boolean then perform set_config('kn.handover', '1', true); update public.members set dev_hash = null where user_id = auth.uid(); perform set_config('kn.handover', '', true);
    perform public.kn_log('login', (r->>'name') || ' signed back in with their recovery code'); end if;
  return r;
end $$;
grant execute on function public.use_recovery_code(text) to authenticated;


-- ================= ADMIN POWER =================
alter table private.config add column if not exists paused boolean not null default false;
alter table private.config add column if not exists pause_msg text;
alter table private.config add column if not exists paused_by text;
alter table private.config add column if not exists paused_at timestamptz;
alter table private.config add column if not exists rules jsonb not null default '{}'::jsonb;
alter table private.config add column if not exists admin_only text[] not null default '{}';
alter table private.config add column if not exists guest_max_days int;
alter table private.config add column if not exists guest_max_per_owner int;
alter table private.config add column if not exists admin_sees_all boolean not null default false;
alter table public.removals add column if not exists snap jsonb;
alter table public.removals add column if not exists restored_at timestamptz;
alter table public.live_locs add column if not exists hidden boolean not null default false;

create or replace function public.kn_me_name() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select name from public.members where user_id = auth.uid()), 'An admin') $$;

-- everything the phones need to know about how the map is run right now
create or replace function public.map_state()
returns json language sql stable security definer set search_path = public, private as $$
  select case when public.is_member() then json_build_object('paused', c.paused, 'pause_msg', c.pause_msg, 'paused_by', c.paused_by, 'paused_at', c.paused_at,
    'rules', c.rules, 'admin_only', c.admin_only, 'guest_max_days', c.guest_max_days, 'guest_max_per_owner', c.guest_max_per_owner, 'admin_sees_all', c.admin_sees_all)
  else json_build_object('paused', false) end from private.config c limit 1 $$;
grant execute on function public.map_state() to authenticated;

-- 1. pause the map for everyone except admins (SOS keeps working)
create or replace function public.set_pause(p_on boolean, p_msg text default null)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set paused = p_on, pause_msg = case when p_on then left(nullif(btrim(coalesce(p_msg, '')), ''), 300) end,
    paused_by = case when p_on then public.kn_me_name() end, paused_at = case when p_on then now() end;
  perform public.kn_log('admin', case when p_on then 'paused the map for everyone' || coalesce(': ' || nullif(btrim(coalesce(p_msg, '')), ''), '') else 'turned the map back on for everyone' end);
end $$;
grant execute on function public.set_pause(boolean, text) to authenticated;

-- 9. reserve rules (speed limit, quiet hours, sunset reminder) for every phone
create or replace function public.set_rules(p_rules jsonb)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set rules = coalesce(p_rules, '{}'::jsonb);
  perform public.kn_log('admin', 'changed the reserve rules');
end $$;
grant execute on function public.set_rules(jsonb) to authenticated;

-- 10. animals only admins (and whoever marked them) can see
create or replace function public.kn_hidden_animal(p_what text) returns boolean language sql stable security definer set search_path = public, private as $$
  select coalesce(p_what = any(coalesce((select admin_only from private.config limit 1), '{}'::text[])), false) $$;
create or replace function public.set_admin_only(p_animals text[])
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set admin_only = coalesce(p_animals, '{}');
  perform public.kn_log('admin', case when coalesce(array_length(p_animals, 1), 0) = 0 then 'made all animals visible to everyone' else 'made ' || array_to_string(p_animals, ', ') || ' sightings admin only' end);
end $$;
grant execute on function public.set_admin_only(text[]) to authenticated;
drop policy if exists s_read on public.sightings;
create policy s_read on public.sightings for select to authenticated
  using (public.is_member() and (user_id = auth.uid() or public.is_admin() or not public.kn_hidden_animal(what)));

-- 5. guest limits for owners (admins are not limited)
create or replace function public.set_guest_limits(p_days int, p_max int)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set guest_max_days = nullif(p_days, 0), guest_max_per_owner = nullif(p_max, 0);
  perform public.kn_log('admin', 'set guest limits: ' || coalesce(p_days::text || ' days max', 'no day limit') || ', ' || coalesce(p_max::text || ' guests per owner', 'no guest limit'));
end $$;
grant execute on function public.set_guest_limits(int, int) to authenticated;
create or replace function public.kn_trg_guest_limits() returns trigger language plpgsql security definer set search_path = public, private as $$
declare d int; mx int; n int;
begin
  if new.kind is distinct from 'guest' or public.is_admin() then return new; end if;
  select guest_max_days, guest_max_per_owner into d, mx from private.config limit 1;
  if d is not null and new.expires_at > now() + make_interval(days => d) + interval '1 hour' then
    raise exception 'Guest passes can last at most % days', d; end if;
  if mx is not null then
    select count(*) into n from public.guest_codes where created_by = new.created_by and kind = 'guest' and not revoked and expires_at > now();
    if n >= mx then raise exception 'You can have at most % guests at a time', mx; end if;
  end if;
  return new;
end $$;
drop trigger if exists kn_guest_limits on public.guest_codes;
create trigger kn_guest_limits before insert on public.guest_codes for each row execute function public.kn_trg_guest_limits();

-- 6. admins see every car (even with sharing off) when this is on; everyone is told in Settings
create or replace function public.set_admin_sees_all(p_on boolean)
returns void language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  update private.config set admin_sees_all = p_on;
  perform public.kn_log('admin', case when p_on then 'turned on: admins can see every car on the reserve' else 'turned off: admins only see cars that share' end);
end $$;
grant execute on function public.set_admin_sees_all(boolean) to authenticated;
drop policy if exists ll_read on public.live_locs;
create policy ll_read on public.live_locs for select to authenticated using (public.is_member() and (not hidden or public.is_admin()));

-- 2. private message to one person
create table if not exists public.direct_msgs (id bigserial primary key, to_user uuid not null, from_name text, body text not null check (char_length(body) between 1 and 600), created_at timestamptz not null default now(), read_at timestamptz);
create index if not exists direct_msgs_to on public.direct_msgs (to_user, created_at desc);
alter table public.direct_msgs enable row level security;
revoke all on public.direct_msgs from anon, authenticated;
create or replace function public.send_direct(p_user uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  select name into nm from public.members where user_id = p_user;
  if nm is null then raise exception 'That person is not on the map'; end if;
  insert into public.direct_msgs (to_user, from_name, body) values (p_user, public.kn_me_name(), left(btrim(p_body), 600));
  perform public.kn_log('admin', 'sent a private message to ' || nm);
end $$;
grant execute on function public.send_direct(uuid, text) to authenticated;
create or replace function public.my_direct()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', id, 'from', from_name, 'body', body, 'at', created_at) order by created_at), '[]'::json)
  from public.direct_msgs where to_user = auth.uid() and read_at is null and created_at > now() - interval '30 days' $$;
grant execute on function public.my_direct() to authenticated;
create or replace function public.read_direct(p_id bigint)
returns void language sql security definer set search_path = public as $$
  update public.direct_msgs set read_at = now() where id = p_id and to_user = auth.uid() $$;
grant execute on function public.read_direct(bigint) to authenticated;

-- 4. ban a phone: it can never join again, even with a new code
create table if not exists public.bans (dev_hash text primary key, name text, by_name text, at timestamptz not null default now());
alter table public.bans enable row level security;
revoke all on public.bans from anon, authenticated;
create or replace function public.ban_member(p_user uuid)
returns json language plpgsql security definer set search_path = public as $$
declare m public.members;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  select * into m from public.members where user_id = p_user;
  if not found then raise exception 'That person is not on the map'; end if;
  if m.locked then raise exception 'This account is protected and cannot be removed'; end if;
  if m.dev_hash is not null then insert into public.bans (dev_hash, name, by_name) values (m.dev_hash, m.name, public.kn_me_name()) on conflict (dev_hash) do nothing; end if;
  perform public.remove_member(p_user);
  update public.removals set kind = 'banned' where user_id = p_user and at > now() - interval '1 minute';
  perform public.kn_log('remove', 'banned ' || m.name || ' from the map' || case when m.dev_hash is null then ' (their phone had not checked in yet, so only removed)' else '' end);
  return json_build_object('ok', true, 'phone', m.dev_hash is not null);
end $$;
grant execute on function public.ban_member(uuid) to authenticated;
create or replace function public.list_bans()
returns json language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then coalesce((select json_agg(json_build_object('h', dev_hash, 'name', name, 'by', by_name, 'at', at) order by at desc) from public.bans), '[]'::json) else '[]'::json end $$;
grant execute on function public.list_bans() to authenticated;
create or replace function public.unban(p_hash text)
returns void language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  delete from public.bans where dev_hash = p_hash returning name into nm;
  perform public.kn_log('admin', 'lifted the ban on ' || coalesce(nm, 'a phone'));
end $$;
grant execute on function public.unban(text) to authenticated;
-- a banned phone that joins with a fresh code is taken off again the moment it checks in
create or replace function public.set_device_key(p_key text)
returns void language plpgsql security definer set search_path = public as $$
declare h text := public.kn_hash(p_key);
begin
  if char_length(coalesce(p_key, '')) < 24 then raise exception 'bad key'; end if;
  if exists (select 1 from public.bans where dev_hash = h) then
    insert into public.removals (user_id, name, by_name, kind) select user_id, name, (select by_name from public.bans where dev_hash = h), 'banned' from public.members where user_id = auth.uid() and not locked;
    delete from public.members where user_id = auth.uid() and not locked;
    return;
  end if;
  update public.members set dev_hash = h where user_id = auth.uid();
end $$;

-- 8. undo a removal within 7 days: everything they had comes back
create or replace function public.list_removed()
returns json language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then coalesce((select json_agg(json_build_object('u', user_id, 'name', name, 'by', by_name, 'at', at, 'kind', kind, 'role', snap->>'role') order by at desc)
    from (select distinct on (user_id) * from public.removals where snap is not null and restored_at is null and at > now() - interval '7 days' and kind in ('removed', 'banned') order by user_id, at desc) r
    where not exists (select 1 from public.members m where m.user_id = r.user_id)), '[]'::json) else '[]'::json end $$;
grant execute on function public.list_removed() to authenticated;
create or replace function public.restore_member(p_user uuid)
returns json language plpgsql security definer set search_path = public as $$
declare r public.removals;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  select * into r from public.removals where user_id = p_user and snap is not null and restored_at is null and at > now() - interval '7 days' order by at desc limit 1;
  if not found then raise exception 'Nothing to undo for that person'; end if;
  insert into public.members select * from jsonb_populate_record(null::public.members, r.snap) on conflict (user_id) do nothing;
  if r.snap->>'dev_hash' is not null then delete from public.bans where dev_hash = r.snap->>'dev_hash'; end if;
  update public.removals set restored_at = now() where user_id = p_user and restored_at is null;
  perform public.kn_log('admin', 'brought ' || r.name || ' back onto the map');
  return json_build_object('ok', true, 'name', r.name);
end $$;
grant execute on function public.restore_member(uuid) to authenticated;
-- keep a copy of the membership when someone is removed, so it can be undone
create or replace function public.kn_trg_removal_snap() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('kn.handover', true), '') = '1' then return old; end if;
  update public.removals set snap = to_jsonb(old) where user_id = old.user_id and snap is null and at > now() - interval '1 minute';
  return old;
end $$;
drop trigger if exists kn_removal_snap on public.members;
create trigger kn_removal_snap after delete on public.members for each row execute function public.kn_trg_removal_snap();

-- 7. weekly report for admins
create or replace function public.weekly_report()
returns json language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - interval '7 days';
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  return json_build_object(
    'since', since,
    'joined', (select coalesce(json_agg(json_build_object('name', name, 'role', role) order by joined_at desc), '[]'::json) from public.members where joined_at > since),
    'removed', (select count(*) from public.removals where at > since and kind in ('removed', 'banned')),
    'sightings', (select count(*) from public.sightings_log where created_at > since),
    'kills', (select count(*) from public.sightings_log where created_at > since and coalesce(kill, false)),
    'top', (select coalesce(json_agg(json_build_object('what', what, 'n', n)), '[]'::json) from (select what, count(*) n from public.sightings_log where created_at > since group by what order by n desc limit 6) t),
    'reports', (select count(*) from public.reports where created_at > since),
    'drives', (select count(*) from public.drives where created_at > since),
    'owners', (select count(*) from public.members where role in ('owner', 'admin')),
    'guests', (select count(*) from public.members where role = 'guest' and expires_at > now()),
    'active', (select count(*) from public.members where last_seen > since),
    'quiet', (select coalesce(json_agg(name), '[]'::json) from public.members where role <> 'guest' and not locked and (last_seen is null or last_seen < since)),
    'old', (select count(*) from public.members m where not m.locked and coalesce(m.app_build, 0) < (select min_build from private.config limit 1)),
    'sos', (select count(*) from public.activity_log where kind = 'sos' and at > since));
end $$;
grant execute on function public.weekly_report() to authenticated;

-- ---------- SUGGESTIONS: anyone on the map can send one, only the protected account can read them ----------
create table if not exists public.suggestions (
  id bigserial primary key,
  user_id uuid default auth.uid(),
  name text, role text,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
alter table public.suggestions enable row level security;
-- no table policies on purpose: nobody reads or writes it directly, only through the functions below
revoke all on public.suggestions from anon, authenticated;

create or replace function public.send_suggestion(p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare m public.members; b text := btrim(coalesce(p_body, ''));
begin
  select * into m from public.members where user_id = auth.uid();
  if not found then raise exception 'members only'; end if;
  if m.role = 'guest' and m.expires_at is not null and m.expires_at <= now() then raise exception 'members only'; end if;
  if char_length(b) < 2 then raise exception 'Write a bit more first'; end if;
  if (select count(*) from public.suggestions where user_id = auth.uid() and created_at > now() - interval '1 day') >= 10 then
    raise exception 'That is 10 suggestions today already, try again tomorrow'; end if;
  insert into public.suggestions (user_id, name, role, body) values (auth.uid(), m.name, m.role, left(b, 1000));
  return json_build_object('ok', true);
end $$;
grant execute on function public.send_suggestion(text) to authenticated;

create or replace function public.list_suggestions()
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where user_id = auth.uid() and locked) then return '[]'::json; end if;
  return coalesce((select json_agg(row_to_json(x) order by x.created_at desc) from (
    select id, name, role, body, created_at, read_at is not null as read from public.suggestions
    order by created_at desc limit 200) x), '[]'::json);
end $$;
grant execute on function public.list_suggestions() to authenticated;

create or replace function public.read_suggestions(p_ids bigint[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where user_id = auth.uid() and locked) then return; end if;
  update public.suggestions set read_at = now() where read_at is null and (p_ids is null or id = any(p_ids));
end $$;
grant execute on function public.read_suggestions(bigint[]) to authenticated;

create or replace function public.delete_suggestion(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where user_id = auth.uid() and locked) then raise exception 'not allowed'; end if;
  delete from public.suggestions where id = p_id;
end $$;
grant execute on function public.delete_suggestion(bigint) to authenticated;

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
  begin insert into public.removals (user_id, name, by_name, kind, at) select user_id, name, 'System', 'expired', expires_at from public.members where role = 'guest' and expires_at < now() - interval '3 days' and not locked;
  delete from public.members where role = 'guest' and expires_at < now() - interval '3 days'; get diagnostics n = row_count; out := out || jsonb_build_object('guests', n); exception when others then null; end;
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
select * from public.kn_backend_selftest();
