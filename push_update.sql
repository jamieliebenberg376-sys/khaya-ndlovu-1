-- Khaya Ndlovu map: make EVERYONE update to the newest version (65).
-- Paste into Supabase > SQL Editor and press Run. Run backend.sql first if you haven't yet.
-- Everyone on an older version gets the "A big update is ready" screen the next time they open the map with signal.
update private.config set min_build = 65;
select min_build as "Everyone must now be on version" from private.config;
