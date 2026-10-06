-- Phase 6 tests: client portal (Front desk). THROWAWAY DB only. Runs after p5 (needs the bos schema).
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;

insert into auth.users (email) values ('own@p6.test'), ('mem@p6.test'), ('cli@p6.test'), ('out@p6.test'), ('nobody@p6.test');
select id as uo from auth.users where email = 'own@p6.test' \gset
select id as um from auth.users where email = 'mem@p6.test' \gset
select id as uc from auth.users where email = 'cli@p6.test' \gset
select id as ux from auth.users where email = 'out@p6.test' \gset
select id as un from auth.users where email = 'nobody@p6.test' \gset
select acq.create_organization('P6 Org', 'p6-org', 'own@p6.test') as o \gset
select acq.create_organization('P6 Other', 'p6-other', 'out@p6.test') as ox \gset
insert into acq.profiles (id, org_id, email, role) values (:'um', :'o', 'mem@p6.test', 'member');

-- a client with its own booking business
insert into bos.businesses (slug, name, industry, timezone, country_code, receptionist_name, test_mode, min_notice_min)
values ('p6-barbers', 'P6 Barbers', 'barbers', 'Europe/London', '44', 'Sophie', true, 0) returning id as bid \gset
insert into bos.business_hours (business_id, weekday, opens, closes)
select :'bid', d, '09:00', '18:00' from generate_series(1, 6) d;
insert into bos.resources (business_id, name, kind, sort_order) values (:'bid', 'Leo', 'staff', 1) returning id as r1 \gset
insert into bos.resources (business_id, name, kind, sort_order) values (:'bid', 'Marcus', 'staff', 2) returning id as r2 \gset
insert into bos.services (business_id, name, duration_min, price_text) values (:'bid', 'Skin fade', 45, 'from £28') returning id as s1 \gset
insert into bos.services (business_id, name, duration_min, price_text) values (:'bid', 'Beard trim', 20, '£15.50') returning id as s2 \gset
insert into bos.customers (business_id, name, phone) values (:'bid', 'Emma Jane Thompson', '+447700900111') returning id as c1 \gset
insert into bos.customers (business_id, name, phone) values (:'bid', null, '+447700900222') returning id as c2 \gset
insert into acq.clients (org_id, business_name, industry, status, bos_business_id) values (:'o', 'P6 Barbers', 'barbers', 'active', :'bid') returning id as cl \gset
insert into acq.clients (org_id, business_name, industry, status) values (:'o', 'P6 Not Yet', 'salon', 'onboarding') returning id as cl2 \gset

-- next Tuesday and the Sunday before it, in London time
select to_char(d, 'YYYY-MM-DD') as tue from (select (now() at time zone 'Europe/London')::date + g d from generate_series(2, 9) g) x where extract(dow from d) = 2 limit 1 \gset
select to_char(:'tue'::date - 2, 'YYYY-MM-DD') as sun \gset

-- two past bookings (revenue) and three upcoming ones, plus calls and texts
insert into bos.bookings (business_id, customer_id, service_id, resource_id, ref, starts_at, ends_at, block_end, status, source, created_at)
values (:'bid', :'c1', :'s1', :'r1', 'PAST01', now() - interval '3 days', now() - interval '3 days' + interval '45 minutes', now() - interval '3 days' + interval '45 minutes', 'completed', 'voice', now() - interval '5 days'),
       (:'bid', :'c2', :'s2', :'r2', 'PAST02', now() - interval '2 days', now() - interval '2 days' + interval '20 minutes', now() - interval '2 days' + interval '20 minutes', 'booked', 'sms', now() - interval '4 days'),
       (:'bid', :'c2', :'s2', :'r2', 'CANC01', now() - interval '1 day', now() - interval '1 day' + interval '20 minutes', now() - interval '1 day' + interval '20 minutes', 'cancelled', 'voice', now() - interval '4 days');
select bos.dispatch('p6-barbers', 'book', jsonb_build_object('customer_name', 'Emma Jane Thompson', 'phone', '+447700900111', 'service', 'Skin fade', 'date', :'tue', 'time', '10:00'), 'p6-1', 'voice')->>'ok' as b1 \gset
select bos.dispatch('p6-barbers', 'book', jsonb_build_object('customer_name', 'Tom Hardy', 'phone', '+447700900333', 'service', 'Beard trim', 'date', :'tue', 'time', '10:00'), 'p6-2', 'website')->>'ok' as b2 \gset
select bos.dispatch('p6-barbers', 'book', jsonb_build_object('customer_name', 'Ali Khan', 'phone', '+447700900444', 'service', 'Beard trim', 'date', :'tue', 'time', '15:30'), 'p6-3', 'sms')->>'ok' as b3 \gset
select t.check(:'b1' = 'true' and :'b2' = 'true' and :'b3' = 'true', '601 fixture bookings created through the real booking engine');
insert into bos.calls (business_id, customer_id, provider_call_id, call_type, customer_phone, started_at, duration_s, summary, ended_reason)
values (:'bid', :'c1', 'p6-call-1', 'inboundPhoneCall', '+447700900111', now() - interval '2 hours', 95, 'Booked a skin fade for Tuesday.', 'customer-ended-call'),
       (:'bid', null, 'p6-call-2', 'webCall', null, now() - interval '1 hour', 40, 'Asked about parking.', 'customer-ended-call');
insert into bos.messages (business_id, customer_id, direction, from_addr, to_addr, body, purpose)
values (:'bid', :'c1', 'in', '+447700900111', '+447700900001', 'C', null);

-- ---------- access ----------
set role authenticated;
select t.as_user(:'uo');
select t.check((acq.portal_clients()->'clients'->0->>'id') = :'cl' and jsonb_array_length(acq.portal_clients()->'clients') = 1, '602 owner sees only provisioned clients');
select t.check((acq.portal_clients()->'clients'->0->>'role') = 'organisation', '603 owner opens clients as the organisation');
select t.as_user(:'uc');
select t.check(jsonb_array_length(acq.portal_clients()->'clients') = 0, '604 client user sees nothing before being added');
select t.check(t.err(format('select acq.portal_overview(%L)', :'cl')) = '42501', '605 client user refused before being added');
select t.as_user(:'um');
select t.check(t.err(format('select acq.add_client_user(%L, %L)', :'cl', 'cli@p6.test')) = '42501', '606 a member (not admin) cannot add client users');
select t.as_user(:'uo');
select t.check((acq.add_client_user(:'cl', 'CLI@p6.test')->>'ok') = 'true', '607 owner adds the client''s own user (email case-insensitive)');
select t.check(t.err(format('select acq.add_client_user(%L, %L)', :'cl', 'ghost@p6.test')) = 'P0001', '608 unknown email is refused');
select t.as_user(:'uc');
select t.check((acq.portal_clients()->'clients'->0->>'role') = 'owner', '609 client user now sees their business');
select t.as_user(:'ux');
select t.check(t.err(format('select acq.portal_day(%L)', :'cl')) = '42501', '610 another organisation is refused');
select t.as_user(:'un');
select t.check(t.err(format('select acq.portal_upcoming(%L)', :'cl')) = '42501', '611 a signed-in stranger is refused');
select t.as_user(null);
select t.check(t.err(format('select acq.portal_activity(%L)', :'cl')) = '42501', '612 no session is refused');
select t.as_user(:'uo');
select t.check(t.err(format('select acq.portal_day(%L)', :'cl2')) = 'P0001', '613 client without a booking system gets a clear message');
reset role;
set role anon;
select t.check(t.err(format('select acq.portal_clients()')) = '42501', '614 anon cannot call the portal');
reset role;

-- ---------- data ----------
set role authenticated;
select t.as_user(:'uc');
select acq.portal_overview(:'cl', 30) as ov \gset
select t.check((:'ov'::jsonb #>> '{kpis,bookings}')::int = 5, '615 bookings in period exclude cancelled', :'ov');
select t.check((:'ov'::jsonb #>> '{kpis,by_ai}')::int = 4, '616 bookings made by the AI (phone, web voice, text)', :'ov');
select t.check((:'ov'::jsonb #>> '{kpis,revenue}')::numeric = 43.50, '617 revenue = past non-cancelled bookings (28 + 15.50)', :'ov');
select t.check((:'ov'::jsonb #>> '{kpis,calls}')::int = 2 and (:'ov'::jsonb #>> '{kpis,upcoming}')::int = 3, '618 calls and upcoming counted', :'ov');
select t.check(jsonb_array_length(:'ov'::jsonb -> 'daily') = 30 and jsonb_array_length(:'ov'::jsonb -> 'monthly') = 6, '619 daily series covers the period, monthly covers six months');
select t.check((select sum((m->>'phone')::numeric + (m->>'text')::numeric) from jsonb_array_elements(:'ov'::jsonb -> 'monthly') m) = 43.50, '620 monthly revenue split by channel adds up');
select t.check(:'ov'::jsonb #>> '{business,name}' = 'P6 Barbers', '621 business details returned');

select acq.portal_day(:'cl', :'tue') as dy \gset
select t.check(jsonb_array_length(:'dy'::jsonb -> 'staff') = 2 and jsonb_array_length(:'dy'::jsonb -> 'bookings') = 3, '622 day view: staff columns and bookings', :'dy');
select t.check(:'dy'::jsonb ->> 'opens' = '09:00' and :'dy'::jsonb ->> 'closes' = '18:00' and (:'dy'::jsonb ->> 'closed')::boolean = false, '623 day view: opening hours');
select t.check((select count(*) from jsonb_array_elements(:'dy'::jsonb -> 'bookings') b where b->>'customer' = 'Emma T.') = 1, '624 customer shown as first name + initial', :'dy');
select t.check((select count(distinct b->>'staff_id') from jsonb_array_elements(:'dy'::jsonb -> 'bookings') b) = 2, '625 two bookings at 10:00 went to different staff');
select t.check((acq.portal_day(:'cl', :'sun')->>'closed')::boolean, '626 closed day is flagged');
select acq.portal_day(:'cl', ((now() - interval '1 day') at time zone 'Europe/London')::date) as d2 \gset
select t.check(not exists (select 1 from jsonb_array_elements(:'d2'::jsonb -> 'bookings') b where b->>'status' = 'cancelled'), '627 cancelled bookings are left out of the diary');

select acq.portal_upcoming(:'cl', null, 14) as up \gset
select t.check(jsonb_array_length(:'up'::jsonb -> 'bookings') = 3, '628 upcoming lists future bookings only', :'up');
select t.check((:'up'::jsonb #>> '{bookings,0,starts_at}')::timestamptz <= (:'up'::jsonb #>> '{bookings,2,starts_at}')::timestamptz, '629 upcoming sorted by time');
select t.check((select count(*) from jsonb_array_elements(:'up'::jsonb -> 'bookings') b where b->>'channel' = 'web') = 1, '630 channel mapped from source');

select acq.portal_activity(:'cl', 10) as act \gset
select t.check(jsonb_array_length(:'act'::jsonb -> 'calls') = 2 and jsonb_array_length(:'act'::jsonb -> 'texts') = 1, '631 activity: calls and texts', :'act');
select t.check(:'act'::jsonb #>> '{calls,0,channel}' = 'web' and :'act'::jsonb #>> '{calls,1,customer}' = 'Emma T.', '632 newest call first, labelled');
select t.check(position('+44' in :'act') = 0, '633 no full phone numbers leave the portal');

-- client users see nothing of the organisation's sales data
select t.check((select count(*) from acq.leads) = 0 and (select count(*) from acq.clients) = 0, '634 client user cannot read the organisation''s leads or clients');
select t.check((select count(*) from acq.client_users) = 1, '635 client user sees only their own membership');

-- switching access off
select t.as_user(:'uo');
select t.check((acq.set_client_user_active(:'cl', 'cli@p6.test', false)->>'active') = 'false', '636 owner switches a client user off');
select t.as_user(:'uc');
select t.check(t.err(format('select acq.portal_overview(%L)', :'cl')) = '42501', '637 switched-off user is refused');
reset role;

select t.check(acq.price_value('from £28') = 28 and acq.price_value('£1,250.00') = 1250 and acq.price_value('free') = 0 and acq.price_value(null) = 0, '638 price parsing');
select t.check(acq.portal_customer('Cher', null) = 'Cher' and acq.portal_customer('  ', '+447700900999') = '•••• 0999', '639 customer labels for single names and unknown names');

\echo ALL_TESTS_PASSED_P6
