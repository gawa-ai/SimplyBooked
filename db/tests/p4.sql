-- Phase 4 tests: replies, classification, responses, demos, meetings, calendar queue. THROWAWAY DB only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;

insert into auth.users (email) values ('own@p4.test'), ('mem@p4.test'), ('vie@p4.test'), ('own@p4b.test'), ('mem@p4b.test');
select id as uo from auth.users where email = 'own@p4.test' \gset
select id as um from auth.users where email = 'mem@p4.test' \gset
select id as uv from auth.users where email = 'vie@p4.test' \gset
select id as ub from auth.users where email = 'own@p4b.test' \gset
select id as umb from auth.users where email = 'mem@p4b.test' \gset
select acq.create_organization('P4 Org', 'p4-org', 'own@p4.test') as o \gset
select acq.create_organization('P4 Other', 'p4-other', 'own@p4b.test') as ob \gset
insert into acq.profiles (id, org_id, email, role) values (:'um', :'o', 'mem@p4.test', 'member'), (:'uv', :'o', 'vie@p4.test', 'viewer'), (:'umb', :'ob', 'mem@p4b.test', 'member');
select id as src from acq.lead_sources where org_id = :'o' and key = 'manual' \gset

-- org configured the way an owner would
update acq.organizations set outreach_enabled = true where id = :'o';
insert into acq.system_settings (org_id, key, value) values
  (:'o', 'sender', '{"from_name":"Jay at BookingOS","from_email":"jay@send.p4.example.co","postal_address":"1 Example Street, London, EC1A 1AA, UK","reply_to_email":"jay@p4.example.co"}'),
  (:'o', 'tracking_base_url', '"https://track.example.co/functions/v1/acq-track"'),
  (:'o', 'send_window', '{"tz":"UTC","start":"00:00","end":"23:59","days":[0,1,2,3,4,5,6]}')
on conflict (org_id, key) do update set value = excluded.value;
update acq.system_settings set value = '0' where org_id = :'o' and key = 'min_send_gap_seconds';
update acq.system_settings set value = '{"email":50,"sms":0}' where org_id = :'o' and key = 'daily_send_limit';
update acq.system_settings set value = '5' where org_id = :'o' and key = 'per_domain_daily_limit';
update acq.system_settings set value = '{"duration_min":30,"tz":"Europe/London","hours":{"0":["10:00","12:00"],"1":["09:00","17:00"],"2":["09:00","17:00"],"3":["09:00","17:00"],"4":["09:00","17:00"],"5":["09:00","17:00"],"6":["10:00","12:00"]},"min_notice_min":60,"max_days_ahead":90,"slot_step_min":30,"calendar_id":"sales@group.calendar.google.com"}'
  where org_id = :'o' and key = 'meeting';

-- helper: a lead that has really been contacted (approved message + sent), email on its own domain
create or replace function t.contacted(p_org uuid, p_src uuid, p_member uuid, p_name text, p_email text, p_pid text) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into acq.leads (org_id, source_id, business_name, email, website, niche, city, country_code, score)
  values (p_org, p_src, p_name, p_email, 'https://' || split_part(p_email, '@', 2), 'dentist', 'Bristol', 'GB', 80) returning leads.id into v_id;
  update acq.leads set status = 'qualified' where leads.id = v_id;
  insert into acq.outreach_messages (org_id, lead_id, kind, channel, step, to_address, from_address, subject, body, status, approval_status, approval_source,
                                     approved_by, approved_at, generated_by, provider, provider_message_id, sent_at, idempotency_key)
  values (p_org, v_id, 'outreach', 'email', 0, p_email, 'jay@send.p4.example.co', 'Hello ' || p_name, 'Hi, we help practices never miss a call. Open to a demo?', 'sent', 'approved', 'user',
          p_member, now(), 'ai', 'resend', p_pid, now() - interval '1 hour', 'seed:' || v_id);
  update acq.leads set status = 'approved' where leads.id = v_id;
  update acq.leads set status = 'contacted' where leads.id = v_id;
  return v_id;
end $$;

-- ---------- A. reply intake ----------
select t.contacted(:'o', :'src', :'um', 'Clifton Dental', 'info@clifton-dental.example.co', '4f7a9c20-1b3d-4e5f-8a6b-7c8d9e0f1a2b') as l1 \gset
select t.contacted(:'o', :'src', :'um', 'Redland Smiles', 'hello@redland-smiles.example.co', 're_a2') as l2 \gset
insert into acq.followups (org_id, lead_id, step, channel, due_at) values (:'o', :'l1', 1, 'email', now() + interval '3 days');

select t.check(acq.ingest_reply('nobody@elsewhere.example', 'info@clifton-dental.example.co', 'Re: hi', 'Yes please', 'in-0')->>'reason' = 'unknown_recipient', 'A1 mail to an address we do not own is ignored');
select acq.ingest_reply('Jay <jay+tag123@p4.example.co>', 'Clifton Dental <info@clifton-dental.example.co>', 'Re: Hello Clifton Dental', E'Hi Jay, this sounds interesting. Can you tell me more about pricing?\n\nOn Mon, 5 Oct 2026 at 10:00, Jay <jay@send.p4.example.co> wrote:\n> Not interested? Unsubscribe here: https://x', 'in-1') as a2 \gset
select t.check((:'a2'::jsonb->>'action') = 'stored' and (:'a2'::jsonb->>'matched')::boolean and (:'a2'::jsonb->>'classification') = 'unclassified', 'A2 reply to the reply-to address (plus-tag + display name) is stored and matched by sender', :'a2');
select t.check((select status from acq.leads where id = :'l1') = 'replied' and (select last_reply_at is not null from acq.leads where id = :'l1'), 'A3 first reply moves the lead to Replied');
select t.check((select status from acq.followups where lead_id = :'l1') = 'cancelled', 'A4 pending follow-ups stop on reply');
select t.check((select count(*) from acq.pipeline_events where lead_id = :'l1' and to_status = 'replied' and reason = 'reply_received' and actor_type = 'n8n') = 1, 'A5 pipeline event attributed to automation with a reason');
select t.check(acq.ingest_reply('jay@p4.example.co', 'info@clifton-dental.example.co', 'Re: Hello Clifton Dental', 'Sounds good', 'in-1')->>'action' = 'duplicate', 'A6 provider retry of the same inbound email is a duplicate');
select t.check((select count(*) from acq.replies where provider_message_id = 'in-1') = 1, 'A6b exactly one reply row');
select acq.ingest_reply('jay@p4.example.co', 'receptionist@gmail.com', 'Re: Hello', 'Forwarded to the owner', 'in-2', '<4f7a9c20-1b3d-4e5f-8a6b-7c8d9e0f1a2b@mail.resend.example>') as a7 \gset
select t.check((:'a7'::jsonb->>'matched')::boolean
               and (select message_id is not null from acq.replies where provider_message_id = 'in-2'), 'A7 In-Reply-To containing our provider message id matches a forwarded reply', (select to_jsonb(r) from acq.replies r where provider_message_id = 'in-2'));
select t.check((acq.ingest_reply('jay@p4.example.co', 'reception@clifton-dental.example.co', 'Re: Hello', 'Hi from reception', 'in-3')->>'matched')::boolean, 'A8 same business domain (unambiguous, not free-mail) matches');
select acq.ingest_reply('jay@p4.example.co', 'someone@gmail.com', 'Hello', 'Do you do whitening?', 'in-4') as a9 \gset
select t.check(not (:'a9'::jsonb->>'matched')::boolean
               and (select count(*) from acq.replies where provider_message_id = 'in-4' and match_status = 'unmatched' and lead_id is null) = 1, 'A9 unknown free-mail sender stays unmatched (kept for triage)');

-- out-of-office must NOT count as a reply (follow-ups continue)
insert into acq.followups (org_id, lead_id, step, channel, due_at) values (:'o', :'l2', 1, 'email', now() + interval '3 days');
select acq.ingest_reply('jay@p4.example.co', 'hello@redland-smiles.example.co', 'Automatic reply: Hello', 'I am out of the office until Monday.', 'in-5', null, null, '{"Auto-Submitted":"auto-replied"}') as a10 \gset
select t.check((:'a10'::jsonb->>'classification') = 'out_of_office' and (select status from acq.leads where id = :'l2') = 'contacted' and (select status from acq.followups where lead_id = :'l2') = 'scheduled',
  'A10 auto-reply is classified by rules and does not stop the sequence', :'a10');
select t.check(acq.ingest_reply('jay@p4.example.co', 'MAILER-DAEMON@mx.example.org', 'Undelivered Mail Returned to Sender', 'Delivery has failed', 'in-6')->>'reason' = 'bounce_notice', 'A11 bounce notices are not replies');

-- "remove me" is acted on immediately; but quoted history (our own footer says "Unsubscribe") must never trigger it
select acq.ingest_reply('jay@p4.example.co', 'hello@redland-smiles.example.co', 'Re: Hello', E'Sounds good, let''s talk next week.\n\nOn Mon, 5 Oct 2026 at 10:00, Jay <jay@send.p4.example.co> wrote:\n> Not interested? Unsubscribe here: https://x\n> Please remove me from your list if...', 'in-7') as a12 \gset
select t.check((:'a12'::jsonb->>'classification') = 'unclassified'
               and (select not do_not_contact and status = 'replied' from acq.leads where id = :'l2'), 'A12 quoted footer text ("Unsubscribe") does not unsubscribe the sender');
select t.contacted(:'o', :'src', :'um', 'Bishopston Dental', 'team@bishopston-dental.example.co', 're_a3') as l3 \gset
select acq.ingest_reply('jay@p4.example.co', 'team@bishopston-dental.example.co', 'Re: Hello', 'Please remove me from your list and do not contact us again.', 'in-8') as a13 \gset
select t.check((:'a13'::jsonb->>'classification') = 'unsubscribe' and (select do_not_contact and status = 'lost' and dnc_reason = 'unsubscribe' from acq.leads where id = :'l3')
               and exists (select 1 from acq.suppressions where org_id = :'o' and kind = 'email' and value = 'team@bishopston-dental.example.co'), 'A13 clear opt-out in the reply suppresses the lead immediately', :'a13');
select t.check((select classified_by from acq.replies where provider_message_id = 'in-8') = 'rules' and (select handled_at is not null from acq.replies where provider_message_id = 'in-8'), 'A14 rule-classified and marked handled');
-- flood guard
insert into acq.replies (org_id, match_status, channel, from_address, body, classification, provider_message_id)
select :'o', 'unmatched', 'email', 'spammer@flood.example.co', 'x', 'unclassified', 'flood-' || g from generate_series(1, 20) g;
select t.check(acq.ingest_reply('jay@p4.example.co', 'spammer@flood.example.co', 's', 'again', 'in-9')->>'reason' = 'flood', 'A15 one sender cannot flood the inbox');
-- a lead that was never contacted can write to us; it is stored but the pipeline does not jump
insert into acq.leads (org_id, source_id, business_name, email, website, country_code) values (:'o', :'src', 'Never Contacted Dental', 'hi@never-contacted.example.co', 'https://never-contacted.example.co', 'GB') returning id as lnc \gset
select acq.ingest_reply('jay@p4.example.co', 'hi@never-contacted.example.co', 'Hello', 'Found your address online, are you hiring?', 'in-10') as a16 \gset
select t.check((:'a16'::jsonb->>'matched')::boolean and (select status from acq.leads where id = :'lnc') = 'new_lead', 'A16 inbound from a never-contacted lead is stored and matched without moving the pipeline');

-- ---------- B. classification ----------
update acq.replies set classification = 'unclassified', classify_attempts = 0, classify_locked_until = null where provider_message_id = 'in-1';
select id as r1 from acq.replies where provider_message_id = 'in-1' \gset
create temp table claimed_replies as select c from acq.claim_replies_for_classification(10) c;
select t.check((select count(*) from claimed_replies where c->>'reply_id' = :'r1') = 1 and (select count(*) from claimed_replies) >= 3, 'B1 unclassified replies are handed to the classifier');
select t.check((select count(*) from acq.claim_replies_for_classification(10) c where c->>'reply_id' = :'r1') = 0, 'B2 claimed replies are locked');
select t.check((select c->>'business_name' = 'Clifton Dental' and c->>'our_subject' = 'Hello Clifton Dental' and (c->>'text') not like '%wrote:%' and (c->>'text') not like '%Unsubscribe%' and c->>'model' = 'gpt-5-mini'
                from claimed_replies where c->>'reply_id' = :'r1'), 'B3 classifier context: lead, our original message, and only the fresh text of the reply (quoted history removed)');
select t.check(t.err($q$select acq.apply_classification('$q$ || :'r1' || $q$', '{"classification":"hot_lead"}')$q$) = 'P0001', 'B4 unknown label rejected');
select acq.apply_classification(:'r1', '{"classification":"question","confidence":0.92,"summary":"Asks about pricing","suggested_response":"Hi, thanks for getting back to me. Plans start from a simple monthly fee and I can walk you through exact pricing in a short call. Would Thursday suit you?"}', 'gpt-5-mini') as b5 \gset
select t.check((:'b5'::jsonb->>'suggestion_pending')::boolean and (select classification = 'question' and response_status = 'pending_approval' and classification_confidence = 0.92 from acq.replies where id = :'r1')
               and (select status from acq.leads where id = :'l1') = 'replied', 'B5 labelled; suggested answer waits for a person (nothing sent)', :'b5');
select t.check(acq.apply_classification(:'r1', '{"classification":"positive"}')->>'note' = 'already question', 'B6 classifying twice is harmless');
select id as r7 from acq.replies where provider_message_id = 'in-7' \gset
select acq.apply_classification(:'r7', '{"classification":"positive","summary":"Wants to talk","suggested_response":"Great, see my calendar at https://evil.example/book for times that suit you."}') as b7 \gset
select t.check((select classification = 'positive' and suggested_response is null and response_status = 'none' and summary like '%suggested reply dropped%' from acq.replies where id = :'r7'), 'B7 a suggested reply containing a link is dropped, the label is kept');
select id as r4 from acq.replies where provider_message_id = 'in-4' \gset
select acq.apply_classification(:'r4', '{"classification":"question","suggested_response":"Yes, we do whitening at our practice. Would you like to book a consultation this week?"}') as b8 \gset
select t.check((select suggested_response is null and match_status = 'unmatched' from acq.replies where id = :'r4'), 'B8 no suggested answer for an unmatched reply (a person must match it first)');
select id as r2 from acq.replies where provider_message_id = 'in-2' \gset
select acq.apply_classification(:'r2', '{"classification":"not_interested","summary":"Declines"}') as b9 \gset
select t.check((select do_not_contact and status = 'lost' and dnc_reason = 'negative_reply' from acq.leads where id = :'l1'), 'B9 negative / not-interested reply stops all contact');
select acq.classification_failed(:'r4', 'openai_http_429') as b10 \gset
select t.check(:'b10'::jsonb->>'ok' = 'true' and (select classify_error = 'openai_http_429' and classify_locked_until > now() from acq.replies where id = :'r4'), 'B10 classifier failure is recorded with back-off');
update acq.replies set classification = 'unclassified', classify_attempts = 3, classify_locked_until = null where id = :'r4';
select t.check((select count(*) from acq.claim_replies_for_classification(10) c where c->>'reply_id' = :'r4') = 0, 'B11 gives up after 3 attempts (left for a human)');

-- ---------- C. approving a suggested response ----------
select t.contacted(:'o', :'src', :'um', 'Fishponds Dental', 'office@fishponds-dental.example.co', 're_c1') as lc \gset
select acq.ingest_reply('jay@p4.example.co', 'office@fishponds-dental.example.co', 'Re: Hello Fishponds Dental', 'Yes, interested. How much is it?', 'in-c1') as c0 \gset
select (:'c0'::jsonb->>'reply_id')::uuid as rc \gset
select acq.apply_classification(:'rc', '{"classification":"question","suggested_response":"Hi, thanks for replying. Pricing depends on call volume, and I can show you exact numbers in a 20 minute call. Would Thursday work?"}') as c1 \gset
set role authenticated; select t.as_user(:'uv'::uuid);
select t.check(t.err($q$select acq.approve_reply_response('$q$ || :'rc' || $q$')$q$) = '42501', 'C1 viewer cannot approve a response');
select t.as_user(:'umb'::uuid);
select t.check(t.err($q$select acq.approve_reply_response('$q$ || :'rc' || $q$')$q$) = 'P0001', 'C2 another org''s member cannot see or approve it');
select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.edit_reply_response('$q$ || :'rc' || $q$', 'Hi [name], see {link}')$q$) = 'P0001', 'C3 placeholders are rejected when editing');
select acq.edit_reply_response(:'rc', 'Hi, thanks for replying. Pricing depends on how many calls you get, and I can show exact numbers in a 20 minute call. Would Thursday afternoon work for you?') as c4 \gset
select acq.approve_reply_response(:'rc') as c5 \gset
reset role;
select t.check((:'c5'::jsonb->>'ok')::boolean and (select kind = 'reply' and status = 'approved' and approval_source = 'user' and approved_by = :'um' and to_address = 'office@fishponds-dental.example.co' and subject = 'Re: Hello Fishponds Dental'
                from acq.outreach_messages where id = (:'c5'::jsonb->>'message_id')::uuid), 'C5 approval queues a normal approved message to the person who wrote', :'c5');
select t.check((select response_status = 'approved' and response_message_id is not null and handled_at is not null from acq.replies where id = :'rc'), 'C6 reply shows the response as approved');
set role authenticated; select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.approve_reply_response('$q$ || :'rc' || $q$')$q$) = 'P0001', 'C7 cannot approve twice');
reset role;
select acq.claim_outbound(5) as cs \gset
select t.check((:'cs'::jsonb->>'message_id') = (:'c5'::jsonb->>'message_id') and (:'cs'::jsonb#>>'{headers,List-Unsubscribe-Post}') = 'List-Unsubscribe=One-Click' and (:'cs'::jsonb->>'to') = 'office@fishponds-dental.example.co', 'C8 the sender picks it up like any approved message (unsubscribe headers included)', :'cs');
select acq.complete_outbound((:'cs'::jsonb->>'message_id')::uuid, 200, '{"id":"re_c_resp"}') as c9 \gset
select t.check((select response_status from acq.replies where id = :'rc') = 'sent' and (select status from acq.leads where id = :'lc') = 'replied', 'C9 once really sent the reply shows Sent; the lead stays Replied');
-- do-not-contact wins over an approved response
select acq.ingest_reply('jay@p4.example.co', 'office@fishponds-dental.example.co', 'Re: Re: Hello', 'Great, Thursday works. Tell me more about onboarding.', 'in-c2') as c10 \gset
select (:'c10'::jsonb->>'reply_id')::uuid as rc2 \gset
select acq.apply_classification(:'rc2', '{"classification":"positive","suggested_response":"Wonderful, onboarding takes about a week and we set everything up for you. Does 10am Thursday work for a call?"}') as c11 \gset
update acq.leads set do_not_contact = true where id = :'lc';
set role authenticated; select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.approve_reply_response('$q$ || :'rc2' || $q$')$q$) = 'P0001', 'C10 a do-not-contact lead cannot be answered');
reset role;

-- ---------- D. demos ----------
select t.contacted(:'o', :'src', :'um', 'Demo Dental', 'info@demo-dental.example.co', 're_d1') as ld \gset
select acq.ingest_reply('jay@p4.example.co', 'info@demo-dental.example.co', 'Re: Hello', 'Interested, can you show me?', 'in-d1') as d0 \gset
set role authenticated; select t.as_user(:'uv'::uuid);
select t.check(t.err($q$select acq.create_demo('$q$ || :'ld' || $q$')$q$) = '42501', 'D1 viewer cannot create demos');
select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.create_demo('$q$ || :'ld' || $q$', null, '{"script":"x"}')$q$) = 'P0001', 'D2 unknown config field rejected');
select t.check(t.err($q$select acq.create_demo('$q$ || :'ld' || $q$', null, '{"headline":"<script>alert(1)</script>"}')$q$) = 'P0001', 'D3 markup in demo text rejected (plain text only)');
select acq.create_demo(:'ld', 'Demo for Demo Dental', '{"headline":"Never miss a patient call","bullets":["Answers 24/7","Books into your diary"],"faqs":[{"q":"Does it work with my diary?","a":"Yes, it books into Google Calendar."}]}') as d1 \gset
select acq.create_demo(:'ld') as d1b \gset
reset role;
select t.check((:'d1'::jsonb->>'ok')::boolean and not (:'d1'::jsonb->>'existing')::boolean and (:'d1'::jsonb->>'url') is null, 'D4 demo created (no public URL until demo_base_url is set)', :'d1');
select t.check((:'d1b'::jsonb->>'existing')::boolean and (:'d1b'::jsonb->>'demo_id') = (:'d1'::jsonb->>'demo_id'), 'D5 one active demo per lead (second call returns it)');
select (:'d1'::jsonb->>'demo_id')::uuid as dm \gset
select token as dtok from acq.demos where id = :'dm' \gset
select t.check(length(:'dtok') = 64 and (select config->>'cta_text' = 'Book a short walkthrough' and jsonb_array_length(config->'bullets') = 2 and config->>'business_name' = 'Demo Dental' from acq.demos where id = :'dm'), 'D6 config merged with safe defaults; 256-bit token');
set role authenticated; select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.send_demo('$q$ || :'dm' || $q$', 'Your demo', 'Hi, here is the short demo we talked about. Let me know what you think.')$q$) = 'P0001', 'D7 cannot send until demo_base_url (https) is configured');
reset role;
update acq.system_settings set value = '"https://demo.example.co/demo"' where org_id = :'o' and key = 'demo_base_url';
set role authenticated; select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.send_demo('$q$ || :'dm' || $q$', 'Your demo', 'Hi, see https://evil.example/x for the demo we talked about, thanks.')$q$) = 'P0001', 'D8 people cannot paste links into the demo email (the system adds the real one)');
select acq.send_demo(:'dm', 'Your short demo', 'Hi, here is the short demo we talked about. Let me know what you think and when you are free for a call.') as d9 \gset
reset role;
select t.check((:'d9'::jsonb->>'ok')::boolean and (select body like '%Your short demo: https://demo.example.co/demo?d=' || :'dtok' and kind = 'reply' and approval_source = 'user' and status = 'approved'
                from acq.outreach_messages where id = (:'d9'::jsonb->>'message_id')::uuid), 'D9 demo email approved by the sender, link appended by the system', :'d9');
select t.check((select status from acq.demos where id = :'dm') = 'ready', 'D10 demo is not "sent" until the email really leaves');
select acq.claim_outbound(5) as dcl \gset
select acq.complete_outbound((:'dcl'::jsonb->>'message_id')::uuid, 200, '{"id":"re_demo_1"}') as d11 \gset
select t.check((select status = 'sent' and sent_at is not null from acq.demos where id = :'dm') and (select status from acq.leads where id = :'ld') = 'demo_sent', 'D11 sent email -> demo Sent and lead Demo Sent');
select t.check(acq.demo_view('zzz')->>'found' = 'false' and acq.demo_view(repeat('a', 64))->>'found' = 'false', 'D12 unknown / malformed tokens look identical');
select acq.demo_view(:'dtok') as v1 \gset
select t.check((:'v1'::jsonb->>'found')::boolean and (:'v1'::jsonb#>>'{config,headline}') = 'Never miss a patient call' and (select open_count = 1 and status = 'opened' and first_opened_at is not null from acq.demos where id = :'dm'), 'D13 page view tracked (opened)', :'v1');
select t.check(not (:'v1'::jsonb::text ~* '(info@demo-dental|phone|email)') and not (:'v1'::jsonb ? 'lead_id') and not (:'v1'::jsonb ? 'org_id'), 'D14 public payload exposes no lead contact details or internal ids', :'v1');
select acq.demo_click(:'dtok') as k1 \gset
select t.check((select click_count = 1 and status = 'clicked' from acq.demos where id = :'dm'), 'D15 CTA click tracked');
select acq.demo_view(:'dtok') as v2 \gset
select t.check((select open_count = 2 and status = 'clicked' from acq.demos where id = :'dm'), 'D16 status never goes backwards');

-- ---------- E. meetings ----------
select acq.meeting_slots(:'dtok') as s1 \gset
select t.check((:'s1'::jsonb->>'found')::boolean and jsonb_array_length((:'s1'::jsonb)->'slots') > 5 and (:'s1'::jsonb->>'timezone') = 'Europe/London' and (:'s1'::jsonb->>'duration_min') = '30', 'E1 slots offered in the sales-call timezone', (:'s1'::jsonb->'slots'->0)::text);
select t.check((select bool_and(((x->>'time')::time between '09:00' and '16:30' or (x->>'time')::time between '10:00' and '11:30') and (x->>'time') ~ ':(00|30)$' and (x->>'start') > to_char(now() at time zone 'UTC' + interval '59 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                from jsonb_array_elements((:'s1'::jsonb)->'slots') x), 'E2 only grid times inside opening hours, after the minimum notice');
select acq.meeting_slots(repeat('b', 64))->>'found' as s_bad \gset
select t.check(:'s_bad' = 'false', 'E3 slots for an unknown token reveal nothing');
-- DST: across the 90-day horizon (UK clocks change 25 Oct) local times stay on the grid
select t.check((select count(*) from acq.meeting_slot_list(:'o', (now() at time zone 'Europe/London')::date, 60, 1000) s
                where to_char(s.starts_at at time zone 'Europe/London', 'HH24:MI') !~ '^(09|1[0-6]):(00|30)$' and to_char(s.starts_at at time zone 'Europe/London', 'HH24:MI') not in ('10:00','10:30','11:00','11:30')) = 0
               and (select count(*) from acq.meeting_slot_list(:'o', (now() at time zone 'Europe/London')::date, 60, 1000)) > 50, 'E4 DST-safe: no slot drifts off the local grid');
select (:'s1'::jsonb->'slots'->2->>'start')::timestamptz as slot1 \gset
select acq.book_meeting(:'dtok', :'slot1'::timestamptz, 'Dr Demo', 'drdemo@demo-dental.example.co', '07700 900123', 'Prefers mornings') as e5 \gset
select t.check((:'e5'::jsonb->>'ok')::boolean, 'E5 booking through the public token', :'e5');
select t.check((select status = 'scheduled' and source = 'demo_booking' and attendee_email = 'drdemo@demo-dental.example.co' and ends_at = starts_at + interval '30 minutes' and calendar_sync = 'pending' and notes like '%Phone: 07700 900123%'
                from acq.meetings where demo_id = :'dm'), 'E6 meeting stored with attendee details and a pending calendar sync');
select t.check((select status from acq.demos where id = :'dm') = 'booked' and (select status from acq.leads where id = :'ld') = 'meeting_booked' and (select meeting_id is not null from acq.demos where id = :'dm'), 'E7 demo Booked and lead Meeting Booked');
select acq.book_meeting(:'dtok', :'slot1'::timestamptz, 'Dr Demo', 'drdemo@demo-dental.example.co') as e8 \gset
select t.check((:'e8'::jsonb->>'error') = 'already_booked', 'E8 a demo link books one call; asking again returns the existing one', :'e8');
select t.check(acq.meeting_slots(:'dtok')::text not like '%' || to_char(:'slot1'::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '%', 'E9 a booked time is no longer offered');
-- a second prospect cannot take the same time
select t.contacted(:'o', :'src', :'um', 'Second Dental', 'info@second-dental.example.co', 're_e1') as l5 \gset
insert into acq.demos (org_id, lead_id, status, config) values (:'o', :'l5', 'ready', '{}') returning token as dtok2 \gset
select t.check(t.err($q$select acq.book_meeting('$q$ || :'dtok2' || $q$', '$q$ || :'slot1' || $q$'::timestamptz, 'Second', 'second@second-dental.example.co')$q$) = 'P0001', 'E10 the same time cannot be booked twice');
select t.check(t.err($q$select acq.book_meeting('$q$ || :'dtok2' || $q$', now() + interval '3 days 3 minutes', 'Second', 'second@second-dental.example.co')$q$) = 'P0001', 'E11 off-grid times rejected (cannot invent a slot)');
select t.check(t.err($q$select acq.book_meeting('$q$ || :'dtok2' || $q$', now() - interval '1 day', 'Second', 'second@second-dental.example.co')$q$) = 'P0001', 'E12 past times rejected');
select t.check(t.err($q$select acq.book_meeting('$q$ || :'dtok2' || $q$', '$q$ || (:'s1'::jsonb->'slots'->4->>'start') || $q$'::timestamptz, 'S', 'not-an-email')$q$) = 'P0001', 'E13 bad name / email rejected');
select t.check(acq.book_meeting('not-a-token', now() + interval '3 days', 'X Y', 'x@y.example')->>'found' = 'false', 'E14 unknown token books nothing');

-- calendar sync queue (earlier phases left other meetings in the queue, so pick ours by id)
select id as mt1 from acq.meetings where demo_id = :'dm' \gset
create or replace function t.claim_cal(p_meeting uuid) returns jsonb language sql as $$ select c from acq.claim_meeting_calendar(50) c where c->>'meeting_id' = p_meeting::text $$;
select t.claim_cal(:'mt1') as cc \gset
select t.check((:'cc'::jsonb->>'method') = 'POST' and (:'cc'::jsonb->>'url') like 'https://www.googleapis.com/calendar/v3/calendars/sales%40group.calendar.google.com/events?sendUpdates=all&conferenceDataVersion=1'
               and (:'cc'::jsonb#>>'{body,attendees,0,email}') = 'drdemo@demo-dental.example.co' and (:'cc'::jsonb#>>'{body,start,timeZone}') = 'Europe/London'
               and (:'cc'::jsonb#>>'{body,conferenceData,createRequest,conferenceSolutionKey,type}') = 'hangoutsMeet', 'E15 calendar create request: encoded calendar id, invite + Meet link, local start with timezone', :'cc');
select t.check((select count(*) from acq.claim_meeting_calendar(5) c where c->>'meeting_id' = :'mt1') = 0, 'E16 claimed meetings are locked');
select acq.complete_meeting_calendar(:'mt1', (:'cc'::jsonb->>'version')::int, 500, '{"error":{"message":"backend error"}}') as e17 \gset
select t.check((:'e17'::jsonb->>'status') = 'retry' and (select calendar_sync = 'pending' and calendar_locked_until > now() from acq.meetings where id = :'mt1'), 'E17 5xx -> retry with back-off (not lost)');
select t.check(t.claim_cal(:'mt1') is null, 'E17b back-off is honoured: not claimed again immediately');
update acq.meetings set calendar_locked_until = null where id = :'mt1';
select t.claim_cal(:'mt1') as cc2 \gset
select acq.complete_meeting_calendar(:'mt1', (:'cc2'::jsonb->>'version')::int, 200, '{"id":"evt_demo_1","hangoutLink":"https://meet.google.com/abc-defg-hij"}') as e18 \gset
select t.check((select google_event_id = 'evt_demo_1' and calendar_sync = 'synced' and meeting_url = 'https://meet.google.com/abc-defg-hij' from acq.meetings where id = :'mt1'), 'E18 event id and Meet link stored; synced');
-- cancel -> delete the same event
set role authenticated; select t.as_user(:'um'::uuid);
select acq.cancel_meeting(:'mt1', 'Prospect asked to cancel') as e19 \gset
reset role;
select t.claim_cal(:'mt1') as cc3 \gset
select t.check((:'cc3'::jsonb->>'method') = 'DELETE' and (:'cc3'::jsonb->>'url') like '%/events/evt_demo_1?sendUpdates=all', 'E19 cancelling a meeting deletes the stored calendar event');
select acq.complete_meeting_calendar(:'mt1', (:'cc3'::jsonb->>'version')::int, 410, '{}') as e20 \gset
select t.check((select google_event_id is null and calendar_sync = 'synced' from acq.meetings where id = :'mt1'), 'E20 event already gone (410) counts as success');
select t.check(acq.meeting_slots(:'dtok')::text like '%' || to_char(:'slot1'::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '%', 'E21 a cancelled meeting frees the time');
-- staff scheduling
set role authenticated; select t.as_user(:'um'::uuid);
select acq.schedule_meeting(:'l5', now() + interval '5 days', 45, 'Intro call', 'phone', 'Second Dentist', 'second@second-dental.example.co', 'Call on 07700 900999') as e22 \gset
select t.check((:'e22'::jsonb->>'ok')::boolean and (select ends_at = starts_at + interval '45 minutes' and status = 'scheduled' from acq.meetings where id = (:'e22'::jsonb->>'meeting_id')::uuid), 'E22 staff can schedule a call');
select t.check(t.err($q$select acq.schedule_meeting('$q$ || :'l5' || $q$', (select starts_at + interval '10 minutes' from acq.meetings where id = '$q$ || (:'e22'::jsonb->>'meeting_id') || $q$'), 30, 'Clash', 'phone', null, null)$q$) = 'P0001', 'E23 overlapping meetings are refused');
select t.as_user(:'uv'::uuid);
select t.check(t.err($q$select acq.schedule_meeting('$q$ || :'l5' || $q$', now() + interval '6 days', 30, 'x', 'phone', null, null)$q$) = '42501', 'E24 viewer cannot schedule');
select t.as_user(:'um'::uuid);
select t.check(t.err($q$select acq.set_meeting_outcome('$q$ || (:'e22'::jsonb->>'meeting_id') || $q$', 'completed', 'won', 'Signed on the call')$q$) = 'ok', 'E25 outcome recorded');
select t.check(t.err($q$select acq.set_meeting_outcome('$q$ || (:'e22'::jsonb->>'meeting_id') || $q$', 'finished', 'won')$q$) = 'P0001', 'E26 invalid status rejected');
reset role;
-- settings validation for the meeting config
set role authenticated; select t.as_user(:'uo'::uuid);
select t.check(t.err($q$select acq.update_setting('meeting', '{"hours":{"1":["17:00","09:00"]}}')$q$) = 'P0001' and t.err($q$select acq.update_setting('meeting', '{"tz":"Mars/Base"}')$q$) = 'P0001'
               and t.err($q$select acq.update_setting('meeting', '{"duration_min":5}')$q$) = 'P0001' and t.err($q$select acq.update_setting('meeting', '{"evil":1}')$q$) = 'P0001'
               and t.err($q$select acq.update_setting('meeting', '{"hours":{"1":["09:00","17:00"]},"duration_min":30}')$q$) = 'ok', 'E27 meeting availability settings are validated');
reset role;

-- ---------- F. privileges / invariants ----------
set role authenticated; select t.as_user(:'uo'::uuid);
select t.check(t.err($q$select acq.ingest_reply('a','b','c','d','e')$q$) = '42501' and t.err($q$select acq.demo_view('x')$q$) = '42501' and t.err($q$select acq.book_meeting('x', now(), 'a', 'b')$q$) = '42501'
  and t.err($q$select acq.meeting_slots('x')$q$) = '42501' and t.err($q$select acq.claim_meeting_calendar(1)$q$) = '42501' and t.err($q$select acq.claim_replies_for_classification(1)$q$) = '42501'
  and t.err($q$select acq.apply_classification(gen_random_uuid(), '{}')$q$) = '42501' and t.err($q$select acq.complete_meeting_calendar(gen_random_uuid(), 1, 200, '{}')$q$) = '42501', 'F1 intake / public-demo / calendar / classifier functions are service-only');
select t.check((select count(*) from acq.v_replies where org_id = :'ob') = 0 and (select count(*) from acq.v_meetings where org_id = :'ob') = 0 and (select count(*) from acq.v_replies) > 0, 'F2 reply and meeting views are scoped to the caller''s org');
set role anon;
select t.check(t.err($q$select * from acq.v_replies$q$) = '42501' and t.err($q$select acq.create_demo(gen_random_uuid())$q$) = '42501', 'F3 anon has no access');
reset role;
select t.check((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'acq'
  and p.prosecdef and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))) = 0, 'F4 every SECURITY DEFINER function pins search_path');
select t.check((select count(*) from acq.outreach_messages where status in ('queued','sending','sent','delivered','opened','clicked') and approval_status <> 'approved') = 0, 'F5 invariant: nothing sent without approval (replies and demo emails included)');
select t.check((select count(*) from acq.outreach_messages where kind = 'reply' and (approved_by is null or approval_source <> 'user')) = 0, 'F6 every reply / demo email carries a human approver');
select t.check(acq.urlenc('sales@group.calendar.google.com') = 'sales%40group.calendar.google.com' and acq.urlenc('a b/c+d') = 'a%20b%2Fc%2Bd' and acq.urlenc('é') = '%C3%A9', 'F7 URL path encoding');

\echo ALL_TESTS_PASSED_P4
