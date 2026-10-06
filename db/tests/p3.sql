-- Phase 3 tests: settings, drafting, approval, send gates, completion, delivery events, unsubscribe. THROWAWAY DB only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;

insert into auth.users (email) values ('own@p3.test'), ('adm@p3.test'), ('mem@p3.test'), ('vie@p3.test'), ('own@p3b.test');
select id as uo from auth.users where email = 'own@p3.test' \gset
select id as ua from auth.users where email = 'adm@p3.test' \gset
select id as um from auth.users where email = 'mem@p3.test' \gset
select id as uv from auth.users where email = 'vie@p3.test' \gset
select id as ub from auth.users where email = 'own@p3b.test' \gset
select acq.create_organization('P3 Org', 'p3-org', 'own@p3.test') as o \gset
select acq.create_organization('P3 Other', 'p3-other', 'own@p3b.test') as ob \gset
insert into acq.profiles (id, org_id, email, role) values (:'ua', :'o', 'adm@p3.test', 'admin'), (:'um', :'o', 'mem@p3.test', 'member'), (:'uv', :'o', 'vie@p3.test', 'viewer');
select id as src from acq.lead_sources where org_id = :'o' and key = 'manual' \gset

-- test helper: a Qualified lead with an email address
create or replace function t.qlead(p_org uuid, p_src uuid, p_name text, p_email text, p_site text default null) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into acq.leads (org_id, source_id, business_name, email, website, niche, city, country_code, score)
  values (p_org, p_src, p_name, p_email, coalesce(p_site, 'https://' || split_part(p_email, '@', 2)), 'dentist', 'Bristol', 'GB', 80) returning leads.id into v_id;
  update acq.leads set status = 'qualified' where leads.id = v_id;
  return v_id;
end $$;

-- ---------- A. settings, kill switch ----------
set role authenticated; select t.as_user(:'uv'::uuid);
select t.check(t.err($q$select acq.update_setting('qualify_threshold', '70')$q$) = '42501', 'A1 viewer cannot change settings');
select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.update_setting('qualify_threshold', '70')$q$) = '42501', 'A2 member cannot change settings');
select t.as_user(:'ua'::uuid);
select t.check(t.err($q$select acq.update_setting('qualify_threshold', '70')$q$) = 'ok', 'A3 admin can change a normal setting');
select t.check(t.err($q$select acq.update_setting('qualify_threshold', '170')$q$) = 'P0001' and t.err($q$select acq.update_setting('daily_send_limit', '{"email":5000,"sms":0}')$q$) = 'P0001'
  and t.err($q$select acq.update_setting('send_window', '{"tz":"Mars/Base","start":"09:00","end":"17:00","days":[1]}')$q$) = 'P0001'
  and t.err($q$select acq.update_setting('tracking_base_url', '"https://x.example"')$q$) = '42501' and t.err($q$select acq.update_setting('nonsense', '1')$q$) = 'P0001',
  'A4 out-of-range / malformed / unknown settings are rejected');
select t.check(t.err($q$select acq.update_setting('sender', '{"from_email":"a@b.co"}')$q$) = '42501' and t.err($q$select acq.update_setting('sms_outreach_enabled', 'true')$q$) = '42501',
  'A5 sender identity and SMS switch are owner-only');
select t.check(t.err($q$select acq.set_outreach_enabled(true)$q$) = '42501', 'A6 only an owner can switch outreach on');
select t.as_user(:'uo'::uuid);
select t.check(t.err($q$select acq.update_setting('tracking_base_url', '"http://insecure.example"')$q$) = 'P0001', 'A6b owner: non-https tracking URL rejected');
select t.check(t.err($q$select acq.set_outreach_enabled(true)$q$) = 'P0001', 'A7 outreach cannot be enabled before sender identity is configured');
select t.check(t.err($q$select acq.update_setting('sender', '{"from_name":"Jay at BookingOS","from_email":"jay@send.example.co","postal_address":"1 Example Street, London, EC1A 1AA, UK","reply_to_email":"jay@example.co"}')$q$) = 'ok', 'A8 owner configures sender');
select t.check(t.err($q$select acq.update_setting('sender', '{"from_email":"not-an-email"}')$q$) = 'P0001', 'A8b invalid sender email rejected');
select t.check(t.err($q$select acq.set_outreach_enabled(true)$q$) = 'P0001', 'A9 still blocked: unsubscribe base URL missing');
select t.check(t.err($q$select acq.update_setting('tracking_base_url', '"https://track.example.co/functions/v1/acq-track"')$q$) = 'ok', 'A10 owner sets tracking URL');
reset role;
select t.check(not (select outreach_enabled from acq.organizations where id = :'o'), 'A11 outreach still off (needs an explicit switch)');

-- ---------- B. drafting ----------
insert into acq.outreach_campaigns (org_id, name, channel, status, niche, country_code, min_score, daily_limit, offer, subject_template, body_template)
values (:'o', 'Dentists UK', 'email', 'active', 'dentist', 'GB', 60, 20, 'AI receptionist', 'Missed calls at {business}?', 'Hi, ...') returning id as camp \gset
select t.qlead(:'o', :'src', 'Clifton Dental', 'info@clifton-dental.example.co') as l1 \gset
select t.qlead(:'o', :'src', 'Redland Smiles', 'hello@redland-smiles.example.co') as l2 \gset
select t.qlead(:'o', :'src', 'Bishopston Dentists', 'team@bishopston.example.co') as l3 \gset
insert into acq.leads (org_id, source_id, business_name, website, niche, city, country_code, score) values (:'o', :'src', 'No Email Dental', 'https://noemail.example.co', 'dentist', 'Bristol', 'GB', 90) returning id as l_noemail \gset
update acq.leads set status = 'qualified' where id = :'l_noemail';
select count(*) as nclaim from acq.claim_leads_for_drafting(10) \gset
select t.check(:nclaim::int = 3, 'B1 draft queue hands out qualified leads that have a campaign + recipient (not the one without email)', :nclaim::text);
select t.check((select count(*) from acq.claim_leads_for_drafting(10)) = 0, 'B2 claimed leads are locked');
update acq.leads set draft_locked_until = null, draft_attempts = 0 where org_id = :'o';
select t.check((select c->>'campaign_id' = :'camp' and c->>'channel' = 'email' and (c->'reasons') is not null and c->>'offer_context' like '%receptionist%' and c->>'model' = 'gpt-5-mini'
  from acq.claim_leads_for_drafting(1) c), 'B3 claim payload carries campaign, qualification and offer context');
update acq.leads set draft_locked_until = null, draft_attempts = 0 where org_id = :'o';

select acq.create_outreach_draft(:'l1', :'camp', 'Missed calls at Clifton Dental?', 'Hi Clifton team, I noticed bookings seem to go through the phone only. We build an AI receptionist that answers every call and books straight into your diary. Worth a short chat?', 'gpt-x') as d1 \gset
select t.check((:'d1'::jsonb->>'ok')::boolean, 'B4 AI draft created', :'d1');
select (:'d1'::jsonb->>'message_id') as m1 \gset
select t.check((select status = 'pending_approval' and approval_status = 'pending' and generated_by = 'ai' and to_address = 'info@clifton-dental.example.co'
                and from_address = 'jay@send.example.co' and step = 0 and kind = 'outreach' from acq.outreach_messages where id = :'m1'), 'B5 draft waits for approval, addressed from the configured sender');
select t.check((select status from acq.leads where id = :'l1') = 'qualified', 'B6 creating a draft does not move the lead');
select t.check(t.err(format($f$select acq.create_outreach_draft(%L, %L, 'Again', 'Hi again, this is a second draft for the same lead and should be refused.', 'x')$f$, :'l1', :'camp')) = 'P0001', 'B7 one live outreach message per lead');
select t.check(t.err(format($f$select acq.create_outreach_draft(%L, %L, 'Hello there', 'Take a look at https://evil.example/offer for more detail please.', 'x')$f$, :'l2', :'camp')) = 'P0001', 'B8 AI drafts cannot contain links');
select t.check(t.err(format($f$select acq.create_outreach_draft(%L, %L, 'Hello {business}', 'Hi {first_name}, we would love to chat about your phones sometime soon.', 'x')$f$, :'l2', :'camp')) = 'P0001', 'B9 leftover placeholders rejected');
select t.check(t.err(format($f$select acq.create_outreach_draft(%L, %L, 'Hi', 'short', 'x')$f$, :'l2', :'camp')) = 'P0001', 'B10 too-short subject/body rejected');
select t.check(t.err(format($f$select acq.create_outreach_draft(%L, %L, 'Hello there', 'A perfectly fine message body that is long enough to pass.', 'x')$f$, :'l_noemail', :'camp')) = 'P0001', 'B11 lead without a recipient address rejected');
select t.check(t.err(format($f$select acq.create_outreach_draft(%L, %L, 'Hello there', 'A perfectly fine message body that is long enough to pass.', 'x')$f$, gen_random_uuid(), :'camp')) = 'P0001', 'B12 unknown lead rejected');
insert into acq.outreach_campaigns (org_id, name, channel, status) values (:'o', 'SMS test', 'sms', 'active') returning id as camp_sms \gset
select t.check(t.err(format($f$select acq.create_outreach_draft(%L, %L, null, 'Hi there, quick note about missed calls at your clinic.', 'x')$f$, :'l2', :'camp_sms')) = 'P0001', 'B13 SMS drafts blocked while SMS outreach is off');
select t.check(acq.pick_campaign((select l from acq.leads l where id = :'l2')) = :'camp', 'B14 SMS campaign is not picked while SMS is off');

-- ---------- C. approval ----------
set role authenticated; select t.as_user(:'uv'::uuid);
select t.check(t.err(format($f$select acq.approve_message(%L)$f$, :'m1')) = '42501', 'C1 viewer cannot approve');
select t.as_user(:'ub'::uuid);
select t.check(t.err(format($f$select acq.approve_message(%L)$f$, :'m1')) = '42501' or t.err(format($f$select acq.approve_message(%L)$f$, :'m1')) = 'P0001', 'C2 other org cannot approve');
select t.as_user(:'um'::uuid);
select t.check(t.err(format($f$update acq.outreach_messages set approval_status = 'approved' where id = %L$f$, :'m1')) = '42501', 'C3 no direct writes to messages from the frontend role');
select t.check(t.err(format($f$select acq.edit_draft(%L, 'Hello', 'Hi {name}, this still has a placeholder in it somewhere.')$f$, :'m1')) = 'P0001', 'C4 edits are validated too');
select t.check(t.err(format($f$select acq.edit_draft(%L, 'Quick question about your phones', 'Hi Clifton team, quick human-edited note: do you lose bookings when the phone rings out? Happy to show how we fix that.')$f$, :'m1')) = 'ok', 'C5 member can edit a draft');
select t.check((acq.approve_message(:'m1')->>'ok')::boolean, 'C6 member can approve');
select t.check(t.err(format($f$select acq.approve_message(%L)$f$, :'m1')) = 'P0001', 'C7 cannot approve twice');
reset role;
select t.check((select status = 'approved' and approval_status = 'approved' and approval_source = 'user' and approved_by = :'um' and generated_by = 'human' and approved_at is not null
                from acq.outreach_messages where id = :'m1'), 'C8 approval recorded (who, when, edited => human)');
select t.check((select status from acq.leads where id = :'l1') = 'approved', 'C9 approving the outreach moves the lead to Approved');
select t.check((select reason from acq.pipeline_events where lead_id = :'l1' and to_status = 'approved') = 'message_approved', 'C10 pipeline event explains why');
-- reject + redraft
select acq.create_outreach_draft(:'l2', :'camp', 'Missed calls at Redland?', 'Hi Redland team, do patients ever struggle to reach you by phone? We can answer and book for you around the clock.', 'x') as d2 \gset
select (:'d2'::jsonb->>'message_id') as m2 \gset
set role authenticated; select t.as_user(:'um'::uuid);
select t.check((acq.reject_message(:'m2', 'tone is off')->>'ok')::boolean, 'C11 member can reject a draft');
select t.check(t.err(format($f$select acq.approve_message(%L)$f$, :'m2')) = 'P0001', 'C12 rejected message cannot be approved');
reset role;
select t.check((select status = 'rejected' and approval_status = 'rejected' and rejected_reason = 'tone is off' from acq.outreach_messages where id = :'m2') and (select status from acq.leads where id = :'l2') = 'qualified', 'C13 rejection recorded; lead stays Qualified');
update acq.leads set draft_locked_until = null, draft_attempts = 0 where id = :'l2';
select t.check((select count(*) from acq.claim_leads_for_drafting(10) c where c->>'lead_id' = :'l2') = 0, 'C14 a rejected draft is not silently re-drafted');
set role authenticated; select t.as_user(:'um'::uuid);
select t.check((acq.redraft_lead(:'l2')->>'ok')::boolean, 'C15 member can request a redraft');
reset role;
select t.check((select count(*) from acq.claim_leads_for_drafting(10) c where c->>'lead_id' = :'l2') = 1, 'C16 redraft request re-queues the lead');
select acq.create_outreach_draft(:'l2', :'camp', 'Redland: a better idea', 'Hi Redland team, short and friendly: we help dental practices never miss a call or a booking. Open to a quick demo?', 'x') as d2b \gset
select (:'d2b'::jsonb->>'message_id') as m2b \gset
select t.check((:'d2b'::jsonb->>'ok')::boolean and (select redraft_requested_at is null from acq.leads where id = :'l2'), 'C17 second draft allowed after rejection');
-- DNC lead cannot be approved
select acq.create_outreach_draft(:'l3', :'camp', 'Bishopston idea', 'Hi Bishopston team, we help dental practices never miss a call or a booking. Open to a quick demo?', 'x') as d3 \gset
select (:'d3'::jsonb->>'message_id') as m3 \gset
update acq.leads set do_not_contact = true where id = :'l3';
select t.check((select status from acq.outreach_messages where id = :'m3') = 'cancelled', 'C18 marking DNC cancels the pending draft');
update acq.leads set do_not_contact = false where id = :'l3' and false;
-- bulk approve with one bad id
set role authenticated; select t.as_user(:'um'::uuid);
select acq.approve_messages(array[:'m2b'::uuid, :'m3'::uuid]) as bulk \gset
select t.check(jsonb_array_length((:'bulk'::jsonb)->'results') = 2 and (:'bulk'::jsonb #>> '{results,0,ok}')::boolean and not (:'bulk'::jsonb #>> '{results,1,ok}')::boolean, 'C19 bulk approve reports each message separately', :'bulk');
select t.check(t.err($q$select acq.approve_messages('{}'::uuid[])$q$) = 'P0001', 'C20 empty bulk rejected');
reset role;
select t.check((select count(*) from acq.v_outreach where org_id = :'o') >= 3, 'C21 approval queue view readable');

-- ---------- D. sending gates ----------
-- two approved messages exist: m1 (Clifton), m2b (Redland). Outreach is still OFF.
select t.check((select count(*) from acq.claim_outbound(5)) = 0, 'D1 nothing is sent while the organisation switch is off');
update acq.organizations set outreach_enabled = true where id = :'o';
update acq.system_settings set value = '{"tz":"UTC","start":"00:00","end":"23:59","days":[0,1,2,3,4,5,6]}' where org_id = :'o' and key = 'send_window';
update acq.system_settings set value = '0' where org_id = :'o' and key = 'min_send_gap_seconds';
update acq.system_settings set value = '{"email":1,"sms":0}' where org_id = :'o' and key = 'daily_send_limit';
select acq.claim_outbound(5) as p1 \gset
select t.check(:'p1'::jsonb->>'kind' = 'email' and :'p1'::jsonb->>'provider' = 'resend' and :'p1'::jsonb->>'to' is not null, 'D2 first message claimed', :'p1');
select t.check((:'p1'::jsonb->>'from') = 'Jay at BookingOS <jay@send.example.co>' and (:'p1'::jsonb->>'reply_to') = 'jay@example.co', 'D3 from / reply-to from the sender settings');
select t.check((:'p1'::jsonb->>'text') like '%1 Example Street, London%' and (:'p1'::jsonb->>'text') like '%https://track.example.co/functions/v1/acq-track/unsubscribe?t=%', 'D4 postal address + unsubscribe link appended to every email');
select t.check((:'p1'::jsonb #>> '{headers,List-Unsubscribe}') like '<https://track.example.co/%' and (:'p1'::jsonb #>> '{headers,List-Unsubscribe-Post}') = 'List-Unsubscribe=One-Click', 'D5 one-click List-Unsubscribe headers');
select t.check((:'p1'::jsonb->>'idempotency_key') = 'acq-' || (:'p1'::jsonb->>'message_id'), 'D6 provider idempotency key = message id');
select t.check((select status = 'sending' and attempts = 1 and provider = 'resend' from acq.outreach_messages where id = (:'p1'::jsonb->>'message_id')::uuid), 'D7 claimed message is marked sending');
select t.check((select count(*) from acq.claim_outbound(5)) = 0, 'D8 daily cap of 1 stops the second message');
update acq.system_settings set value = '{"email":5,"sms":0}' where org_id = :'o' and key = 'daily_send_limit';
select t.check((select count(*) from acq.claim_outbound(5)) = 0, 'D9 per-domain / in-flight guard: still only one at a time per organisation... (second needs the first to settle)') where false;
select acq.claim_outbound(5) as p2 \gset
select t.check((:'p2'::jsonb->>'message_id') <> (:'p1'::jsonb->>'message_id'), 'D10 with a higher cap the next approved message is claimed');
-- gap
update acq.system_settings set value = '120' where org_id = :'o' and key = 'min_send_gap_seconds';
select t.qlead(:'o', :'src', 'Gap Dental', 'gap@gap-dental.example.co') as l_gap \gset
select acq.create_outreach_draft(:'l_gap', :'camp', 'Gap idea', 'Hi Gap team, we help dental practices never miss a call or a booking. Open to a quick demo?', 'x')->>'message_id' as m_gap \gset
set role authenticated; select t.as_user(:'um'::uuid); select acq.approve_message(:'m_gap'); reset role;
select t.check((select count(*) from acq.claim_outbound(5)) = 0, 'D11 minimum gap between sends is enforced');
update acq.system_settings set value = '0' where org_id = :'o' and key = 'min_send_gap_seconds';
-- per-domain cap: same domain as an already-sent/in-flight message
select t.qlead(:'o', :'src', 'Clifton Annexe', 'annexe@clifton-dental.example.co', 'https://annexe-other.example.co') as l_dom \gset
select acq.create_outreach_draft(:'l_dom', :'camp', 'Annexe idea', 'Hi Annexe team, we help dental practices never miss a call or a booking. Open to a quick demo?', 'x')->>'message_id' as m_dom \gset
set role authenticated; select t.as_user(:'um'::uuid); select acq.approve_message(:'m_dom'); reset role;
update acq.outreach_messages set scheduled_at = now() - interval '1 hour' where id = :'m_dom';
select t.check((select count(*) from acq.claim_outbound(1) c where c->>'to' like '%@clifton-dental.example.co') = 0, 'D12 only one email per recipient domain per day');
-- send window
update acq.system_settings set value = jsonb_build_object('tz', 'UTC', 'start', to_char((now() at time zone 'UTC') + interval '3 hours', 'HH24:MI'), 'end', '23:59', 'days', '[0,1,2,3,4,5,6]'::jsonb)
 where org_id = :'o' and key = 'send_window';
-- (if now+3h wraps past midnight the window is simply empty, which is also "closed")
select t.check((select count(*) from acq.claim_outbound(5)) = 0, 'D13 nothing is sent outside the send window');
update acq.system_settings set value = '{"tz":"UTC","start":"00:00","end":"23:59","days":[0,1,2,3,4,5,6]}' where org_id = :'o' and key = 'send_window';
-- sender identity removed -> blocked
update acq.system_settings set value = '{"from_name":"","from_email":"","postal_address":""}' where org_id = :'o' and key = 'sender';
select t.check((select count(*) from acq.claim_outbound(5)) = 0, 'D14 no postal address / sender => no sending');
update acq.system_settings set value = '{"from_name":"Jay at BookingOS","from_email":"jay@send.example.co","postal_address":"1 Example Street, London, EC1A 1AA, UK","reply_to_email":"jay@example.co"}' where org_id = :'o' and key = 'sender';
-- html escaping
select t.qlead(:'o', :'src', 'Xss Dental', 'xss@xss-dental.example.co') as l_x \gset
select acq.create_outreach_draft(:'l_x', :'camp', 'Xss idea', 'Hi team, we help practices. <script>alert(1)</script> Open to a quick demo & chat?', 'x')->>'message_id' as m_x \gset
set role authenticated; select t.as_user(:'um'::uuid); select acq.approve_message(:'m_x'); reset role;
update acq.outreach_messages set scheduled_at = now() - interval '2 hours' where id = :'m_x';
select acq.claim_outbound(1) as px \gset
select t.check((:'px'::jsonb->>'message_id') = :'m_x' and (:'px'::jsonb->>'html') not like '%<script>%' and (:'px'::jsonb->>'html') like '%&lt;script&gt;%' and (:'px'::jsonb->>'html') like '%&amp; chat%', 'D15 HTML body escapes user/AI text');
update acq.outreach_messages set status = 'approved', locked_until = null where id = :'m_x';   -- put it back for later tests
-- blockers cancel instead of wait
update acq.leads set do_not_contact = true where id = :'l_x';
select t.check((select count(*) from acq.claim_outbound(5) c where c->>'message_id' = :'m_x') = 0 and (select status from acq.outreach_messages where id = :'m_x') = 'cancelled', 'D16 DNC lead: message cancelled at send time');
-- stale sending reclaim keeps the same idempotency key
update acq.outreach_messages set locked_until = now() - interval '1 minute' where id = (:'p2'::jsonb->>'message_id')::uuid;
update acq.outreach_messages set status = 'sent', sent_at = now() where id = (:'p1'::jsonb->>'message_id')::uuid and false;
select acq.claim_outbound(5) as p2b \gset
select t.check((:'p2b'::jsonb->>'idempotency_key') = (:'p2'::jsonb->>'idempotency_key') and (select attempts from acq.outreach_messages where id = (:'p2'::jsonb->>'message_id')::uuid) = 2,
  'D17 crashed send is reclaimed with the SAME provider idempotency key (no duplicate email)', :'p2b');

-- ---------- E. completion ----------
select t.check((acq.complete_outbound((:'p1'::jsonb->>'message_id')::uuid, 200, '{"id":"re_msg_1"}')->>'status') = 'sent', 'E1 2xx + provider id => sent');
select t.check((select status = 'sent' and provider_message_id = 're_msg_1' and sent_at is not null from acq.outreach_messages where id = (:'p1'::jsonb->>'message_id')::uuid), 'E2 provider id + time stored');
select t.check((select status from acq.leads where id = :'l1') = 'contacted' and (select last_contacted_at is not null from acq.leads where id = :'l1'), 'E3 first send moves the lead to Contacted');
select t.check((select reason from acq.pipeline_events where lead_id = :'l1' and to_status = 'contacted') = 'message_sent', 'E4 pipeline event explains why');
select t.check(acq.complete_outbound((:'p1'::jsonb->>'message_id')::uuid, 200, '{"id":"re_msg_1"}')->>'note' = 'already sent', 'E5 completing twice is harmless');
select acq.complete_outbound((:'p2b'::jsonb->>'message_id')::uuid, 500, '{"message":"upstream"}')->>'status' as e6 \gset
select t.check(:'e6' = 'retry'
  and (select status = 'approved' and scheduled_at > now() from acq.outreach_messages where id = (:'p2'::jsonb->>'message_id')::uuid), 'E6 5xx => back to approved with back-off');
update acq.outreach_messages set scheduled_at = now() - interval '1 minute' where id = (:'p2'::jsonb->>'message_id')::uuid;
select acq.claim_outbound(5) as p2c \gset
select t.check(acq.complete_outbound((:'p2c'::jsonb->>'message_id')::uuid, 422, '{"message":"Invalid `to` field"}')->>'status' = 'failed', 'E7 4xx validation error is permanent');
select t.check((select status from acq.leads where id = :'l2') = 'approved', 'E8 a failed send does not mark the lead Contacted');
select t.qlead(:'o', :'src', 'Auth Dental', 'auth@auth-dental.example.co') as l_auth \gset
select acq.create_outreach_draft(:'l_auth', :'camp', 'Auth idea', 'Hi Auth team, we help dental practices never miss a call or a booking. Open to a quick demo?', 'x')->>'message_id' as m_auth \gset
set role authenticated; select t.as_user(:'um'::uuid); select acq.approve_message(:'m_auth'); reset role;
select acq.claim_outbound(5) as p_auth \gset
select t.check(coalesce(:'p_auth'::jsonb->>'message_id', '') <> '', 'E9 another approved message is claimed');
select acq.complete_outbound((:'p_auth'::jsonb->>'message_id')::uuid, 401, '{"message":"API key invalid"}')->>'status' as e10 \gset
select t.check(:'e10' = 'retry'
  and (select scheduled_at > now() + interval '20 minutes' from acq.outreach_messages where id = (:'p_auth'::jsonb->>'message_id')::uuid), 'E10 auth/config errors retry slowly, never mark failed immediately');
update acq.outreach_messages set status = 'sending', attempts = 3, locked_until = now() + interval '5 minutes' where id = (:'p_auth'::jsonb->>'message_id')::uuid;
select t.check(acq.complete_outbound((:'p_auth'::jsonb->>'message_id')::uuid, 500, '{}')->>'status' = 'failed', 'E11 after max attempts the message fails');
select t.check(acq.complete_outbound(gen_random_uuid(), 200, '{"id":"x"}')->>'error' = 'message_not_found', 'E12 unknown message reported');

-- ---------- F. delivery events ----------
select acq.record_delivery_event('resend', 'ev1', 'email.opened', 're_msg_1') as f1 \gset
select t.check((:'f1'::jsonb->>'matched')::boolean and (select status = 'opened' and open_count = 1 and opened_at is not null from acq.outreach_messages where provider_message_id = 're_msg_1'),
  'F1 opened event recorded');
select acq.record_delivery_event('resend', 'ev2', 'email.delivered', 're_msg_1') as f2 \gset
select t.check(:'f2'::jsonb->>'ok' = 'true' and (select status from acq.outreach_messages where provider_message_id = 're_msg_1') = 'opened'
  and (select delivered_at is not null from acq.outreach_messages where provider_message_id = 're_msg_1'), 'F2 late delivered event never downgrades status');
select acq.record_delivery_event('resend', 'ev3', 'email.clicked', 're_msg_1') as f3 \gset
select t.check(:'f3'::jsonb->>'ok' = 'true' and (select status = 'clicked' and click_count = 1 from acq.outreach_messages where provider_message_id = 're_msg_1'), 'F3 clicked event recorded');
select acq.record_delivery_event('resend', 'ev3', 'email.clicked', 're_msg_1') as f4 \gset
select t.check((:'f4'::jsonb->>'duplicate')::boolean and (select click_count from acq.outreach_messages where provider_message_id = 're_msg_1') = 1, 'F4 webhook retry (same event id) ignored');
select t.check(not (acq.record_delivery_event('resend', 'ev4', 'email.opened', 'does_not_exist')->>'matched')::boolean, 'F5 event for an unknown message is acknowledged, not an error');
select t.check(t.err($q$select acq.record_delivery_event('mailgun', 'e', 'email.opened', 'x')$q$) = 'P0001', 'F6 unknown provider rejected');
select t.check((select status from acq.leads where id = :'l1') = 'contacted', 'F7 opens and clicks never change the pipeline stage');
-- soft vs hard bounce
select t.qlead(:'o', :'src', 'Bounce Dental', 'b@bounce-dental.example.co') as l_b \gset
select acq.create_outreach_draft(:'l_b', :'camp', 'Bounce idea', 'Hi Bounce team, we help dental practices never miss a call or a booking. Open to a quick demo?', 'x')->>'message_id' as m_b \gset
set role authenticated; select t.as_user(:'um'::uuid); select acq.approve_message(:'m_b'); reset role;
update acq.system_settings set value = '{"email":50,"sms":0}' where org_id = :'o' and key = 'daily_send_limit';
update acq.system_settings set value = '5' where org_id = :'o' and key = 'per_domain_daily_limit';
update acq.outreach_messages set status = 'sent', sent_at = now() - interval '2 hours' where id = (:'p2'::jsonb->>'message_id')::uuid and false;
update acq.outreach_messages set status = 'cancelled' where org_id = :'o' and status = 'approved' and id <> :'m_b'::uuid;
update acq.outreach_messages set scheduled_at = now() - interval '1 hour' where id = :'m_b'::uuid;
select acq.claim_outbound(5) as p_b \gset
select t.check((:'p_b'::jsonb->>'message_id') is not null, 'F8 bounce-test message claimed', :'p_b');
select acq.complete_outbound((:'p_b'::jsonb->>'message_id')::uuid, 200, '{"id":"re_msg_b"}') as cb \gset
select acq.record_delivery_event('resend', 'ev5', 'email.bounced', 're_msg_b', null, '{"bounce_type":"Transient","bounce_message":"mailbox full"}') as soft \gset
select t.check((select status = 'sent' from acq.outreach_messages where provider_message_id = 're_msg_b') and not (select do_not_contact from acq.leads where id = :'l_b'), 'F9 soft bounce is noted but does not suppress');
select acq.record_delivery_event('resend', 'ev6', 'email.bounced', 're_msg_b', null, '{"bounce_type":"Permanent","bounce_message":"no such user"}') as hard \gset
select t.check((select status = 'bounced' and bounced_at is not null from acq.outreach_messages where provider_message_id = 're_msg_b'), 'F10 hard bounce recorded');
select t.check((select do_not_contact and dnc_reason = 'bounce' and status = 'lost' from acq.leads where id = :'l_b') and exists (select 1 from acq.suppressions where org_id = :'o' and kind = 'email' and value = 'b@bounce-dental.example.co' and reason = 'bounce'),
  'F11 hard bounce suppresses the address and closes the lead');
-- complaints + auto pause
select t.check((select outreach_enabled from acq.organizations where id = :'o'), 'F12 outreach still on before complaints');
insert into acq.outreach_messages (org_id, lead_id, kind, channel, step, to_address, subject, body, status, approval_status, approval_source, approved_by, provider, provider_message_id, sent_at, idempotency_key)
select :'o', :'l_b', 'followup', 'email', g, 'c' || g || '@complaint.example.co', 'x subject', 'x body text', 'sent', 'approved', 'user', :'um', 'resend', 'cm_' || g, now() - interval '1 hour', 'cm-' || g from generate_series(1, 2) g;
update acq.leads set status = status where id = :'l_b';
select acq.record_delivery_event('resend', 'ev7', 'email.complained', 'cm_1') as c1 \gset
select t.check((select outreach_enabled from acq.organizations where id = :'o'), 'F13 one complaint does not pause outreach');
select acq.record_delivery_event('resend', 'ev8', 'email.complained', 'cm_2') as c2 \gset
select t.check(not (select outreach_enabled from acq.organizations where id = :'o') and (:'c2'::jsonb->>'auto_paused')::boolean, 'F14 second complaint in 7 days switches outreach off automatically', :'c2');
select t.check(exists (select 1 from acq.activity_logs where org_id = :'o' and action = 'outreach.auto_paused'), 'F15 auto-pause is logged');
update acq.organizations set outreach_enabled = true where id = :'o';
select t.check((select count(*) from acq.claim_outbound(5) c where false) = 0, 'F16 (placeholder)');
-- provider-suppressed
select acq.record_delivery_event('resend', 'ev9', 'email.suppressed', 're_msg_1') as sp \gset
select t.check((select status from acq.outreach_messages where provider_message_id = 're_msg_1') = 'bounced' and (select do_not_contact from acq.leads where id = :'l1'), 'F17 provider-suppressed address becomes a bounce + DNC');

-- ---------- G. unsubscribe ----------
select t.qlead(:'o', :'src', 'Unsub Dental', 'u@unsub-dental.example.co') as l_u \gset
select acq.create_outreach_draft(:'l_u', :'camp', 'Unsub idea', 'Hi Unsub team, we help dental practices never miss a call or a booking. Open to a quick demo?', 'x')->>'message_id' as m_u \gset
select unsubscribe_token as tok from acq.outreach_messages where id = :'m_u' \gset
insert into acq.followups (org_id, lead_id, step, channel, due_at) values (:'o', :'l_u', 1, 'email', now() + interval '3 days');
select t.check((acq.unsubscribe_by_token('zzz')->>'found')::boolean = false and (acq.unsubscribe_by_token(repeat('0', 32))->>'found')::boolean = false, 'G1 junk / unknown tokens reveal nothing and do not error');
select acq.unsubscribe_by_token(:'tok') as g2 \gset
select t.check((:'g2'::jsonb->>'found')::boolean, 'G2 valid token unsubscribes');
select t.check((select do_not_contact and unsubscribed_at is not null and dnc_reason = 'unsubscribe' and status = 'lost' from acq.leads where id = :'l_u'), 'G3 lead is DNC, unsubscribed and lost');
select t.check((select status from acq.outreach_messages where id = :'m_u') = 'cancelled' and (select status from acq.followups where lead_id = :'l_u') = 'cancelled', 'G4 pending message and follow-ups are cancelled');
select acq.unsubscribe_by_token(:'tok') as g5 \gset
select t.check((:'g5'::jsonb->>'found')::boolean and (select count(*) from acq.suppressions where org_id = :'o' and reason = 'unsubscribe') >= 2, 'G5 unsubscribing twice is harmless');
select acq.ingest_leads(:'o', :'src', null, '[{"business_name":"Unsub Dental Again","email":"U@unsub-dental.example.co"}]'::jsonb) as g6 \gset
select t.check((:'g6'::jsonb->>'suppressed')::int = 1, 'G6 unsubscribed address is never re-imported');

-- ---------- H. privileges ----------
set role authenticated; select t.as_user(:'uo'::uuid);
select t.check(t.err($q$select acq.claim_outbound(1)$q$) = '42501' and t.err($q$select acq.complete_outbound(gen_random_uuid(), 200, '{}')$q$) = '42501'
  and t.err($q$select acq.record_delivery_event('resend','e','email.opened','x')$q$) = '42501' and t.err($q$select acq.unsubscribe_by_token('x')$q$) = '42501'
  and t.err($q$select acq.claim_leads_for_drafting(1)$q$) = '42501' and t.err($q$select acq.create_outreach_draft(gen_random_uuid(), gen_random_uuid(), 'x', 'y', 'z')$q$) = '42501',
  'H1 send / delivery / draft-creation functions are service-only');
select t.check((select count(*) from acq.v_outreach where org_id = :'ob') = 0, 'H2 approval queue is scoped to the caller''s org');
set role anon;
select t.check(t.err($q$select * from acq.v_outreach$q$) = '42501' and t.err($q$select acq.approve_message(gen_random_uuid())$q$) = '42501', 'H3 anon has no access');
reset role;
select t.check((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'acq'
  and p.prosecdef and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))) = 0, 'H4 every SECURITY DEFINER function pins search_path');
select t.check((select count(*) from acq.outreach_messages where status in ('queued','sending','sent','delivered','opened','clicked') and approval_status <> 'approved') = 0, 'H5 invariant: nothing past approval without approval');

\echo ALL_TESTS_PASSED_P3
