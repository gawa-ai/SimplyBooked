-- Phase 7 tests: Front desk hardening (026). THROWAWAY DB only. Runs after p6.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;
select id as uo from auth.users where email = 'own@p6.test' \gset
select id as uc from auth.users where email = 'cli@p6.test' \gset
select id as ox from acq.organizations where slug = 'p6-other' \gset
select id as o from acq.organizations where slug = 'p6-org' \gset
select id as cl from acq.clients where business_name = 'P6 Barbers' \gset
select bos_business_id as bid from acq.clients where id = :'cl' \gset
select to_char(d, 'YYYY-MM-DD') as tue from (select (now() at time zone 'Europe/London')::date + g d from generate_series(2, 9) g) x where extract(dow from d) = 2 limit 1 \gset

-- re-enable the client user switched off at the end of p6
update acq.client_users set active = true where client_id = :'cl';

select t.check(acq.portal_redact('Call me on 07700 900111 or +44 (0)161 496 0000, email emma.t@example.co.uk') = 'Call me on [phone] or [phone], email [email]', '701 phone numbers and emails are masked', acq.portal_redact('Call me on 07700 900111 or +44 (0)161 496 0000, email emma.t@example.co.uk'));
select t.check(acq.portal_redact('Booked for 2026-10-06 at 2:30pm, ref K7Q2MP') = 'Booked for 2026-10-06 at 2:30pm, ref K7Q2MP', '702 dates, times and references are left alone');
insert into bos.calls (business_id, provider_call_id, call_type, started_at, duration_s, summary)
values (:'bid', 'p7-call', 'inboundPhoneCall', now() - interval '5 minutes', 30, 'Asked us to ring back on 07700 900555.');
set role authenticated;
select t.as_user(:'uc');
select t.check(acq.portal_activity(:'cl', 1) #>> '{calls,0,summary}' = 'Asked us to ring back on [phone].', '703 call summaries reach owners masked');
select t.check((acq.portal_clients() #>> '{clients,0,timezone}') = 'Europe/London', '704 businesses come with their time zone');
reset role;

-- a member of staff deactivated after taking bookings still shows in that day's diary
update bos.resources set active = false where business_id = :'bid' and name = 'Marcus';
set role authenticated;
select t.as_user(:'uc');
select t.check(jsonb_array_length(acq.portal_day(:'cl', :'tue') -> 'staff') = 2, '705 deactivated staff with bookings keep their column');
select t.check(jsonb_array_length(acq.portal_day(:'cl', (:'tue'::date + 14)) -> 'staff') = 1, '706 and disappear from days without bookings');
reset role;
update bos.resources set active = true where business_id = :'bid' and name = 'Marcus';

-- churned client: its own users lose access, the organisation keeps it
update acq.clients set status = 'churned' where id = :'cl';
set role authenticated;
select t.as_user(:'uc');
select t.check(t.err(format('select acq.portal_overview(%L)', :'cl')) = '42501', '707 client user refused once the client has churned');
select t.check(jsonb_array_length(acq.portal_clients() -> 'clients') = 0, '708 and the business is no longer listed for them');
select t.as_user(:'uo');
select t.check((acq.portal_overview(:'cl') ->> 'ok') = 'true', '709 the organisation can still open a churned client');
reset role;
update acq.clients set status = 'active' where id = :'cl';

-- suspended organisation: client users lose access too
update acq.organizations set status = 'suspended' where id = :'o';
set role authenticated;
select t.as_user(:'uc');
select t.check(t.err(format('select acq.portal_day(%L)', :'cl')) = '42501', '710 client user refused while the organisation is suspended');
reset role;
update acq.organizations set status = 'active' where id = :'o';

-- integrity
select t.check(t.err(format('insert into acq.clients (org_id, business_name, bos_business_id) values (%L, %L, %L)', :'ox', 'Copycat', :'bid')) = '23505', '711 a booking business belongs to one client only');
select t.check(t.err(format('insert into acq.client_users (client_id, user_id, org_id) values (%L, %L, %L)', :'cl', :'uo', :'ox')) = '23503', '712 client_users.org_id must be the client''s own organisation');

set role authenticated;
select t.as_user(:'uc');
select t.check((acq.portal_upcoming(:'cl', null, 14) ->> 'truncated') = 'false', '713 upcoming says whether it was cut short');
reset role;

\echo ALL_TESTS_PASSED_P7
