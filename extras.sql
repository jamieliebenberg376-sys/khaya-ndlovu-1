-- Khaya Ndlovu map: sighting photos + "Still here"
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.

alter table public.sightings add column if not exists photo boolean not null default false;
alter table public.sightings add column if not exists still boolean not null default false;

-- private photo storage, members only
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sightings', 'sightings', false, 3145728, array['image/jpeg'])
on conflict (id) do nothing;

drop policy if exists kn_photo_read on storage.objects;
drop policy if exists kn_photo_add  on storage.objects;
drop policy if exists kn_photo_upd  on storage.objects;
create policy kn_photo_read on storage.objects for select to authenticated using (bucket_id = 'sightings' and public.is_member());
create policy kn_photo_add  on storage.objects for insert to authenticated with check (bucket_id = 'sightings' and public.is_member());
create policy kn_photo_upd  on storage.objects for update to authenticated using (bucket_id = 'sightings' and owner = auth.uid()) with check (bucket_id = 'sightings' and public.is_member());
