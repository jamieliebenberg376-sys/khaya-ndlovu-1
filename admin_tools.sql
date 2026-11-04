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
