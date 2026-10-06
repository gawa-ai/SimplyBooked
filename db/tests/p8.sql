-- Phase 8 tests: map search source for "Find leads" (027). THROWAWAY DB only. Runs after p7.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;
select id as uo from auth.users where email = 'own@p6.test' \gset
select id as um from auth.users where email = 'mem@p6.test' \gset
select id as uc from auth.users where email = 'cli@p6.test' \gset
select id as o from acq.organizations where slug = 'p6-org' \gset
select id as ox from acq.organizations where slug = 'p6-other' \gset

select t.check(not exists (select 1 from acq.organizations o where not exists (
  select 1 from acq.lead_sources s where s.org_id = o.id and s.key = 'osm' and s.provider = 'osm_overpass' and s.active)),
  '801 every existing organisation has an active map search source');

-- a new organisation gets one too, next to manual and csv
select acq.create_organization('P8 New', 'p8-new', null) as on8 \gset
select t.check((select string_agg(key, ',' order by key) from acq.lead_sources where org_id = :'on8') = 'csv,manual,osm',
  '802 new organisations start with manual, csv and map search');

-- an admin's choice to pause the source survives a re-run of the migration
update acq.lead_sources set active = false, daily_limit = 50 where org_id = :'o' and key = 'osm';
\ir ../027_acq_lead_search_source.sql
select t.check((select not active and daily_limit = 50 from acq.lead_sources where org_id = :'o' and key = 'osm'),
  '803 re-running 027 never overwrites an existing source');
update acq.lead_sources set active = true, daily_limit = 200 where org_id = :'o' and key = 'osm';

-- a member can now queue a search with the source the screen uses
set role authenticated;
select t.as_user(:'um');
select acq.queue_search_run('osm', 'Dentists', 'Bristol', null, 'gb', 20) as q1 \gset
select t.check((:'q1'::jsonb ->> 'ok') = 'true', '804 member queues a map search', :'q1'::jsonb);
select t.check((select status || ':' || country_code || ':' || max_results from acq.lead_search_runs where id = (:'q1'::jsonb ->> 'run_id')::uuid) = 'queued:GB:20',
  '805 the run is queued with the country upper-cased');
select t.check((acq.queue_search_run('osm', 'dentists', 'bristol', null, 'GB', 20) ->> 'duplicate') = 'true',
  '806 the same search while one is waiting is not queued twice');
select t.check(t.err($$select acq.queue_search_run('csv', 'Dentists', 'Bristol', null, 'GB', 20)$$) = 'P0001', '807 import sources cannot be searched');

-- the screen lists runs of its own organisation only
select t.check((select count(*) from acq.lead_search_runs) = 1, '808 member sees their organisation''s runs');
select t.as_user(:'uc');
select t.check((select count(*) from acq.lead_search_runs) = 0 and (select count(*) from acq.lead_sources) = 0,
  '809 a business owner (client user) sees no searches or sources');
select t.check(t.err($$select acq.queue_search_run('osm', 'Dentists', 'Bristol', null, 'GB', 20)$$) <> 'ok', '810 and cannot queue one');
reset role;
update acq.lead_search_runs set status = 'cancelled' where org_id = :'o';

\echo ALL_TESTS_PASSED_P8
