-- Phase 2 tests: ingest/dedupe, pipeline state machine, qualification, search queue, user RPCs, privileges. THROWAWAY DB only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;

insert into auth.users (email) values ('own@p2a.test'), ('adm@p2a.test'), ('mem@p2a.test'), ('vie@p2a.test'), ('own@p2b.test');
select id as uo from auth.users where email = 'own@p2a.test' \gset
select id as ua from auth.users where email = 'adm@p2a.test' \gset
select id as um from auth.users where email = 'mem@p2a.test' \gset
select id as uv from auth.users where email = 'vie@p2a.test' \gset
select id as ub from auth.users where email = 'own@p2b.test' \gset
select acq.create_organization('P2 Org A', 'p2-org-a', 'own@p2a.test') as oa \gset
select acq.create_organization('P2 Org B', 'p2-org-b', 'own@p2b.test') as ob \gset
insert into acq.profiles (id, org_id, email, role) values (:'ua', :'oa', 'adm@p2a.test', 'admin'), (:'um', :'oa', 'mem@p2a.test', 'member'), (:'uv', :'oa', 'vie@p2a.test', 'viewer');
select id as sa from acq.lead_sources where org_id = :'oa' and key = 'manual' \gset
select id as sb from acq.lead_sources where org_id = :'ob' and key = 'manual' \gset
insert into acq.lead_sources (org_id, key, name, provider) values (:'oa', 'osm', 'OpenStreetMap', 'osm_overpass');
select id as sosm from acq.lead_sources where org_id = :'oa' and key = 'osm' \gset

-- ---------- A. ingest / dedupe ----------
select acq.ingest_leads(:'oa', :'sa', null, $j$[
  {"business_name":"Alpha Dental","website":"https://www.alpha-dental.co.uk/","phone":"020 7946 0001","email":"Hello@Alpha-Dental.co.uk","niche":"dentist","city":"London","country_code":"gb","rating":"4.6","review_count":"120"},
  {"business_name":"Beta Salon","phone":"+44 161 496 0002","niche":"salon","city":"Manchester","country_code":"GB"},
  {"business_name":"Gamma Physio","niche":"physio","city":"Leeds","country_code":"GB"}
]$j$::jsonb) as ing1 \gset
select t.check((:'ing1'::jsonb->>'created')::int = 3, 'A1 three new leads created', :'ing1');
select t.check((select count(*) from acq.pipeline_events pe join acq.leads l on l.id = pe.lead_id where l.org_id = :'oa' and pe.to_status = 'new_lead' and pe.from_status is null) = 3,
  'A2 creation logged in pipeline_events');
select t.check((select phone_e164 from acq.leads where org_id = :'oa' and business_name = 'Alpha Dental') = '+442079460001'
  and (select domain from acq.leads where org_id = :'oa' and business_name = 'Alpha Dental') = 'alpha-dental.co.uk'
  and (select rating from acq.leads where org_id = :'oa' and business_name = 'Alpha Dental') = 4.6, 'A3 normalised on the way in');
select acq.ingest_leads(:'oa', :'sa', null, $j$[
  {"business_name":"ALPHA DENTAL LTD","website":"alpha-dental.co.uk","city":"London"},
  {"business_name":"Beta Salon (Manchester)","phone":"0161 496 0002","website":"https://beta-salon.co.uk","email":"hi@beta-salon.co.uk"},
  {"business_name":"gamma physio","city":"leeds","country_code":"GB","address":"1 High St"},
  {"business_name":""},
  "not an object"
]$j$::jsonb) as ing2 \gset
select t.check((:'ing2'::jsonb->>'created')::int = 0 and (:'ing2'::jsonb->>'duplicate')::int = 1 and (:'ing2'::jsonb->>'merged')::int = 2
  and (:'ing2'::jsonb->>'invalid')::int = 2, 'A4 re-discovery merges / dedupes / rejects junk', :'ing2');
select t.check((select count(*) from acq.leads where org_id = :'oa') = 3, 'A5 still exactly 3 leads');
select t.check((select email from acq.leads where org_id = :'oa' and business_name = 'Beta Salon') = 'hi@beta-salon.co.uk'
  and (select domain from acq.leads where org_id = :'oa' and business_name = 'Beta Salon') = 'beta-salon.co.uk', 'A6 merge filled blanks from the new data');
select t.check((select business_name from acq.leads where org_id = :'oa' and phone_e164 = '+442079460001') = 'Alpha Dental', 'A7 merge never overwrites existing values');
-- identifier belonging to a different lead must not be stolen
select acq.ingest_leads(:'oa', :'sa', null, '[{"business_name":"Gamma Physio","city":"Leeds","phone":"020 7946 0001","country_code":"GB"}]'::jsonb) as ing3 \gset
select t.check((select phone_e164 from acq.leads where org_id = :'oa' and business_name = 'Gamma Physio') is null
  and (select count(*) from acq.leads where org_id = :'oa') = 3, 'A8 phone owned by another lead is not copied (no unique violation)', :'ing3');
-- same data in another org is independent
select t.check((acq.ingest_leads(:'ob', :'sb', null, '[{"business_name":"Alpha Dental","website":"alpha-dental.co.uk"}]'::jsonb)->>'created')::int = 1, 'A9 other org can hold the same business');
-- bad input
select t.check(t.err(format($f$select acq.ingest_leads(%L, %L, null, '{"a":1}'::jsonb)$f$, :'oa', :'sa')) = 'P0001', 'A10 items must be an array');
select t.check(t.err(format($f$select acq.ingest_leads(%L, %L, null, '[]'::jsonb)$f$, :'oa', :'sb')) = 'P0001', 'A11 source from another org rejected');
select t.check(t.err(format($f$select acq.ingest_leads(%L, %L, null, (select jsonb_agg(jsonb_build_object('business_name','x'||g)) from generate_series(1,201) g))$f$, :'oa', :'sa')) = 'P0001', 'A12 batch > 200 rejected');
select acq.ingest_leads(:'oa', :'sa', null, jsonb_build_array(jsonb_build_object('business_name', repeat('N', 500), 'category', repeat('c', 500), 'raw', jsonb_build_object('k', repeat('x', 30000))))) as ing4 \gset
select t.check((:'ing4'::jsonb->>'created')::int = 1 and (select length(business_name) from acq.leads where org_id = :'oa' and business_name like 'NNN%') = 200
  and (select raw from acq.leads where org_id = :'oa' and business_name like 'NNN%') = '{}'::jsonb, 'A13 over-long text truncated, oversized raw dropped', :'ing4');
-- daily cap per source
update acq.lead_sources set daily_limit = 5 where id = :'sa';
select acq.ingest_leads(:'oa', :'sa', null, $j$[{"business_name":"Cap 1"},{"business_name":"Cap 2"},{"business_name":"Cap 3"},{"business_name":"Alpha Dental","city":"London"}]$j$::jsonb) as ing5 \gset
select t.check((:'ing5'::jsonb->>'created')::int = 1 and (:'ing5'::jsonb->>'limited')::int = 2 and (:'ing5'::jsonb->>'duplicate')::int = 1,
  'A14 per-source daily cap stops new leads but still dedupes', :'ing5');
update acq.lead_sources set daily_limit = 200 where id = :'sa';
-- run counters
insert into acq.lead_search_runs (org_id, source_id, niche, country_code) values (:'oa', :'sosm', 'dentist', 'GB') returning id as runid \gset
select acq.ingest_leads(:'oa', :'sosm', :'runid', '[{"business_name":"Run Lead 1"},{"business_name":"Run Lead 2"},{"business_name":"Run Lead 1"}]'::jsonb) as ing6 \gset
select t.check((select found_count = 3 and new_count = 2 and dup_count = 1 from acq.lead_search_runs where id = :'runid'), 'A15 search run counters updated');

-- ---------- B. suppression ----------
select id as l_beta from acq.leads where org_id = :'oa' and business_name = 'Beta Salon' \gset
select acq.suppress_lead(:'l_beta', 'unsubscribe', 'test') as sup \gset
select t.check((select do_not_contact and unsubscribed_at is not null and status = 'lost' and lost_reason = 'dnc_unsubscribe' from acq.leads where id = :'l_beta'), 'B1 unsubscribe marks lead DNC + lost');
select t.check((select count(*) from acq.suppressions where org_id = :'oa' and reason = 'unsubscribe') = 3, 'B2 email, phone and domain suppressed');
select t.check((acq.ingest_leads(:'oa', :'sa', null, '[{"business_name":"Beta Salon Again","email":"HI@beta-salon.co.uk"}]'::jsonb)->>'suppressed')::int = 1, 'B3 re-discovered suppressed lead is not re-added');
select t.check(t.err(format($f$update acq.leads set do_not_contact = false where id = %L$f$, :'l_beta')) = 'P0001', 'B4 DNC cannot be cleared by a plain update');
select t.check(t.err(format($f$update acq.leads set status = 'qualified' where id = %L$f$, :'l_beta')) = 'ok', 'B5 (lost -> qualified is a legal move; DNC keeps outreach blocked)');
select t.check(t.err(format($f$update acq.leads set status = 'approved' where id = %L$f$, :'l_beta')) = 'P0001', 'B6 DNC lead cannot reach Approved');

-- ---------- C. pipeline state machine ----------
select id as l_a from acq.leads where org_id = :'oa' and business_name = 'Alpha Dental' \gset
select t.check(t.err(format($f$update acq.leads set status = 'contacted' where id = %L$f$, :'l_a')) = 'P0001', 'C1 new_lead -> contacted is illegal');
select t.check(t.err(format($f$update acq.leads set status = 'qualified' where id = %L$f$, :'l_a')) = 'ok', 'C2 new_lead -> qualified ok');
select t.check(t.err(format($f$update acq.leads set status = 'approved' where id = %L$f$, :'l_a')) = 'P0001', 'C3 Approved needs an approved message');
insert into acq.outreach_messages (org_id, lead_id, channel, step, to_address, subject, body, idempotency_key)
values (:'oa', :'l_a', 'email', 0, 'hello@alpha-dental.co.uk', 'Hi', 'Hello', 'p2-m1') returning id as m1 \gset
select t.check(t.err(format($f$update acq.leads set status = 'approved' where id = %L$f$, :'l_a')) = 'P0001', 'C4 a pending (unapproved) message does not unlock Approved');
update acq.outreach_messages set approval_status = 'approved', approval_source = 'user', approved_by = :'uo', approved_at = now(), status = 'approved' where id = :'m1';
select t.check(t.err(format($f$update acq.leads set status = 'approved' where id = %L$f$, :'l_a')) = 'ok', 'C5 approved message unlocks Approved');
select t.check(t.err(format($f$update acq.leads set status = 'contacted' where id = %L$f$, :'l_a')) = 'P0001', 'C6 Contacted needs a message that was really sent');
update acq.outreach_messages set status = 'sent', sent_at = now(), provider = 'resend', provider_message_id = 'rs_1' where id = :'m1';
select t.check(t.err(format($f$update acq.leads set status = 'contacted' where id = %L$f$, :'l_a')) = 'ok', 'C7 sent message unlocks Contacted');
select t.check((select last_contacted_at is not null from acq.leads where id = :'l_a'), 'C8 last_contacted_at stamped');
-- follow-up + pending message stop on reply
insert into acq.followups (org_id, lead_id, step, channel, due_at) values (:'oa', :'l_a', 1, 'email', now() + interval '3 days') returning id as f1 \gset
insert into acq.outreach_messages (org_id, lead_id, kind, followup_id, channel, step, to_address, body, idempotency_key)
values (:'oa', :'l_a', 'followup', :'f1', 'email', 1, 'hello@alpha-dental.co.uk', 'Following up', 'p2-m2') returning id as m2 \gset
select t.check(t.err(format($f$update acq.leads set status = 'replied' where id = %L$f$, :'l_a')) = 'ok', 'C9 contacted -> replied ok');
select t.check((select status from acq.followups where id = :'f1') = 'cancelled' and (select status from acq.outreach_messages where id = :'m2') = 'cancelled',
  'C10 reply stops scheduled follow-up and cancels its draft');
select t.check((select last_reply_at is not null from acq.leads where id = :'l_a'), 'C11 last_reply_at stamped');
select t.check(t.err(format($f$update acq.leads set status = 'won' where id = %L$f$, :'l_a')) = 'ok', 'C12 replied -> won ok');
select t.check(t.err(format($f$update acq.leads set status = 'lost' where id = %L$f$, :'l_a')) = 'P0001', 'C13 won is final');
select t.check((select array_agg(to_status order by id) from acq.pipeline_events where lead_id = :'l_a') = array['new_lead','qualified','approved','contacted','replied','won'],
  'C14 full history in pipeline_events');
select t.check((select won_at is not null from acq.leads where id = :'l_a'), 'C15 won_at stamped');
-- lost handling
select id as l_g from acq.leads where org_id = :'oa' and business_name = 'Gamma Physio' \gset
select set_config('acq.reason', 'no budget', false);
select t.check(t.err(format($f$update acq.leads set status = 'lost' where id = %L$f$, :'l_g')) = 'ok', 'C16 new_lead -> lost');
select set_config('acq.reason', '', false);
select t.check((select lost_reason = 'no budget' and lost_at is not null from acq.leads where id = :'l_g'), 'C17 lost reason + time recorded');
select t.check(t.err(format($f$update acq.leads set status = 'qualified' where id = %L$f$, :'l_g')) = 'ok', 'C18 lost -> qualified ok');
select t.check((select lost_at is null and lost_reason is null from acq.leads where id = :'l_g'), 'C18b lost fields cleared on revival');

-- ---------- D. qualification ----------
select id as l_c1 from acq.leads where org_id = :'oa' and business_name = 'Cap 1' \gset
select acq.record_qualification(:'l_c1', $j$ {"score": 82, "reasons":["Books by phone","No online booking"],"pain_points":["Missed calls"],
   "website_quality":"poor","has_online_booking":"no","booking_availability":"phone only","recommended_offer":"AI receptionist",
   "summary":"Great fit","signals":{"has_form":false}} $j$::jsonb, 'gpt-x', 'v1') as q1 \gset
select t.check((:'q1'::jsonb->>'ok')::boolean and (:'q1'::jsonb->>'fit') = 'excellent' and (:'q1'::jsonb->>'status') = 'qualified', 'D1 score >= threshold qualifies', :'q1');
select t.check((select count(*) from acq.lead_qualification where lead_id = :'l_c1' and is_current) = 1
  and (select array_length(reasons, 1) from acq.lead_qualification where lead_id = :'l_c1' and is_current) = 2, 'D2 reasons / pain points stored');
select t.check((select score from acq.leads where id = :'l_c1') = 82, 'D3 score copied to the lead');
select t.check((select reason from acq.pipeline_events where lead_id = :'l_c1' and to_status = 'qualified') = 'ai_score_82'
  and (select actor_type from acq.pipeline_events where lead_id = :'l_c1' and to_status = 'qualified') = 'n8n', 'D4 AI qualification attributed to n8n with its score');
select acq.record_qualification(:'l_c1', '{"score": 30, "has_online_booking":"maybe","website_quality":"great"}'::jsonb) as q2 \gset
select t.check((select count(*) from acq.lead_qualification where lead_id = :'l_c1') = 2 and (select count(*) from acq.lead_qualification where lead_id = :'l_c1' and is_current) = 1
  and (select score from acq.lead_qualification where lead_id = :'l_c1' and is_current) = 30
  and (select has_online_booking || website_quality from acq.lead_qualification where lead_id = :'l_c1' and is_current) = 'unknownunknown', 'D5 re-qualification supersedes; unknown enum values normalised');
select t.check((select status from acq.leads where id = :'l_c1') = 'qualified', 'D6 a lower rescore does not silently demote a qualified lead');
select id as l_c2 from acq.leads where org_id = :'oa' and business_name = 'Run Lead 1' \gset
select acq.record_qualification(:'l_c2', '{"score": 35.4}'::jsonb) as q3 \gset
select t.check((:'q3'::jsonb->>'fit') = 'poor' and (:'q3'::jsonb->>'status') = 'new_lead' and (:'q3'::jsonb->>'is_fit') = 'false', 'D7 low score stays New Lead (fit derived server-side)', :'q3');
select t.check(t.err(format($f$select acq.record_qualification(%L, '{"score": 101}'::jsonb)$f$, :'l_c2')) = 'P0001', 'D8 score > 100 rejected');
select t.check(t.err(format($f$select acq.record_qualification(%L, '{"score": "high"}'::jsonb)$f$, :'l_c2')) = 'P0001', 'D9 non-numeric score rejected');
select t.check(t.err(format($f$select acq.record_qualification(%L, '{}'::jsonb)$f$, :'l_c2')) = 'P0001', 'D10 missing score rejected');
select t.check(t.err(format($f$select acq.record_qualification(%L, '{"score":50}'::jsonb)$f$, gen_random_uuid())) = 'P0001', 'D11 unknown lead rejected');
-- queue
update acq.leads set qual_attempts = 0, qual_locked_until = null where org_id = :'oa';
select count(*) as nclaim from acq.claim_leads_for_qualification(50) \gset
select t.check(:nclaim::int >= 1, 'D12 claim returns unqualified new leads');
select t.check((select count(*) from acq.claim_leads_for_qualification(50) c where (c->>'lead_id')::uuid = :'l_c1' or (c->>'lead_id')::uuid = :'l_c2') = 0, 'D13 qualified / locked leads are not handed out again');
select t.check((select count(*) from acq.claim_leads_for_qualification(50)) = 0, 'D14 claimed leads are locked (no double processing)');
update acq.leads set qual_locked_until = now() - interval '1 minute', qual_attempts = 3 where org_id = :'oa';
select t.check((select count(*) from acq.claim_leads_for_qualification(50)) = 0, 'D15 leads that failed 3 times are not retried forever');
update acq.leads set qual_attempts = 0, qual_locked_until = null where org_id = :'oa';
select acq.qualification_failed(:'l_c2', 'openai 500') as qf \gset
select t.check((select qual_error = 'openai 500' and qual_locked_until > now() from acq.leads where id = :'l_c2'), 'D16 failed AI call backs off');
update acq.leads set qual_locked_until = null, requalify_requested_at = now() where id = :'l_c2';
select t.check((select count(*) from acq.claim_leads_for_qualification(50) c where (c->>'lead_id')::uuid = :'l_c2' and c->>'offer_context' like '%AI receptionist%' and (c->>'threshold')::int = 60) = 1,
  'D17 claim payload carries the offer context and threshold');
update acq.leads set requalify_requested_at = now(), qual_attempts = 0, qual_locked_until = null where id = :'l_c1';
select t.check((select count(*) from acq.claim_leads_for_qualification(50) c where (c->>'lead_id')::uuid = :'l_c1') = 1, 'D18 re-qualification request re-queues a qualified lead');

-- ---------- E. search runs ----------
update acq.lead_search_runs set status = 'completed' where org_id = :'oa';
set role authenticated;
select t.as_user(:'uv'::uuid);
select t.check(t.err($q$select acq.queue_search_run('osm','dentist','Bristol',null,'GB',20)$q$) = '42501', 'E1 viewer cannot queue a search');
select t.as_user(:'um'::uuid);
select acq.queue_search_run('osm', 'dentist', 'Bristol', 'Avon', 'gb', 20) as qr1 \gset
select t.check((:'qr1'::jsonb->>'ok')::boolean and (:'qr1'::jsonb ? 'run_id'), 'E2 member can queue a search', :'qr1');
select t.check((acq.queue_search_run('osm', 'Dentist', 'bristol', null, 'GB', 20)->>'duplicate')::boolean, 'E3 identical queued search is not duplicated');
select t.check(t.err($q$select acq.queue_search_run('manual','dentist','Bristol',null,'GB',20)$q$) = 'P0001', 'E4 manual source cannot be "searched"');
select t.check(t.err($q$select acq.queue_search_run('osm','dentist','Bristol',null,'UK1',20)$q$) = 'P0001', 'E5 bad country rejected');
select t.check(t.err($q$select acq.queue_search_run('osm','dentist','Bristol',null,'GB',500)$q$) = 'P0001', 'E6 max_results capped at 60');
select t.check(t.err($q$select acq.queue_search_run('nope','dentist','Bristol',null,'GB',20)$q$) = 'P0001', 'E7 unknown source rejected');
reset role;
update acq.system_settings set value = '1' where org_id = :'oa' and key = 'max_search_runs_per_day';
set role authenticated; select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.queue_search_run('osm','salon','Leeds',null,'GB',20)$q$) = 'P0001', 'E8 daily search cap enforced');
reset role;
update acq.system_settings set value = '20' where org_id = :'oa' and key = 'max_search_runs_per_day';
select acq.claim_search_runs(5) as claimed \gset
select t.check((select count(*) from acq.claim_search_runs(5)) = 0, 'E9 claimed run is locked');
select t.check((select status from acq.lead_search_runs where id = (:'qr1'::jsonb->>'run_id')::uuid) = 'running'
  and (select attempts from acq.lead_search_runs where id = (:'qr1'::jsonb->>'run_id')::uuid) = 1, 'E10 run marked running (attempt 1)');
update acq.lead_search_runs set locked_until = now() - interval '1 minute' where id = (:'qr1'::jsonb->>'run_id')::uuid;
select t.check((select count(*) from acq.claim_search_runs(5)) = 1, 'E11 crashed run is reclaimed after the lock expires');
update acq.lead_search_runs set locked_until = now() - interval '1 minute', attempts = 3 where id = (:'qr1'::jsonb->>'run_id')::uuid;
select count(*) as n0 from acq.claim_search_runs(5) \gset
select t.check(:n0::int = 0 and (select status from acq.lead_search_runs where id = (:'qr1'::jsonb->>'run_id')::uuid) = 'failed', 'E12 run failing 3 times is marked failed');
select t.check((acq.complete_search_run((:'qr1'::jsonb->>'run_id')::uuid, true)->>'ok')::boolean = false, 'E13 completing a non-running run is a no-op');

-- ---------- F. user RPCs + RLS ----------
select id as l_c3 from acq.leads where org_id = :'oa' and business_name = 'Alpha Dental' \gset
set role authenticated; select t.as_user(:'um'::uuid);
select t.check((acq.import_leads('[{"business_name":"CSV Clinic","email":"a@csv-clinic.com","niche":"clinic","city":"Bath","country_code":"GB"}]'::jsonb)->>'created')::int = 1, 'F1 member can import leads');
select t.check(t.err($q$select acq.import_leads('[{"business_name":"X"}]'::jsonb, 'osm')$q$) = 'P0001', 'F2 import only through manual / csv sources');
select id as l_csv from acq.leads where business_name = 'CSV Clinic' \gset
select t.check(t.err(format($f$update acq.leads set status = 'qualified' where id = %L$f$, :'l_csv')) = '42501', 'F3 no direct status writes from the frontend role');
select t.check((acq.move_lead(:'l_csv', 'qualified', 'looks good')->>'ok')::boolean, 'F4 member can move a lead through the RPC');
select t.check(t.err(format($f$select acq.move_lead(%L, 'lost')$f$, :'l_csv')) = 'P0001', 'F5 lost requires a reason');
select t.check(t.err(format($f$select acq.move_lead(%L, 'contacted', 'x')$f$, :'l_csv')) = 'P0001', 'F6 RPC cannot skip the approval / send gates');
select t.check((select actor_type || ':' || reason from acq.pipeline_events where lead_id = :'l_csv' and to_status = 'qualified') = 'user:looks good', 'F7 user move recorded with actor and reason');
select t.as_user(:'ub'::uuid);
select t.check(t.err(format($f$select acq.move_lead(%L, 'lost', 'x')$f$, :'l_csv')) = 'P0001', 'F8 other org cannot move my lead');
select t.check((select count(*) from acq.v_leads) = 1 or (select count(*) from acq.v_leads) = 0, 'F9 board view only shows own org');
select t.check((select count(*) from acq.v_leads where org_id = :'oa') = 0, 'F9b board view hides other org');
select t.as_user(:'uv'::uuid);
select t.check(t.err(format($f$select acq.move_lead(%L, 'lost', 'x')$f$, :'l_csv')) = '42501', 'F10 viewer cannot move leads');
select t.check(t.err(format($f$select acq.mark_do_not_contact(%L)$f$, :'l_csv')) = '42501', 'F11 viewer cannot mark do-not-contact');
select t.check((select count(*) from acq.v_pipeline) >= 1 and (select count(*) from acq.v_leads where niche = 'clinic') = 1, 'F12 viewer can read the board');
select t.as_user(:'um'::uuid);
select t.check((acq.mark_do_not_contact(:'l_csv', 'asked on phone')->>'ok')::boolean, 'F13 member can mark do-not-contact');
select t.check((select status from acq.leads where id = :'l_csv') = 'lost' and (select do_not_contact from acq.leads where id = :'l_csv'), 'F13b lead is lost + DNC');
select t.check(t.err(format($f$select acq.reinstate_lead(%L)$f$, :'l_csv')) = '42501', 'F14 only an owner can reinstate');
select t.as_user(:'uo'::uuid);
select t.check((acq.reinstate_lead(:'l_csv')->>'ok')::boolean, 'F15 owner can reinstate a manual DNC');
select t.check(not (select do_not_contact from acq.leads where id = :'l_csv') and (select status from acq.leads where id = :'l_csv') = 'new_lead', 'F15a reinstated lead is back to New Lead');
select t.check((select count(*) from acq.suppressions where lead_id = :'l_csv') = 0, 'F15b manual suppressions removed on reinstate');
reset role;
select acq.suppress_lead(:'l_csv', 'bounce', 'resend') as sb1 \gset
set role authenticated; select t.as_user(:'uo'::uuid);
select t.check(t.err(format($f$select acq.reinstate_lead(%L)$f$, :'l_csv')) = 'P0001', 'F16 bounces can never be reinstated');
select t.check(t.err(format($f$select acq.erase_lead(%L)$f$, :'l_csv')) = 'ok', 'F17 admin+ can erase a lead (GDPR)');
select t.as_user(:'um'::uuid);
select t.check(t.err(format($f$select acq.erase_lead(%L)$f$, :'l_c3')) = '42501', 'F18 member cannot erase');
reset role;
select t.check(not exists (select 1 from acq.leads where id = :'l_csv') and not exists (select 1 from acq.pipeline_events where lead_id = :'l_csv'), 'F19 erased lead and its history are gone');
select t.check(exists (select 1 from acq.suppressions where org_id = :'oa' and reason = 'erasure' and value like 'sha256:%')
  and not exists (select 1 from acq.suppressions where value = 'a@csv-clinic.com' and reason = 'erasure'), 'F20 erasure keeps only hashed identifiers');
select t.check((acq.ingest_leads(:'oa', :'sa', null, '[{"business_name":"CSV Clinic back","email":"a@csv-clinic.com"}]'::jsonb)->>'suppressed')::int = 1, 'F21 erased lead is not re-imported');

-- ---------- G. privileges: service functions are not callable from the frontend role ----------
set role authenticated; select t.as_user(:'uo'::uuid);
select t.check(t.err(format($f$select acq.ingest_leads(%L, %L, null, '[]'::jsonb)$f$, :'oa', :'sa')) = '42501', 'G1 ingest_leads is service-only');
select t.check(t.err(format($f$select acq.record_qualification(%L, '{"score":99}'::jsonb)$f$, :'l_c3')) = '42501', 'G2 record_qualification is service-only');
select t.check(t.err($q$select acq.claim_leads_for_qualification(5)$q$) = '42501', 'G3 claim_leads_for_qualification is service-only');
select t.check(t.err($q$select acq.claim_search_runs(5)$q$) = '42501', 'G4 claim_search_runs is service-only');
select t.check(t.err(format($f$select acq.suppress_lead(%L, 'manual')$f$, :'l_c3')) = '42501', 'G5 suppress_lead is service-only');
select t.check(t.err(format($f$select acq.upsert_lead(%L, %L, null, '{"business_name":"x"}'::jsonb)$f$, :'oa', :'sa')) = '42501', 'G6 upsert_lead is service-only');
select t.check(t.err(format($f$select acq.stop_followups(%L, 'x')$f$, :'l_c3')) = '42501', 'G7 stop_followups is service-only');
reset role;
set role anon;
select t.check(t.err($q$select * from acq.v_leads$q$) = '42501' and t.err($q$select acq.import_leads('[]'::jsonb)$q$) = '42501', 'G8 anon has no access');
reset role;
select t.check((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'acq'
  and p.prosecdef and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))) = 0,
  'G9 every SECURITY DEFINER function pins search_path');

-- ---------- H. SSRF-safe domains + rate limiter ----------
select t.check(acq.norm_domain('http://192.168.1.10/admin') is null and acq.norm_domain('10.0.0.5') is null and acq.norm_domain('http://localhost:8080') is null
  and acq.norm_domain('printer.local') is null and acq.norm_domain('intranet.corp') is null and acq.norm_domain('https://www.good-clinic.co.uk/x') = 'good-clinic.co.uk',
  'H1 IPs / internal names never become a fetchable domain');
select t.check((acq.hit_rate_limit('t:rl', 3, 60)->>'allowed')::boolean and (acq.hit_rate_limit('t:rl', 3, 60)->>'allowed')::boolean
  and (acq.hit_rate_limit('t:rl', 3, 60)->>'allowed')::boolean and not (acq.hit_rate_limit('t:rl', 3, 60)->>'allowed')::boolean, 'H2 rate limiter blocks the 4th hit in a window');
select t.check(t.err($q$select acq.hit_rate_limit('x', 0, 60)$q$) = 'P0001', 'H3 bad limiter args rejected');
set role authenticated; select t.as_user(:'uo'::uuid);
select t.check(t.err($q$select acq.hit_rate_limit('x', 5, 60)$q$) = '42501', 'H4 rate limiter is service-only');
reset role;

\echo ALL_TESTS_PASSED_P2
