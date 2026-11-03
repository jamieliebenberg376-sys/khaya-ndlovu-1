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
