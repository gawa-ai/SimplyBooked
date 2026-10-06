-- Phase 1 tests: schema, constraints, RLS, audit. THROWAWAY DB only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

insert into auth.users (email) values ('a@org1.test'), ('v@org1.test'), ('m@org1.test'), ('b@org2.test'), ('free@x.test');
select id as ua from auth.users where email = 'a@org1.test' \gset
select id as uv from auth.users where email = 'v@org1.test' \gset
select id as um from auth.users where email = 'm@org1.test' \gset
select id as ub from auth.users where email = 'b@org2.test' \gset
select id as uf from auth.users where email = 'free@x.test' \gset
select acq.create_organization('Org One', 'org-one', 'a@org1.test') as o1 \gset
select acq.create_organization('Org Two', 'org-two', 'b@org2.test') as o2 \gset

-- 01 tables
select t.check((select count(*) from pg_tables where schemaname = 'acq'
  and tablename in ('organizations','profiles','leads','lead_sources','lead_qualification','pipeline_events','outreach_campaigns',
                    'outreach_messages','replies','demos','meetings','followups','clients','onboarding_tasks','activity_logs','system_settings')) = 16,
  '01 all 16 required tables exist');
select t.check((select count(*) from pg_tables where schemaname = 'acq' and not rowsecurity) = 0, '02 RLS enabled on every acq table');
select t.check((select count(*) from acq.system_settings where org_id = :'o1') >= 12, '03 org settings seeded');
select t.check((select count(*) from acq.lead_sources where org_id = :'o1') = 2, '04 default lead sources created');
select t.check(not (select outreach_enabled from acq.organizations where id = :'o1'), '05 outreach disabled by default');
select t.check((select sms from (select (value->>'sms')::int as sms from acq.system_settings where org_id = :'o1' and key = 'daily_send_limit') x) = 0
               and (select value from acq.system_settings where org_id = :'o1' and key = 'sms_outreach_enabled') = 'false'::jsonb,
  '06 SMS outreach off by default');

-- seed membership + data (as superuser)
insert into acq.profiles (id, org_id, email, role) values (:'uv', :'o1', 'v@org1.test', 'viewer'), (:'um', :'o1', 'm@org1.test', 'member');
select id as src1 from acq.lead_sources where org_id = :'o1' and key = 'manual' \gset
select id as src2 from acq.lead_sources where org_id = :'o2' and key = 'manual' \gset
insert into acq.leads (org_id, source_id, business_name, website, phone, email, country_code, niche, city)
values (:'o1', :'src1', 'Smile Dental', 'https://www.Smile-Dental.com/contact?x=1', '07700 900123', ' Info@Smile-Dental.COM ', 'GB', 'dentist', 'London'),
       (:'o1', :'src1', 'Facebook Only Salon', 'https://facebook.com/facebookonlysalon', null, null, 'GB', 'salon', 'Leeds'),
       (:'o2', :'src2', 'Other Org Clinic', 'https://other-clinic.com', null, null, 'GB', 'clinic', 'Bath');

-- 07 normalisation
select t.check((select domain from acq.leads where business_name = 'Smile Dental') = 'smile-dental.com', '07a domain normalised');
select t.check((select phone_e164 from acq.leads where business_name = 'Smile Dental') = '+447700900123', '07b UK phone to E.164');
select t.check((select email from acq.leads where business_name = 'Smile Dental') = 'info@smile-dental.com', '07c email lowercased');
select t.check((select domain from acq.leads where business_name = 'Facebook Only Salon') is null, '07d social-media site is not a business domain');
select t.check(acq.norm_phone('0917 123 4567', 'PH') = '+639171234567' and acq.norm_phone('0917 123 4567', 'ZZ') is null, '07e PH number ok, unknown country not guessed');

-- 08 duplicate prevention at the database level
select t.check(t.err($q$insert into acq.leads (org_id, business_name, website) values ('$q$ || :'o1' || $q$', 'Dup', 'smile-dental.com')$q$) = '23505', '08a same domain rejected');
select t.check(t.err($q$insert into acq.leads (org_id, business_name, phone, country_code) values ('$q$ || :'o1' || $q$', 'Dup2', '+44 7700 900123', 'GB')$q$) = '23505', '08b same phone rejected');
select t.check(t.err($q$insert into acq.leads (org_id, business_name, email) values ('$q$ || :'o1' || $q$', 'Dup3', 'INFO@smile-dental.com')$q$) = '23505', '08c same email rejected');
select t.check(t.err($q$insert into acq.leads (org_id, business_name, website) values ('$q$ || :'o2' || $q$', 'Same domain other org', 'smile-dental.com')$q$) = 'ok', '08d same domain allowed in a different org');

-- 09 check constraints
select t.check(t.err($q$update acq.leads set status = 'bogus'$q$) in ('23514', 'P0001'), '09a invalid pipeline status rejected (CHECK, or the pipeline guard once phase 2 is installed)');
select t.check(t.err($q$update acq.leads set score = 101$q$) = '23514', '09b score range enforced');
select t.check(t.err($q$insert into acq.lead_sources (org_id, key, name, config) values ('$q$ || :'o1' || $q$', 'x1', 'X', '{"api_key":"abc"}')$q$) = '23514', '09c secrets cannot be stored in source config');
select t.check(t.err($q$insert into acq.outreach_campaigns (org_id, name, followup_steps) values ('$q$ || :'o1' || $q$', 'bad', '[{"delay_days":0}]')$q$) = '23514', '09d invalid follow-up sequence rejected');
select t.check(t.err($q$insert into acq.outreach_campaigns (org_id, name, followup_steps) values ('$q$ || :'o1' || $q$', 'good', '[{"delay_days":3},{"delay_days":7}]')$q$) = 'ok', '09e valid follow-up sequence accepted');

-- 10 approval gate + tenant-consistent FKs
select id as l1 from acq.leads where business_name = 'Smile Dental' \gset
select t.check(t.err($q$insert into acq.outreach_messages (org_id, lead_id, channel, step, to_address, subject, body, status, idempotency_key)
  values ('$q$ || :'o1' || $q$', '$q$ || :'l1' || $q$', 'email', 0, 'info@smile-dental.com', 's', 'b', 'queued', 'k-gate-1')$q$) = '23514', '10a cannot queue a message that was not approved');
select t.check(t.err($q$insert into acq.outreach_messages (org_id, lead_id, channel, step, to_address, subject, body, status, approval_status, idempotency_key)
  values ('$q$ || :'o1' || $q$', '$q$ || :'l1' || $q$', 'email', 0, 'info@smile-dental.com', 's', 'b', 'sent', 'approved', 'k-gate-2')$q$) = '23514', '10b approved without an approver is rejected');
insert into acq.outreach_messages (org_id, lead_id, channel, step, to_address, subject, body, idempotency_key)
values (:'o1', :'l1', 'email', 0, 'info@smile-dental.com', 'Hello', 'Body', 'k-gate-3');
select t.check((select status || '/' || approval_status from acq.outreach_messages where idempotency_key = 'k-gate-3') = 'pending_approval/pending', '10c new drafts start pending approval');
select t.check(t.err($q$update acq.outreach_messages set status = 'queued' where idempotency_key = 'k-gate-3'$q$) = '23514', '10d pending message cannot be queued');
select t.check(t.err($q$update acq.outreach_messages set status = 'queued', approval_status = 'approved', approval_source = 'user', approved_by = '$q$ || :'ua' || $q$' where idempotency_key = 'k-gate-3'$q$) = 'ok', '10e approved message can be queued');
select t.check(t.err($q$insert into acq.outreach_messages (org_id, lead_id, channel, step, to_address, body, idempotency_key)
  values ('$q$ || :'o2' || $q$', '$q$ || :'l1' || $q$', 'email', 1, 'x@y.com', 'b', 'k-cross')$q$) = '23503', '10f message cannot point at another org''s lead');
select t.check(t.err($q$insert into acq.outreach_messages (org_id, lead_id, channel, step, to_address, body, idempotency_key)
  values ('$q$ || :'o1' || $q$', '$q$ || :'l1' || $q$', 'email', 0, 'x@y.com', 'dup step', 'k-dupstep')$q$) = '23505', '10g one live message per lead per step');

-- 11 RLS isolation (authenticated role)
set role authenticated;
select t.as_user(:'ua'::uuid);
select t.check((select count(*) from acq.leads) = 2, '11a owner sees only own org leads');
select t.check((select count(*) from acq.organizations) = 1 and (select count(*) from acq.profiles) = 3, '11b org + profiles scoped');
select t.check((select count(*) from acq.leads where org_id = :'o2') = 0, '11c other org invisible');
select t.check(t.rows($q$update acq.leads set notes = 'x' where org_id = '$q$ || :'o2' || $q$'$q$) = 0, '11d cannot update another org''s lead');
select t.check(t.err($q$insert into acq.leads (org_id, business_name) values ('$q$ || :'o1' || $q$', 'Direct insert')$q$) = '42501', '11e no direct lead inserts (RPC only)');
select t.check(t.rows($q$update acq.leads set notes = 'called', tags = '{hot}' where business_name = 'Smile Dental'$q$) = 1, '11f may edit notes/tags');
select t.check(t.err($q$update acq.leads set status = 'won' where business_name = 'Smile Dental'$q$) = '42501', '11g cannot set status directly');
select t.check(t.err($q$update acq.leads set do_not_contact = false$q$) = '42501', '11h cannot clear do_not_contact directly');
select t.check(t.err($q$update acq.outreach_messages set approval_status = 'approved'$q$) = '42501', '11i cannot approve outreach via direct update');
select t.check(t.err($q$delete from acq.leads$q$) = '42501', '11j cannot delete leads directly');
select t.check(t.err($q$select * from acq.rate_limits$q$) = '42501', '11k rate_limits hidden');
select t.check((select updated_by from acq.leads where business_name = 'Smile Dental') = :'ua'::uuid, '11l updated_by stamped from JWT');
-- source/campaign management needs admin+
select t.check(t.err($q$insert into acq.lead_sources (org_id, key, name) values ('$q$ || :'o1' || $q$', 'apify_main', 'Apify')$q$) = 'ok', '11m owner can add a lead source');
select t.check((select created_by from acq.lead_sources where key = 'apify_main') = :'ua'::uuid, '11n created_by stamped');
select t.check((select count(*) from acq.activity_logs where action = 'lead_sources.insert') >= 1, '11o audit log written (through definer trigger)');
select t.check(t.err($q$insert into acq.lead_sources (org_id, key, name) values ('$q$ || :'o2' || $q$', 'sneaky', 'Sneaky')$q$) = '42501', '11p cannot create a source in another org');
reset role;

-- viewer / member
set role authenticated;
select t.as_user(:'uv'::uuid);
select t.check((select count(*) from acq.leads) = 2, '12a viewer can read');
select t.check(t.rows($q$update acq.leads set notes = 'v'$q$) = 0, '12b viewer cannot write');
select t.check(t.err($q$insert into acq.lead_sources (org_id, key, name) values ('$q$ || :'o1' || $q$', 'vsrc', 'V')$q$) = '42501', '12c viewer cannot add sources');
select t.as_user(:'um'::uuid);
select t.check(t.rows($q$update acq.leads set notes = 'm' where business_name = 'Smile Dental'$q$) = 1, '12d member can edit notes');
select t.check(t.err($q$insert into acq.lead_sources (org_id, key, name) values ('$q$ || :'o1' || $q$', 'msrc', 'M')$q$) = '42501', '12e member cannot add sources (admin+)');
select t.check(t.err($q$select acq.add_member('v@org1.test', 'member')$q$) = '42501', '12f member cannot add members');
select t.as_user(:'uf'::uuid);
select t.check((select count(*) from acq.leads) = 0 and (select count(*) from acq.organizations) = 0, '12g user without a profile sees nothing');
select t.as_user(:'ub'::uuid);
select t.check((select count(*) from acq.leads) = 2 and (select count(*) from acq.leads where org_id = :'o1') = 0, '12h org2 owner sees only org2 leads');
reset role;

-- 13 anon has no access
set role anon;
select t.check(t.err($q$select * from acq.leads$q$) = '42501', '13 anon cannot touch acq');
reset role;

-- 14 add_member rules
set role authenticated;
select t.as_user(:'ua'::uuid);
select t.check(acq.add_member('free@x.test', 'member')->>'ok' = 'true', '14a owner adds an existing user');
select t.check(t.err($q$select acq.add_member('nobody@x.test', 'member')$q$) = 'P0001', '14b unknown user rejected');
select t.check(t.err($q$select acq.add_member('free@x.test', 'owner')$q$) = 'P0001', '14c cannot grant owner');
reset role;
select t.check((select role from acq.profiles where id = :'uf') = 'member', '14d profile created with the requested role');
select t.check(t.err($q$insert into acq.profiles (id, org_id) values ('$q$ || :'ub' || $q$', '$q$ || :'o1' || $q$')$q$) = '23505', '14e user is in only one org');

-- 15 service role
set role service_role;
select t.check((select count(*) from acq.leads) = 4, '15 service role sees every org (server-side only)');
reset role;

-- 16 append-only / immutability / meetings
insert into acq.pipeline_events (org_id, lead_id, to_status) values (:'o1', :'l1', 'new_lead');
select t.check(t.err($q$update acq.pipeline_events set to_status = 'won'$q$) = '42501', '16a pipeline_events cannot be edited');
select t.check(t.err($q$delete from acq.pipeline_events$q$) = '42501', '16b pipeline_events cannot be deleted');
select t.check(t.err($q$update acq.activity_logs set action = 'x'$q$) = '42501', '16c activity_logs cannot be edited');
select t.check(t.err($q$update acq.leads set org_id = '$q$ || :'o2' || $q$' where id = '$q$ || :'l1' || $q$'$q$) = '42501', '16d org_id is immutable');
insert into acq.meetings (org_id, lead_id, title, starts_at, ends_at) values (:'o1', :'l1', 'Demo call', '2030-01-07 10:00+00', '2030-01-07 10:30+00');
select t.check(t.err($q$insert into acq.meetings (org_id, title, starts_at, ends_at) values ('$q$ || :'o1' || $q$', 'Clash', '2030-01-07 10:15+00', '2030-01-07 10:45+00')$q$) = '23P01', '16e overlapping meeting rejected');
select t.check(t.err($q$insert into acq.meetings (org_id, title, starts_at, ends_at) values ('$q$ || :'o1' || $q$', 'Back to back', '2030-01-07 10:30+00', '2030-01-07 11:00+00')$q$) = 'ok', '16f back-to-back meeting allowed');
select t.check(t.err($q$insert into acq.meetings (org_id, title, starts_at, ends_at) values ('$q$ || :'o2' || $q$', 'Other org same time', '2030-01-07 10:00+00', '2030-01-07 10:30+00')$q$) = 'ok', '16g other org unaffected');
delete from acq.leads where id = :'l1';
select t.check((select count(*) from acq.pipeline_events where lead_id = :'l1') = 0, '16h deleting a lead cascades its events');

\echo ALL_TESTS_PASSED_P1
