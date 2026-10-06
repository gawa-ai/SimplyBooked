-- =====================================================================
-- ACQ 027 — "Find leads" screen: every organisation gets a map search source
--   * adds the OpenStreetMap search source (key 'osm', provider osm_overpass) to every organisation
--     that doesn't have one yet, and to every organisation created from now on
--   * an existing 'osm' source is never changed (an admin may have paused it on purpose)
-- Requires 020. Safe to re-run. No destructive statements.
-- =====================================================================

insert into acq.lead_sources (org_id, key, name, provider)
select o.id, 'osm', 'OpenStreetMap', 'osm_overpass' from acq.organizations o
on conflict (org_id, key) do nothing;

create or replace function acq.tg_org_default_sources()
returns trigger language plpgsql set search_path = '' as $$
begin
  insert into acq.lead_sources (org_id, key, name, provider) values (new.id, 'osm', 'OpenStreetMap', 'osm_overpass')
  on conflict (org_id, key) do nothing;
  return null;
end $$;

create or replace trigger tg_org_default_sources after insert on acq.organizations
  for each row execute function acq.tg_org_default_sources();

revoke execute on function acq.tg_org_default_sources() from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function acq.tg_org_default_sources() from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke execute on function acq.tg_org_default_sources() from authenticated;
  end if;
end $$;
