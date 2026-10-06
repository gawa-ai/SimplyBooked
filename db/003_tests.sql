-- =====================================================================
-- BOOKING OS — functional test suite (run on a THROWAWAY database only)
-- Every check raises an exception on failure; the script stops at the first failure.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;

create or replace function pg_temp.check(p_ok boolean, p_name text, p_info jsonb default null)
returns void language plpgsql as $$
begin
  if coalesce(p_ok, false) then raise notice 'PASS  %', p_name;
  else raise exception 'FAIL  % :: %', p_name, coalesce(p_info::text, ''); end if;
end $$;

set client_min_messages = notice;

-- next Monday (dental open) and next Saturday (salon open), in London time, at least 2 days out
select to_char(d, 'YYYY-MM-DD') as mon from (
  select (now() at time zone 'Europe/London')::date + g as d from generate_series(2, 9) g
) x where extract(dow from d) = 1 limit 1 \gset
select to_char(d, 'YYYY-MM-DD') as sat from (
  select (now() at time zone 'Europe/London')::date + g as d from generate_series(2, 9) g
) x where extract(dow from d) = 6 limit 1 \gset
select to_char(:'mon'::date + 1, 'YYYY-MM-DD') as tue \gset

-- ---------- 1. business info / resolution ----------
select pg_temp.check(bos.dispatch('brightsmile-demo','get_business_info','{}',null,'voice')->>'ok' = 'true', '01 business info by slug');
select pg_temp.check(bos.dispatch('nope-biz','business_info','{}',null,'voice')->>'error' = 'business_not_found', '02 unknown business rejected');
update bos.businesses set vapi_assistant_id = 'asst_demo_1' where slug = 'brightsmile-demo';
select pg_temp.check(bos.dispatch(null,'business_info','{}',null,'voice','{"assistant_id":"asst_demo_1"}')->>'business' = 'BrightSmile Dental', '03 business resolved from Vapi assistant id');

-- ---------- 2. phone / time parsing ----------
select pg_temp.check(bos.norm_phone('07700 900123','44') = '+447700900123', '04 UK local number normalised');
select pg_temp.check(bos.norm_phone('+63 917 123 4567','44') = '+639171234567', '05 international number kept');
select pg_temp.check(bos.parse_time('2:30pm') = '14:30' and bos.parse_time('9') = '09:00' and bos.parse_time('12am') = '00:00'
                     and bos.parse_time('10.15') = '10:15' and bos.parse_time('banana') is null, '06 time parser');

-- ---------- 3. availability ----------
select pg_temp.check((bos.dispatch('brightsmile-demo','check_availability',
  jsonb_build_object('service','check-up','date',:'mon','time','10:00'),null,'voice')->>'available')::boolean,
  '07 fuzzy service name + slot available');
select pg_temp.check(bos.dispatch('brightsmile-demo','check_availability',
  jsonb_build_object('service','check up','date',:'mon','time','12:45'),null,'voice')->>'available' = 'false',
  '08 slot crossing lunch break rejected');
select pg_temp.check(bos.dispatch('brightsmile-demo','check_availability',
  jsonb_build_object('service','Dental Check-up','date',:'sat'),null,'voice')->>'available' = 'false',
  '09 closed day offers next openings');
select pg_temp.check(bos.dispatch('brightsmile-demo','check_availability',
  jsonb_build_object('service','Whitening','date',:'mon'),null,'voice')->>'error' = 'service_not_found',
  '10 unknown service lists options');

-- ---------- 4. booking + idempotency ----------
select bos.dispatch('brightsmile-demo','book_appointment',
  jsonb_build_object('customer_name','Emma Thompson','phone','07700 900111','service','Dental Check-up','date',:'mon','time','10:00'),
  'toolcall-1','voice') as r1 \gset
select pg_temp.check((:'r1'::jsonb)->>'ok' = 'true', '11 booking created', :'r1'::jsonb);
select (:'r1'::jsonb)#>>'{booking,ref}' as ref1 \gset

select pg_temp.check(bos.dispatch('brightsmile-demo','book_appointment',
  jsonb_build_object('customer_name','Emma Thompson','phone','07700 900111','service','Dental Check-up','date',:'mon','time','10:00'),
  'toolcall-1','voice')->>'duplicate' = 'true', '12 same tool call id returns the original result');
select pg_temp.check((select count(*) from bos.bookings where business_id = '11111111-1111-4111-8111-111111111111') = 1, '13 no duplicate booking row');

select pg_temp.check((select count(*) from bos.jobs j join bos.bookings k on k.id = j.booking_id where k.ref = :'ref1'
                      and j.purpose in ('confirmation','calendar_upsert','reminder','followup','review')) >= 4,
  '14 confirmation, calendar, reminders, follow-up, review queued');

-- ---------- 5. double-booking protection ----------
select pg_temp.check(bos.dispatch('brightsmile-demo','book',
  jsonb_build_object('customer_name','James Wilson','phone','07700900222','service','Dental Check-up','date',:'mon','time','10:15'),
  'toolcall-2','voice')->>'error' = 'slot_taken', '15 overlapping slot on same dentist refused');
select pg_temp.check(bos.dispatch('brightsmile-demo','book',
  jsonb_build_object('customer_name','James Wilson','phone','07700900222','service','Hygiene','date',:'mon','time','10:00'),
  'toolcall-3','voice')->>'ok' = 'true', '16 same time with a different resource (hygienist) allowed');
select pg_temp.check(bos.dispatch('brightsmile-demo','check_availability',
  jsonb_build_object('service','Hygiene','date',:'mon','time','10:45'),null,'voice')->>'available' = 'false',
  '17 service buffer respected (45 min + 15 buffer)');
select pg_temp.check((bos.dispatch('brightsmile-demo','check_availability',
  jsonb_build_object('service','Hygiene','date',:'mon','time','11:00'),null,'voice')->>'available')::boolean,
  '18 slot right after buffer is free');

-- failed attempt must not burn the idempotency key
select pg_temp.check(bos.dispatch('brightsmile-demo','book',
  jsonb_build_object('customer_name','Olivia Brown','phone','07700900333','service','Consultation','date',:'mon','time','22:00'),
  'toolcall-4','voice')->>'error' = 'outside_hours', '19 outside hours refused');
select pg_temp.check(bos.dispatch('brightsmile-demo','book',
  jsonb_build_object('customer_name','Olivia Brown','phone','07700900333','service','Consultation','date',:'mon','time','14:00'),
  'toolcall-4','voice')->>'ok' = 'true', '20 retry with same key after a failure succeeds');

-- ---------- 6. find / verification ----------
select pg_temp.check(bos.dispatch('brightsmile-demo','find','{"phone":"07700900111"}',null,'web_voice')->>'error' = 'verification_failed',
  '21 web caller must verify identity');
select pg_temp.check(bos.dispatch('brightsmile-demo','find','{"phone":"07700900111","customer_name":"emma"}',null,'web_voice')->>'ok' = 'true',
  '22 phone + first name verifies');
select pg_temp.check(bos.dispatch('brightsmile-demo','find','{}',null,'voice','{"caller_phone":"+447700900111"}')->>'ok' = 'true',
  '23 phone caller id verifies automatically');
select pg_temp.check(bos.dispatch('brightsmile-demo','find','{"phone":"07700900111","customer_name":"james"}',null,'web_voice')->>'error' = 'verification_failed',
  '24 wrong name refused');

-- ---------- 7. reschedule ----------
select bos.dispatch('brightsmile-demo','reschedule_appointment',
  jsonb_build_object('ref',:'ref1','customer_name','Emma','date',:'tue','time','09:30'),'toolcall-5','web_voice') as r5 \gset
select pg_temp.check((:'r5'::jsonb)->>'ok' = 'true', '25 reschedule ok', :'r5'::jsonb);
select pg_temp.check((select version from bos.bookings where ref = :'ref1') = 2, '26 booking version bumped');
select pg_temp.check((select count(*) from bos.jobs j join bos.bookings k on k.id = j.booking_id
                      where k.ref = :'ref1' and j.booking_version = 1 and j.status = 'queued') = 0,
  '27 old reminders / follow-ups cancelled');
select pg_temp.check((select count(*) from bos.jobs j join bos.bookings k on k.id = j.booking_id
                      where k.ref = :'ref1' and j.purpose = 'rescheduled' and j.status = 'queued') = 1,
  '28 rescheduled text queued');
select pg_temp.check((bos.dispatch('brightsmile-demo','check_availability',
  jsonb_build_object('service','Dental Check-up','date',:'mon','time','10:00'),null,'voice')->>'available')::boolean,
  '29 old slot released');

-- ---------- 8. salon (different industry, same engine) ----------
select pg_temp.check(bos.dispatch('luxe-hair-demo','book',
  jsonb_build_object('customer_name','Daniel Smith','phone','07700900444','service','haircut','date',:'sat','time','2pm'),
  'toolcall-6','website')->>'ok' = 'true', '30 salon booking on Saturday');
select pg_temp.check(bos.dispatch('luxe-hair-demo','book',
  jsonb_build_object('customer_name','Amy Lee','phone','07700900555','service','haircut','date',:'mon','time','11:00'),
  'toolcall-7','website')->>'error' = 'outside_hours', '31 salon closed Monday');

-- ---------- 9. worker: claim / render / complete ----------
update bos.businesses set test_numbers = '{+447700900111}', calendar_id = 'clinic@group.calendar.google.com'
where slug = 'brightsmile-demo';
select pg_temp.check(true, '-- worker section');
create temp table claimed as select j from bos.claim_jobs(50) j;
select pg_temp.check((select count(*) from claimed where j->>'kind' = 'sms' and j->>'to' = '+447700900111') >= 1,
  '32 SMS for allow-listed test number claimed');
select pg_temp.check((select count(*) from bos.jobs where status = 'skipped' and last_error = 'test_mode_blocked') >= 1,
  '33 test mode blocks non-test numbers');
select pg_temp.check((select j->>'body' from claimed where j->>'purpose' = 'rescheduled' limit 1) like '%moved to%',
  '34 message rendered from template', (select j from claimed where j->>'purpose' = 'rescheduled' limit 1));
select pg_temp.check((select count(*) from claimed where j->>'kind' = 'calendar' and j->>'method' = 'POST'
                      and j->>'url' like '%clinic%40group.calendar.google.com/events') >= 1, '35 calendar create request built');
select pg_temp.check((select count(*) from bos.claim_jobs(50)) = 0, '36 claimed jobs are locked (no double send)');

select (j->>'job_id')::bigint as sms_job from claimed where j->>'purpose' = 'rescheduled' limit 1 \gset
select (j->>'job_id')::bigint as cal_job from claimed where j->>'kind' = 'calendar'
  and (select booking_id from bos.jobs where id = (j->>'job_id')::bigint) = (select id from bos.bookings where ref = :'ref1') limit 1 \gset
select pg_temp.check(bos.complete_job(:sms_job, 201, '{"sid":"SM123","status":"queued"}', null)->>'status' = 'sent', '37 SMS marked sent');
select pg_temp.check(exists (select 1 from bos.messages where provider_id = 'SM123' and direction = 'out'), '38 outbound SMS logged');
select pg_temp.check(bos.complete_job(:cal_job, 200, '{"id":"evt_abc"}', null)->>'status' = 'sent', '39 calendar job marked sent');
select pg_temp.check((select google_event_id from bos.bookings where ref = :'ref1') = 'evt_abc', '40 google event id stored');

-- retry and permanent failure
select (j->>'job_id')::bigint as fail_job from claimed where j->>'kind' = 'calendar'
  and (j->>'job_id')::bigint <> :cal_job limit 1 \gset
select pg_temp.check(bos.complete_job(:fail_job, 500, '{"error":{"message":"backend"}}', null)->>'status' = 'retry', '41 5xx scheduled for retry');
select pg_temp.check((select status from bos.jobs where id = :fail_job) = 'queued'
                     and (select run_at from bos.jobs where id = :fail_job) > now(), '42 retry has back-off');

-- ---------- 10. cancel ----------
select pg_temp.check(bos.dispatch('brightsmile-demo','cancel_appointment',
  jsonb_build_object('ref',:'ref1'),'toolcall-8','voice','{"caller_phone":"07700900111"}')->>'ok' = 'true', '43 cancel ok');
select pg_temp.check((select count(*) from bos.jobs j join bos.bookings k on k.id = j.booking_id
                      where k.ref = :'ref1' and j.purpose in ('cancelled','calendar_delete') and j.status = 'queued') = 2,
  '44 cancellation text + calendar delete queued');
select pg_temp.check(bos.dispatch('brightsmile-demo','cancel',jsonb_build_object('ref',:'ref1'),'toolcall-9','dashboard','{"trusted":true}')->>'message'
                     like '%already cancelled%', '45 cancel is idempotent');
create temp table claimed2 as select j from bos.claim_jobs(50) j;
select pg_temp.check((select count(*) from claimed2 where j->>'method' = 'DELETE' and j->>'url' like '%/events/evt_abc') = 1,
  '46 calendar delete targets the stored event');

-- ---------- 11. inbound SMS ----------
select bos.dispatch('brightsmile-demo','book',
  jsonb_build_object('customer_name','Emma Thompson','phone','07700900111','service','Consultation','date',:'tue','time','15:00'),
  'toolcall-10','sms') as r10 \gset
select pg_temp.check((:'r10'::jsonb)->>'ok' = 'true', '47 second booking for SMS tests', :'r10'::jsonb);
select bos.inbound_sms('+447700900001','+447700900111','c','SMa1') as in1 \gset
select pg_temp.check((:'in1'::jsonb)->>'action' = 'reply' and (:'in1'::jsonb)#>>'{sms,body}' like 'Thanks Emma%', '48 "C" confirms the next booking', :'in1'::jsonb);
select pg_temp.check((select status from bos.bookings where ref = (:'r10'::jsonb)#>>'{booking,ref}') = 'confirmed', '49 booking status confirmed');
select pg_temp.check(bos.inbound_sms('+447700900001','+447700900111','c','SMa1')->>'reason' = 'duplicate', '50 duplicate webhook ignored');
select bos.inbound_sms('+447700900001','+447700900111','Hi, can I move it to Wednesday afternoon?','SMa2') as in2 \gset
select pg_temp.check((:'in2'::jsonb)->>'action' = 'agent' and (:'in2'::jsonb)->>'system_prompt' like '%Consultation on%',
  '51 free text goes to AI agent with booking context');
select bos.inbound_sms('+447700900001','+447700900999','STOP','SMa3') as in3 \gset
select pg_temp.check((:'in3'::jsonb)->>'reason' = 'opted_out'
                     and (select sms_opt_out from bos.customers where phone = '+447700900999'), '52 STOP opts out');
select pg_temp.check(bos.inbound_sms('+440000000000','+447700900111','hi','SMa4')->>'reason' = 'unknown_number', '53 unknown business number ignored');
-- the agent's tool call, exactly as n8n sends it (caller phone from Twilio, not from the AI)
select pg_temp.check(bos.dispatch('11111111-1111-4111-8111-111111111111','reschedule',
  jsonb_build_object('date',:'tue','time','16:00'),'SMa2:reschedule','sms','{"caller_phone":"+447700900111"}')->>'ok' = 'true',
  '54 SMS agent reschedule scoped to the sender');
select pg_temp.check(bos.dispatch('11111111-1111-4111-8111-111111111111','cancel',
  jsonb_build_object('ref',(:'r10'::jsonb)#>>'{booking,ref}'),'SMx:cancel','sms','{"caller_phone":"+447700900222"}')->>'error' = 'verification_failed',
  '55 another texter cannot cancel someone else''s booking');

-- ---------- 12. calls + dashboard ----------
select bos.dispatch(null,'record_call',
  '{"call_id":"call_1","call_type":"inboundPhoneCall","customer_phone":"+447700900111","started_at":"2026-01-01T10:00:00Z","ended_at":"2026-01-01T10:03:30Z","summary":"Booked"}',
  null,'vapi_event','{"assistant_id":"asst_demo_1"}') as rc \gset
select pg_temp.check((:'rc'::jsonb)->>'ok' = 'true'
  and (select duration_s from bos.calls where provider_call_id = 'call_1') = 210
  and (select customer_id from bos.calls where provider_call_id = 'call_1') is not null, '56 call report stored and linked to customer', :'rc'::jsonb);
select pg_temp.check(bos.dispatch('brightsmile-demo','set_status',jsonb_build_object('ref',(:'r10'::jsonb)#>>'{booking,ref}','status','completed'),
  'dash-1','voice')->>'error' = 'forbidden', '57 staff-only action refused for callers');
select pg_temp.check(bos.dispatch('brightsmile-demo','set_status',jsonb_build_object('ref',(:'r10'::jsonb)#>>'{booking,ref}','status','completed'),
  'dash-1','dashboard','{"trusted":true}')->>'ok' = 'true', '58 dashboard can complete a booking');
select pg_temp.check((select count(*) from bos.errors) = 0, '59 no unexpected internal errors logged',
  (select jsonb_agg(e) from bos.errors e));

\echo ALL_TESTS_PASSED
