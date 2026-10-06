-- =====================================================================
-- ACQ Phase 5: follow-up engine, client onboarding, daily digest, maintenance, dashboard metrics.
-- Non-destructive and re-runnable. Requires 020-023.
--   * Follow-ups: chain-scheduled (step N+1 is scheduled only when step N was really SENT), drafted by AI into
--     pending_approval (or auto-approved ONLY when the org turned followups_require_approval off AND the first message
--     was approved by a person). Stops on reply / unsubscribe / bounce / complaint / meeting / won / lost.
--   * Won -> client record + onboarding checklist (trigger) with validated receptionist / FAQ / booking / integration config.
--   * Daily digest (internal email to the org's own team) and housekeeping.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Follow-up engine
-- ---------------------------------------------------------------------

alter table acq.followups add column if not exists last_error text;

-- followup_steps entries: { "delay_days": 1-60, "hint": optional angle for the AI, max 200 chars }
create or replace function acq.valid_followup_steps(p jsonb)
returns boolean language sql immutable as $$
  select case when jsonb_typeof(p) = 'array' and jsonb_array_length(p) <= 6 then
    not exists (
      select 1 from jsonb_array_elements(p) e
      where jsonb_typeof(e) <> 'object'
         or coalesce(e->>'delay_days', '') !~ '^[0-9]{1,2}$'
         or (e->>'delay_days')::int not between 1 and 60
         or (e ? 'hint' and (jsonb_typeof(e->'hint') <> 'string' or length(e->>'hint') > 200)))
  else false end
$$;

-- When a message is SENT, schedule the next follow-up step; when a follow-up draft dies, close its row.
create or replace function acq.tg_outreach_followups() returns trigger language plpgsql security definer set search_path = '' as $$
declare c acq.outreach_campaigns; nxt int; d int; maxs int; l acq.leads;
begin
  if new.kind = 'followup' and new.followup_id is not null and new.status in ('rejected', 'cancelled', 'failed') and old.status is distinct from new.status then
    update acq.followups set status = 'cancelled', cancel_reason = left('message_' || new.status, 200)
     where id = new.followup_id and status in ('drafting', 'drafted');
  end if;
  if new.status in ('bounced', 'complained') and old.status is distinct from new.status then
    perform acq.stop_followups(new.lead_id, 'delivery_' || new.status);
  end if;

  if new.status = 'sent' and old.status is distinct from 'sent' and new.kind in ('outreach', 'followup') and new.campaign_id is not null then
    nxt := coalesce(new.step, 0) + 1;
    select * into c from acq.outreach_campaigns where id = new.campaign_id and org_id = new.org_id;
    if c.id is null or c.status <> 'active' then return new; end if;
    maxs := least(greatest(acq.setting_int(new.org_id, 'followup_max_steps', 3), 0), 5);
    if nxt > maxs or nxt > jsonb_array_length(c.followup_steps) then return new; end if;
    select * into l from acq.leads where id = new.lead_id;
    if l.id is null or l.do_not_contact then return new; end if;
    d := (c.followup_steps -> (nxt - 1) ->> 'delay_days')::int;
    insert into acq.followups (org_id, lead_id, campaign_id, step, channel, due_at)
    values (new.org_id, new.lead_id, c.id, nxt, c.channel, coalesce(new.sent_at, now()) + make_interval(days => d))
    on conflict (lead_id, step) do nothing;
  end if;
  return new;
end $$;

create or replace trigger tg_outreach_followups after update of status on acq.outreach_messages
  for each row execute function acq.tg_outreach_followups();

-- n8n: due follow-ups -> context for the AI. Every hard rule is re-checked here; anything that no longer applies is cancelled, not drafted.
create or replace function acq.claim_followups_for_drafting(p_limit int default 3)
returns setof jsonb language plpgsql as $$
declare f acq.followups; l acq.leads; c acq.outreach_campaigns; reason text; prev jsonb; q acq.lead_qualification; hint text;
begin
  for f in
    select x.* from acq.followups x join acq.organizations o on o.id = x.org_id and o.status = 'active' and o.outreach_enabled
    where x.status in ('scheduled', 'drafting') and x.due_at <= now() and (x.locked_until is null or x.locked_until < now())
    order by x.due_at limit least(greatest(p_limit, 1), 10) for update of x skip locked
  loop
    select * into l from acq.leads where id = f.lead_id;
    select * into c from acq.outreach_campaigns where id = f.campaign_id and org_id = f.org_id;
    reason := case
      when l.id is null then 'lead_gone'
      when l.do_not_contact then 'do_not_contact'
      when acq.is_suppressed(l.org_id, l.email, l.phone_e164, l.domain) then 'suppressed'
      when l.status <> 'contacted' then 'lead_' || l.status
      when c.id is null or c.status <> 'active' then 'campaign_inactive'
      when f.step > least(acq.setting_int(f.org_id, 'followup_max_steps', 3), 5) then 'over_step_cap'
      when f.step > jsonb_array_length(c.followup_steps) then 'step_removed'
      when exists (select 1 from acq.outreach_messages m where m.lead_id = l.id and m.status in ('bounced', 'complained')) then 'delivery_problem'
      when exists (select 1 from acq.meetings m where m.lead_id = l.id and m.status = 'scheduled') then 'meeting_booked'
      when f.channel = 'email' and l.email is null then 'no_recipient'
      when f.channel = 'sms' and (l.phone_e164 is null or not acq.setting_bool(f.org_id, 'sms_outreach_enabled', false)) then 'no_recipient'
      when exists (select 1 from acq.outreach_messages m where m.lead_id = l.id and m.step = f.step and m.status not in ('rejected', 'cancelled', 'failed')) then 'already_drafted'
      end;
    if reason is not null then
      update acq.followups set status = 'cancelled', cancel_reason = reason, locked_until = null where id = f.id;
      continue;
    end if;
    if f.attempts >= 3 then
      update acq.followups set status = 'skipped', cancel_reason = 'draft_failed', locked_until = null where id = f.id;
      continue;
    end if;
    update acq.followups set status = 'drafting', attempts = attempts + 1, locked_until = now() + interval '10 minutes' where id = f.id;
    select jsonb_agg(jsonb_build_object('step', m.step, 'subject', m.subject, 'body', left(m.body, 1200), 'sent_at', m.sent_at) order by m.step) into prev
      from acq.outreach_messages m where m.lead_id = l.id and m.kind in ('outreach', 'followup') and m.status in ('sent', 'delivered', 'opened', 'clicked');
    select * into q from acq.lead_qualification where lead_id = l.id and is_current;
    hint := left(coalesce(c.followup_steps -> (f.step - 1) ->> 'hint', ''), 200);
    return next jsonb_build_object('followup_id', f.id, 'lead_id', l.id, 'org_id', l.org_id, 'campaign_id', c.id, 'channel', f.channel, 'step', f.step,
      'total_steps', least(acq.setting_int(f.org_id, 'followup_max_steps', 3), jsonb_array_length(c.followup_steps)),
      'step_hint', hint, 'previous_messages', coalesce(prev, '[]'::jsonb),
      'business_name', l.business_name, 'category', l.category, 'niche', l.niche, 'city', l.city, 'country_code', l.country_code,
      'pain_points', coalesce(to_jsonb(q.pain_points), '[]'::jsonb), 'recommended_offer', q.recommended_offer,
      'campaign_offer', c.offer,
      'sender_name', acq.setting(l.org_id, 'sender', '{}'::jsonb) ->> 'from_name',
      'offer_context', acq.setting(l.org_id, 'offer_context', '""'::jsonb) #>> '{}',
      'model', coalesce(acq.setting(l.org_id, 'ai', '{}'::jsonb) ->> 'model', 'gpt-5-mini'));
  end loop;
end $$;

create or replace function acq.followup_failed(p_followup uuid, p_error text)
returns jsonb language plpgsql as $$
declare f acq.followups;
begin
  select * into f from acq.followups where id = p_followup for update;
  if f.id is null or f.status <> 'drafting' then return jsonb_build_object('ok', false, 'error', 'not_drafting'); end if;
  update acq.followups set status = 'scheduled', last_error = left(coalesce(p_error, 'failed'), 300),
         locked_until = now() + make_interval(mins => 10 * greatest(f.attempts, 1)) where id = f.id;
  return jsonb_build_object('ok', true);
end $$;

-- n8n: store the AI's follow-up as a draft. Pending approval unless the org opted into auto-approval AND a person approved the first message.
create or replace function acq.create_followup_draft(p_followup uuid, p_subject text, p_body text, p_model text default null)
returns jsonb language plpgsql as $$
declare f acq.followups; l acq.leads; c acq.outreach_campaigns; err text; to_addr text; s jsonb; mid uuid; auto boolean; subj text := nullif(btrim(coalesce(p_subject, '')), '');
begin
  select * into f from acq.followups where id = p_followup for update;
  if f.id is null then perform acq.fail('followup_not_found', 'Follow-up not found.'); end if;
  if f.status <> 'drafting' then perform acq.fail('not_drafting', 'This follow-up is not waiting for a draft (it is ' || f.status || ').'); end if;
  select * into l from acq.leads where id = f.lead_id for update;
  select * into c from acq.outreach_campaigns where id = f.campaign_id and org_id = f.org_id and status = 'active';
  if c.id is null then perform acq.fail('campaign_not_found', 'Campaign not found or not active.'); end if;
  if l.do_not_contact or acq.is_suppressed(l.org_id, l.email, l.phone_e164, l.domain) then perform acq.fail('do_not_contact', 'This lead must not be contacted.'); end if;
  if l.status <> 'contacted' then perform acq.fail('lead_not_contacted', 'Follow-ups only go to leads still in Contacted.'); end if;
  if f.channel = 'sms' and not acq.setting_bool(l.org_id, 'sms_outreach_enabled', false) then perform acq.fail('sms_disabled', 'SMS outreach is disabled for this organisation.'); end if;
  to_addr := case f.channel when 'email' then l.email else l.phone_e164 end;
  if to_addr is null then perform acq.fail('no_recipient', 'The lead has no ' || f.channel || ' address.'); end if;
  err := acq.check_draft(f.channel, subj, p_body, true);
  if err is not null then perform acq.fail('invalid_draft', err); end if;
  if exists (select 1 from acq.outreach_messages where lead_id = l.id and step = f.step and status not in ('rejected', 'cancelled', 'failed')) then
    perform acq.fail('draft_exists', 'This step already has a live message.');
  end if;

  auto := not acq.setting_bool(l.org_id, 'followups_require_approval', true)
          and exists (select 1 from acq.outreach_messages m where m.lead_id = l.id and m.step = 0 and m.approval_status = 'approved'
                      and m.approval_source = 'user' and m.approved_by is not null and m.status in ('sent', 'delivered', 'opened', 'clicked'));
  s := acq.setting(l.org_id, 'sender', '{}'::jsonb);
  insert into acq.outreach_messages (org_id, lead_id, campaign_id, followup_id, kind, channel, step, to_address, from_address, reply_to, subject, body,
                                     status, approval_status, approval_source, approved_at, scheduled_at, generated_by, ai_model, idempotency_key)
  values (l.org_id, l.id, c.id, f.id, 'followup', f.channel, f.step, to_addr,
          case f.channel when 'email' then nullif(s->>'from_email', '') else nullif(s->>'sms_from', '') end,
          nullif(coalesce(s->>'reply_to_email', s->>'from_email'), ''),
          case when f.channel = 'email' then subj end, btrim(p_body),
          case when auto then 'approved' else 'pending_approval' end, case when auto then 'approved' else 'pending' end,
          case when auto then 'auto_followup' end, case when auto then now() end, case when auto then now() end,
          'ai', left(p_model, 80), 'followup:' || f.id || ':' || f.attempts)
  returning id into mid;
  update acq.followups set status = 'drafted', message_id = mid, locked_until = null, last_error = null where id = f.id;
  if auto then
    perform acq.activity(l.org_id, 'followup.auto_approved', 'outreach_messages', mid::text, l.id, jsonb_build_object('step', f.step), 'system');
  end if;
  return jsonb_build_object('ok', true, 'message_id', mid, 'auto_approved', auto);
end $$;

-- user RPCs (member+)
create or replace function acq.cancel_lead_followups(p_lead uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); n int;
begin
  if not exists (select 1 from acq.leads where id = p_lead and org_id = o) then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  n := acq.stop_followups(p_lead, 'manual');
  return jsonb_build_object('ok', true, 'cancelled', n);
end $$;

create or replace function acq.skip_followup(p_followup uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); f acq.followups;
begin
  select * into f from acq.followups where id = p_followup and org_id = o for update;
  if f.id is null then perform acq.fail('followup_not_found', 'Follow-up not found.'); end if;
  if f.status not in ('scheduled', 'drafting', 'drafted') then perform acq.fail('not_active', 'This follow-up is already ' || f.status || '.'); end if;
  update acq.followups set status = 'skipped', cancel_reason = 'manual', locked_until = null where id = f.id;
  update acq.outreach_messages set status = 'cancelled', last_error = 'followup_skipped'
   where id = f.message_id and status in ('draft', 'pending_approval', 'approved');
  return jsonb_build_object('ok', true);
end $$;

create or replace function acq.set_followup_due(p_followup uuid, p_due timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); n int;
begin
  if p_due is null or p_due < now() or p_due > now() + interval '60 days' then perform acq.fail('invalid_due', 'Pick a time within the next 60 days.'); end if;
  update acq.followups set due_at = p_due where id = p_followup and org_id = o and status = 'scheduled';
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('followup_not_found', 'Only scheduled follow-ups can be moved.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace view acq.v_followups with (security_invoker = true) as
select f.id, f.org_id, f.lead_id, l.business_name, l.status as lead_status, f.campaign_id, c.name as campaign_name, f.step, f.channel, f.due_at,
       f.status, f.cancel_reason, f.message_id, m.status as message_status, f.attempts, f.last_error
from acq.followups f
left join acq.leads l on l.id = f.lead_id and l.org_id = f.org_id
left join acq.outreach_campaigns c on c.id = f.campaign_id and c.org_id = f.org_id
left join acq.outreach_messages m on m.id = f.message_id and m.org_id = f.org_id;

-- ---------------------------------------------------------------------
-- B. Client onboarding (Won -> client + checklist + validated AI-receptionist configuration)
-- ---------------------------------------------------------------------

create or replace function acq.onboarding_template()
returns table (key text, title text, description text, category text, sort_order int, due_days int)
language sql immutable as $$
  select * from (values
    ('kickoff_call',          'Kick-off call',                         'Confirm goals, go-live date, who the main contact is, and what a "good week" looks like.',                'kickoff',      10, 2),
    ('collect_business_info', 'Collect business details',              'Address, phone, parking, payment methods, cancellation policy, languages spoken.',                       'discovery',    20, 3),
    ('collect_services',      'Collect services, prices and durations','Every bookable service with duration, buffer time and price text. Feeds the booking engine.',          'discovery',    30, 3),
    ('collect_hours_staff',   'Collect opening hours and staff',       'Weekly opening hours (incl. lunch breaks) and which staff / rooms can take which service.',               'discovery',    40, 3),
    ('collect_faqs',          'Collect FAQs and policies',             'Questions callers really ask, with answers the receptionist may give. Nothing medical or legal.',          'discovery',    50, 5),
    ('receptionist_persona',  'Set receptionist persona and greeting', 'Name, tone, languages, greeting, after-hours message and escalation number.',                              'configuration', 60, 5),
    ('booking_rules',         'Confirm booking rules',                 'Minimum notice, how far ahead people can book, slot interval, reschedule / cancel policy.',               'configuration', 70, 5),
    ('connect_calendar',      'Connect Google Calendar',               'Share the business calendar with the connected Google account and record the calendar id (reference only).', 'integration', 80, 6),
    ('connect_sms',           'Set up the SMS number',                 'Provision / port the sender number so confirmations and reminders can go out. Record the number only.',    'integration',  90, 6),
    ('provision_receptionist','Provision the AI receptionist',         'Create the booking business from the validated configuration (test mode ON) and attach the voice assistant.', 'integration', 100, 7),
    ('website_voice_button',  'Install the website voice button',      'Add the voice widget to the client website (public key only) and check microphone permissions.',          'integration', 110, 8),
    ('test_calls',            'Run the end-to-end test',               'Book, reschedule and cancel by phone and website; confirm SMS and calendar events; check the error log is empty.', 'testing', 120, 9),
    ('staff_walkthrough',     'Walk the team through the system',      'Show staff how bookings, confirmations and the calendar behave and who to call for help.',               'testing',     130, 10),
    ('go_live_review',        'Go-live review (turn test mode off)',   'Final sign-off with the client. Only after this can the client be marked Active.',                        'launch',      140, 11),
    ('week1_check',           'Week-1 check-in',                       'Review calls and bookings from the first week; fix wrong answers; adjust FAQs.',                          'launch',      150, 18),
    ('review_request',        'Ask for a review / testimonial',        'Once the client is happy, ask for a review we may quote (with their permission).',                        'launch',      160, 35)
  ) t(key, title, description, category, sort_order, due_days)
$$;

-- Internal: idempotent client creation from a Won lead (no caller role check; called by the Won trigger and by convert_lead_to_client).
create or replace function acq.create_client_from_lead(p_lead uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare l acq.leads; cid uuid; tz text;
begin
  select * into l from acq.leads where id = p_lead;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  tz := coalesce(nullif(acq.setting(l.org_id, 'meeting', '{}'::jsonb) ->> 'tz', ''), 'Europe/London');
  insert into acq.clients (org_id, lead_id, business_name, email, phone, website, industry, status, won_at,
                           business_details, receptionist_config, booking_requirements, faqs, integrations)
  values (l.org_id, l.id, l.business_name, l.email, coalesce(l.phone_e164, l.phone), l.website, coalesce(l.niche, l.category), 'onboarding', coalesce(l.won_at, now()),
          jsonb_strip_nulls(jsonb_build_object('address', l.address, 'city', l.city, 'region', l.region, 'country_code', l.country_code)),
          jsonb_build_object('receptionist_name', 'Sophie', 'tone', 'friendly', 'languages', jsonb_build_array('en')),
          jsonb_build_object('timezone', tz, 'slot_interval_min', 15, 'min_notice_min', 60, 'max_days_ahead', 60),
          '[]'::jsonb,
          jsonb_build_object('calendar', jsonb_build_object('provider', 'google', 'status', 'pending'),
                             'sms', jsonb_build_object('provider', 'twilio', 'status', 'pending'),
                             'voice', jsonb_build_object('provider', 'vapi', 'status', 'pending'),
                             'website', jsonb_build_object('status', 'pending')))
  on conflict (lead_id) where lead_id is not null do nothing
  returning id into cid;
  if cid is null then
    select id into cid from acq.clients where lead_id = l.id and org_id = l.org_id;
    return cid;       -- already converted: leave the existing client and its checklist alone
  end if;
  insert into acq.onboarding_tasks (org_id, client_id, key, title, description, category, sort_order, due_at)
  select l.org_id, cid, t.key, t.title, t.description, t.category, t.sort_order, now() + make_interval(days => t.due_days)
  from acq.onboarding_template() t
  on conflict (client_id, key) do nothing;
  perform acq.activity(l.org_id, 'client.created', 'clients', cid::text, l.id, jsonb_build_object('from', 'won_lead'));
  return cid;
end $$;

create or replace function acq.tg_leads_won() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform acq.create_client_from_lead(new.id);
  return new;
end $$;
create or replace trigger tg_leads_won after update of status on acq.leads
  for each row when (new.status = 'won' and old.status is distinct from 'won') execute function acq.tg_leads_won();

create or replace function acq.convert_lead_to_client(p_lead uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); l acq.leads; cid uuid;
begin
  select * into l from acq.leads where id = p_lead and org_id = o for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  if l.status <> 'won' then
    perform set_config('acq.reason', 'converted_to_client', true);
    update acq.leads set status = 'won' where id = l.id;      -- the pipeline guard decides whether this move is legal
    perform set_config('acq.reason', '', true);
  end if;
  cid := acq.create_client_from_lead(l.id);
  return jsonb_build_object('ok', true, 'client_id', cid);
end $$;

create or replace function acq.tg_onboarding_task_done() returns trigger language plpgsql as $$
begin
  if new.status in ('done', 'skipped') then new.completed_at := coalesce(old.completed_at, now());
  else new.completed_at := null; end if;
  return new;
end $$;
create or replace trigger tg_onboarding_task_done before update of status on acq.onboarding_tasks
  for each row execute function acq.tg_onboarding_task_done();

-- ---- validation of client configuration sections (plain data only; no credentials, no markup)
create or replace function acq.valid_hhmm(p text) returns boolean language sql immutable as $$
  select coalesce(p, '') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
$$;

create or replace function acq.validate_client_section(p_section text, p_val jsonb)
returns text language plpgsql stable as $$
declare k text; e jsonb; i jsonb; lim int;
begin
  if length(p_val::text) > 20000 then return 'too large'; end if;
  case p_section
    when 'business_details' then
      if jsonb_typeof(p_val) <> 'object' then return 'must be an object'; end if;
      for k, e in select key, value from jsonb_each(p_val) loop
        if k not in ('address','city','region','country_code','phone','parking','payment_methods','cancellation_policy','languages','notes') then return 'unknown field ' || k; end if;
        if jsonb_typeof(e) = 'string' then
          if length(e #>> '{}') > 1000 or (e #>> '{}') ~ '[<>]' then return k || ' must be plain text up to 1000 characters'; end if;
        elsif jsonb_typeof(e) = 'array' then
          if jsonb_array_length(e) > 20 or exists (select 1 from jsonb_array_elements(e) x where jsonb_typeof(x) <> 'string' or length(x #>> '{}') > 100 or (x #>> '{}') ~ '[<>]') then return k || ' must be up to 20 short text items'; end if;
        else return k || ' must be text'; end if;
      end loop;
    when 'receptionist_config' then
      if jsonb_typeof(p_val) <> 'object' then return 'must be an object'; end if;
      for k, e in select key, value from jsonb_each(p_val) loop
        if k not in ('receptionist_name','tone','languages','greeting','after_hours_message','escalation_phone','notes','voice') then return 'unknown field ' || k; end if;
        if k = 'tone' then
          if jsonb_typeof(e) <> 'string' or (e #>> '{}') not in ('friendly','professional','casual') then return 'tone must be friendly, professional or casual'; end if;
        elsif k = 'languages' then
          if jsonb_typeof(e) <> 'array' or jsonb_array_length(e) > 5 or exists (select 1 from jsonb_array_elements(e) x where jsonb_typeof(x) <> 'string' or (x #>> '{}') !~ '^[a-z]{2,3}(-[A-Za-z]{2,4})?$') then return 'languages must be up to 5 language codes'; end if;
        elsif k = 'escalation_phone' then
          if jsonb_typeof(e) <> 'string' or (e #>> '{}') !~ '^\+[1-9][0-9]{7,14}$' then return 'escalation_phone must be E.164'; end if;
        else
          lim := case k when 'receptionist_name' then 40 when 'voice' then 60 when 'notes' then 1000 else 300 end;   -- (a CASE inside IF would end the IF at its first THEN)
          if jsonb_typeof(e) <> 'string' or length(e #>> '{}') > lim or (e #>> '{}') ~ '[<>]' then return k || ' must be plain text within its length limit'; end if;
          if k = 'receptionist_name' and length(btrim(e #>> '{}')) < 1 then return 'receptionist_name is empty'; end if;
        end if;
      end loop;
    when 'booking_requirements' then
      if jsonb_typeof(p_val) <> 'object' then return 'must be an object'; end if;
      for k, e in select key, value from jsonb_each(p_val) loop
        if k not in ('timezone','hours','services','staff','slot_interval_min','min_notice_min','max_days_ahead','notes') then return 'unknown field ' || k; end if;
        if k = 'timezone' then
          if jsonb_typeof(e) <> 'string' or not exists (select 1 from pg_timezone_names where name = e #>> '{}') then return 'unknown timezone'; end if;
        elsif k = 'hours' then
          if jsonb_typeof(e) <> 'object' then return 'hours must be an object keyed 0-6 (0 = Sunday)'; end if;
          if exists (select 1 from jsonb_object_keys(e) d where d !~ '^[0-6]$') then return 'hours keys must be 0-6'; end if;
          for k, i in select key, value from jsonb_each(e) loop
            -- ["09:00","17:00"] or [["09:00","13:00"],["14:00","17:00"]]
            if jsonb_typeof(i) <> 'array' or jsonb_array_length(i) = 0 or jsonb_array_length(i) > 4 then return 'hours[' || k || '] must be one or more open periods'; end if;
            if jsonb_typeof(i -> 0) = 'string' then
              if jsonb_array_length(i) <> 2 or not acq.valid_hhmm(i ->> 0) or not acq.valid_hhmm(i ->> 1) or (i ->> 0) >= (i ->> 1) then return 'hours[' || k || '] must be ["HH:MM","HH:MM"] with start before end'; end if;
            else
              if exists (select 1 from jsonb_array_elements(i) x where jsonb_typeof(x) <> 'array' or jsonb_array_length(x) <> 2 or not acq.valid_hhmm(x ->> 0) or not acq.valid_hhmm(x ->> 1) or (x ->> 0) >= (x ->> 1)) then return 'hours[' || k || '] periods must be ["HH:MM","HH:MM"] with start before end'; end if;
            end if;
          end loop;
          k := 'hours';
        elsif k = 'services' then
          if jsonb_typeof(e) <> 'array' or jsonb_array_length(e) > 30 then return 'services must be a list of up to 30'; end if;
          for i in select value from jsonb_array_elements(e) loop
            if jsonb_typeof(i) <> 'object' or exists (select 1 from jsonb_object_keys(i) x where x not in ('name','duration_min','buffer_min','price_text','description')) then return 'each service may only have name, duration_min, buffer_min, price_text, description'; end if;
            if jsonb_typeof(i -> 'name') <> 'string' or length(btrim(i ->> 'name')) not between 1 and 80 or (i ->> 'name') ~ '[<>]' then return 'service name must be 1-80 characters'; end if;
            if jsonb_typeof(i -> 'duration_min') <> 'number' or (i ->> 'duration_min') !~ '^[0-9]{1,3}$' or (i ->> 'duration_min')::int not between 5 and 480 then return 'duration_min must be 5-480'; end if;
            if i ? 'buffer_min' and (jsonb_typeof(i -> 'buffer_min') <> 'number' or (i ->> 'buffer_min') !~ '^[0-9]{1,3}$' or (i ->> 'buffer_min')::int > 120) then return 'buffer_min must be 0-120'; end if;
            if i ? 'price_text' and (jsonb_typeof(i -> 'price_text') <> 'string' or length(i ->> 'price_text') > 40 or (i ->> 'price_text') ~ '[<>]') then return 'price_text must be up to 40 characters'; end if;
            if i ? 'description' and (jsonb_typeof(i -> 'description') <> 'string' or length(i ->> 'description') > 200 or (i ->> 'description') ~ '[<>]') then return 'description must be up to 200 characters'; end if;
          end loop;
          k := 'services';
        elsif k = 'staff' then
          if jsonb_typeof(e) <> 'array' or jsonb_array_length(e) > 20 or exists (select 1 from jsonb_array_elements(e) x where jsonb_typeof(x) <> 'string' or length(btrim(x #>> '{}')) not between 1 and 80 or (x #>> '{}') ~ '[<>]') then return 'staff must be up to 20 names'; end if;
        elsif k = 'notes' then
          if jsonb_typeof(e) <> 'string' or length(e #>> '{}') > 1000 or (e #>> '{}') ~ '[<>]' then return 'notes must be plain text up to 1000 characters'; end if;
        else
          if jsonb_typeof(e) <> 'number' or (e #>> '{}') !~ '^[0-9]{1,5}$' then return k || ' must be a whole number'; end if;
          if k = 'slot_interval_min' and (e #>> '{}')::int not between 5 and 240 then return 'slot_interval_min must be 5-240'; end if;
          if k = 'min_notice_min' and (e #>> '{}')::int > 20160 then return 'min_notice_min must be 0-20160'; end if;
          if k = 'max_days_ahead' and (e #>> '{}')::int not between 1 and 365 then return 'max_days_ahead must be 1-365'; end if;
        end if;
      end loop;
    when 'faqs' then
      if jsonb_typeof(p_val) <> 'array' or jsonb_array_length(p_val) > 60 then return 'must be a list of up to 60 questions'; end if;
      for i in select value from jsonb_array_elements(p_val) loop
        if jsonb_typeof(i) <> 'object' or exists (select 1 from jsonb_object_keys(i) x where x not in ('q','a')) then return 'each FAQ must be {"q":..., "a":...}'; end if;
        if jsonb_typeof(i -> 'q') <> 'string' or length(btrim(i ->> 'q')) not between 3 and 200 or jsonb_typeof(i -> 'a') <> 'string' or length(btrim(i ->> 'a')) not between 3 and 800 then return 'question 3-200 and answer 3-800 characters'; end if;
        if (i ->> 'q') ~ '[<>]' or (i ->> 'a') ~ '[<>]' then return 'FAQs are plain text only'; end if;
      end loop;
    when 'integrations' then
      if jsonb_typeof(p_val) <> 'object' then return 'must be an object'; end if;
      if p_val::text ~* '(api[_-]?key|secret|token|password|bearer|authorization)' then return 'store references (ids, numbers), never credentials'; end if;
      for k, e in select key, value from jsonb_each(p_val) loop
        if k not in ('calendar','sms','voice','website') then return 'unknown integration ' || k; end if;
        if jsonb_typeof(e) <> 'object' then return k || ' must be an object'; end if;
        for i in select to_jsonb(x) from jsonb_object_keys(e) x loop
          if (i #>> '{}') not in ('provider','status','calendar_id','number','assistant_id','url','note') then return k || ': unknown field ' || (i #>> '{}'); end if;
        end loop;
        if e ? 'status' and (jsonb_typeof(e -> 'status') <> 'string' or (e ->> 'status') not in ('pending','connected','failed')) then return k || '.status must be pending, connected or failed'; end if;
        if e ? 'number' and (jsonb_typeof(e -> 'number') <> 'string' or (e ->> 'number') !~ '^\+[1-9][0-9]{7,14}$') then return k || '.number must be E.164'; end if;
        if e ? 'url' and (jsonb_typeof(e -> 'url') <> 'string' or (e ->> 'url') !~ '^https://[^\s<>"'']{4,200}$') then return k || '.url must be an https URL'; end if;
        if e ? 'calendar_id' and (jsonb_typeof(e -> 'calendar_id') <> 'string' or length(e ->> 'calendar_id') > 200 or (e ->> 'calendar_id') ~ '\s') then return k || '.calendar_id looks wrong'; end if;
        if e ? 'provider' and (jsonb_typeof(e -> 'provider') <> 'string' or length(e ->> 'provider') > 30 or (e ->> 'provider') ~ '[<>]') then return k || '.provider looks wrong'; end if;
        if e ? 'assistant_id' and (jsonb_typeof(e -> 'assistant_id') <> 'string' or length(e ->> 'assistant_id') > 100 or (e ->> 'assistant_id') ~ '\s') then return k || '.assistant_id looks wrong'; end if;
        if e ? 'note' and (jsonb_typeof(e -> 'note') <> 'string' or length(e ->> 'note') > 200 or (e ->> 'note') ~ '[<>]') then return k || '.note must be up to 200 characters'; end if;
      end loop;
    else return 'unknown section';
  end case;
  return null;
end $$;

create or replace function acq.update_client_config(p_client uuid, p_section text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); err text; n int;
begin
  err := acq.validate_client_section(p_section, p_value);
  if err is not null then perform acq.fail('invalid_config', p_section || ': ' || err); end if;
  update acq.clients set
    business_details     = case when p_section = 'business_details'     then p_value else business_details end,
    receptionist_config  = case when p_section = 'receptionist_config'  then p_value else receptionist_config end,
    booking_requirements = case when p_section = 'booking_requirements' then p_value else booking_requirements end,
    faqs                 = case when p_section = 'faqs'                 then p_value else faqs end,
    integrations         = case when p_section = 'integrations'         then p_value else integrations end
   where id = p_client and org_id = o;
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('client_not_found', 'Client not found.'); end if;
  return jsonb_build_object('ok', true, 'section', p_section);
end $$;

create or replace function acq.set_client_status(p_client uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); c acq.clients;
begin
  if p_status not in ('onboarding', 'active', 'paused', 'churned') then perform acq.fail('invalid_status', 'Unknown client status.'); end if;
  select * into c from acq.clients where id = p_client and org_id = o for update;
  if c.id is null then perform acq.fail('client_not_found', 'Client not found.'); end if;
  if p_status = 'churned' then perform acq.require_role('admin'); end if;
  if p_status = 'active' and c.status = 'onboarding'
     and not exists (select 1 from acq.onboarding_tasks t where t.client_id = c.id and t.key = 'go_live_review' and t.status in ('done', 'skipped')) then
    perform acq.fail('onboarding_incomplete', 'Finish the go-live review task before marking the client Active.');
  end if;
  update acq.clients set status = p_status, go_live_at = case when p_status = 'active' then coalesce(go_live_at, now()) else go_live_at end where id = c.id;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

-- Creates the booking business (bos.*) from the validated configuration. TEST MODE STAYS ON; going live is a separate, deliberate step.
create or replace function acq.provision_bos_business(p_client uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o uuid := acq.require_role('admin'); c acq.clients; br jsonb; rc jsonb; bd jsonb; slug text; bid uuid; tz text; cc text; k text; v jsonb; p jsonb;
  staff jsonb; svc jsonb; notes text; n int := 0;
begin
  if to_regclass('bos.businesses') is null then perform acq.fail('bos_not_installed', 'The booking engine schema (bos) is not installed in this database.'); end if;
  select * into c from acq.clients where id = p_client and org_id = o for update;
  if c.id is null then perform acq.fail('client_not_found', 'Client not found.'); end if;
  if c.bos_business_id is not null then return jsonb_build_object('ok', true, 'bos_business_id', c.bos_business_id, 'existing', true); end if;
  br := c.booking_requirements; rc := c.receptionist_config; bd := c.business_details;
  tz := br ->> 'timezone';
  if tz is null then perform acq.fail('booking_requirements_incomplete', 'Set the timezone first.'); end if;
  if coalesce(jsonb_typeof(br -> 'hours'), '') <> 'object' or br -> 'hours' = '{}'::jsonb then perform acq.fail('booking_requirements_incomplete', 'Set the opening hours first.'); end if;
  if coalesce(jsonb_array_length(br -> 'services'), 0) = 0 then perform acq.fail('booking_requirements_incomplete', 'Add at least one service first.'); end if;
  cc := coalesce(acq.dial_code(bd ->> 'country_code'), '44');
  slug := trim(both '-' from regexp_replace(lower(c.business_name), '[^a-z0-9]+', '-', 'g'));
  slug := left(coalesce(nullif(slug, ''), 'client'), 50) || '-' || substr(c.id::text, 1, 6);

  notes := concat_ws(E'\n',
    nullif('Parking: ' || coalesce(bd ->> 'parking', ''), 'Parking: '),
    nullif('Payment: ' || coalesce(bd ->> 'payment_methods', ''), 'Payment: '),
    nullif('Cancellation policy: ' || coalesce(bd ->> 'cancellation_policy', ''), 'Cancellation policy: '),
    nullif('Notes: ' || coalesce(bd ->> 'notes', ''), 'Notes: '),
    (select string_agg('Q: ' || (f ->> 'q') || ' A: ' || (f ->> 'a'), E'\n') from jsonb_array_elements(c.faqs) f));

  insert into bos.businesses (slug, name, industry, timezone, country_code, phone, address, website, calendar_id, receptionist_name, ai_notes,
                              slot_interval_min, min_notice_min, max_days_ahead, test_mode, active)
  values (slug, c.business_name, c.industry, tz, cc, c.phone, nullif(bd ->> 'address', ''), c.website,
          nullif(c.integrations #>> '{calendar,calendar_id}', ''), coalesce(nullif(rc ->> 'receptionist_name', ''), 'Sophie'), left(nullif(notes, ''), 6000),
          coalesce((br ->> 'slot_interval_min')::int, 15), coalesce((br ->> 'min_notice_min')::int, 60), coalesce((br ->> 'max_days_ahead')::int, 60), true, true)
  returning id into bid;

  for k, v in select key, value from jsonb_each(br -> 'hours') loop
    for p in select case when jsonb_typeof(v -> 0) = 'string' then jsonb_build_array(v) else v end loop
      insert into bos.business_hours (business_id, weekday, opens, closes)
      select bid, k::smallint, (x ->> 0)::time, (x ->> 1)::time from jsonb_array_elements(p) x
      on conflict do nothing;
    end loop;
  end loop;

  staff := coalesce(nullif(br -> 'staff', '[]'::jsonb), '["Reception"]'::jsonb);
  insert into bos.resources (business_id, name, kind, sort_order)
  select bid, btrim(s.value #>> '{}'), 'staff', s.ord::int from jsonb_array_elements(staff) with ordinality s(value, ord);
  for svc in select value from jsonb_array_elements(br -> 'services') loop
    insert into bos.services (business_id, name, description, duration_min, buffer_min, price_text)
    values (bid, btrim(svc ->> 'name'), nullif(svc ->> 'description', ''), (svc ->> 'duration_min')::int, coalesce((svc ->> 'buffer_min')::int, 0), nullif(svc ->> 'price_text', ''))
    on conflict do nothing;
    n := n + 1;
  end loop;

  update acq.clients set bos_business_id = bid where id = c.id;
  update acq.onboarding_tasks set status = 'in_progress' where client_id = c.id and key = 'provision_receptionist' and status = 'todo';
  perform acq.activity(o, 'client.provisioned', 'clients', c.id::text, c.lead_id, jsonb_build_object('bos_business_id', bid, 'services', n));
  return jsonb_build_object('ok', true, 'bos_business_id', bid, 'slug', slug, 'test_mode', true, 'services', n,
                            'next', 'Set sms_from / calendar_id, create the voice assistant with the slug, run the end-to-end test, then turn test mode off.');
end $$;

create or replace view acq.v_clients with (security_invoker = true) as
select c.id, c.org_id, c.lead_id, c.business_name, c.contact_name, c.email, c.phone, c.website, c.industry, c.plan, c.monthly_fee, c.status,
       c.bos_business_id, c.won_at, c.go_live_at,
       count(t.id) filter (where t.status not in ('skipped'))                                  as tasks_total,
       count(t.id) filter (where t.status = 'done')                                            as tasks_done,
       count(t.id) filter (where t.status in ('todo', 'in_progress', 'blocked') and t.due_at < now()) as tasks_overdue,
       min(t.due_at) filter (where t.status in ('todo', 'in_progress', 'blocked'))             as next_due_at
from acq.clients c left join acq.onboarding_tasks t on t.client_id = c.id and t.org_id = c.org_id
group by c.id;

-- the configuration sections now go through update_client_config (validated); contact fields stay directly editable
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke update (business_details, receptionist_config, booking_requirements, faqs, integrations) on acq.clients from authenticated;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- C. Daily digest (internal email to the organisation's own team) + housekeeping
-- ---------------------------------------------------------------------

create table if not exists acq.digests (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references acq.organizations(id) on delete cascade,
  day          date not null,                              -- organisation-local day
  status       text not null default 'sending' check (status in ('sending','sent','failed','skipped')),
  to_email     text,
  summary      jsonb not null default '{}'::jsonb,
  attempts     int not null default 0,
  locked_until timestamptz,
  provider_message_id text,
  last_error   text,
  created_at   timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by   uuid, updated_by uuid,
  unique (org_id, day)
);
alter table acq.digests enable row level security;
do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'digests' and policyname = 'digests_select') then
    alter policy digests_select on acq.digests to authenticated
      using (org_id = (select acq.current_org_id()));
  else
    create policy digests_select on acq.digests for select to authenticated using (org_id = (select acq.current_org_id()));
  end if;
end $$;

create or replace function acq.pending_work(p_org uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'drafts_awaiting_approval', (select count(*) from acq.outreach_messages where org_id = p_org and status = 'pending_approval'),
    'replies_to_handle',        (select count(*) from acq.replies where org_id = p_org and handled_at is null and classification in ('positive', 'question', 'follow_up_needed', 'unclassified')),
    'reply_responses_pending',  (select count(*) from acq.replies where org_id = p_org and response_status = 'pending_approval'),
    'meetings_next_36h',        (select count(*) from acq.meetings where org_id = p_org and status = 'scheduled' and starts_at between now() and now() + interval '36 hours'),
    'overdue_onboarding_tasks', (select count(*) from acq.onboarding_tasks t join acq.clients c on c.id = t.client_id and c.org_id = t.org_id
                                  where t.org_id = p_org and t.status in ('todo', 'in_progress', 'blocked') and t.due_at < now() and c.status = 'onboarding'),
    'followups_due_today',      (select count(*) from acq.followups where org_id = p_org and status in ('scheduled', 'drafting', 'drafted') and due_at <= now() + interval '24 hours'))
$$;

create or replace function acq.claim_digests(p_limit int default 3)
returns setof jsonb language plpgsql as $$
declare
  o acq.organizations; s jsonb; w jsonb; loc timestamp; d date; to_e text; w8 jsonb; txt text; n int; dg acq.digests; sender text;
begin
  -- 1. start today's digest for organisations that are due
  for o in select * from acq.organizations where status = 'active' order by id loop
    continue when not acq.setting_bool(o.id, 'daily_digest', true);
    to_e := acq.norm_email(acq.setting(o.id, 'notify_email', '""'::jsonb) #>> '{}');
    continue when to_e is null;
    s := acq.setting(o.id, 'sender', '{}'::jsonb);
    continue when acq.norm_email(s ->> 'from_email') is null;
    w := acq.setting(o.id, 'send_window', '{}'::jsonb);
    begin loc := now() at time zone coalesce(w ->> 'tz', 'UTC'); exception when others then loc := now() at time zone 'UTC'; end;
    continue when loc::time < time '08:00';
    d := loc::date;
    continue when exists (select 1 from acq.digests x where x.org_id = o.id and x.day = d);
    w8 := acq.pending_work(o.id);
    n := (select sum(value::int) from jsonb_each_text(w8));
    insert into acq.digests (org_id, day, status, to_email, summary) values (o.id, d, case when n > 0 then 'sending' else 'skipped' end, to_e, w8)
    on conflict (org_id, day) do nothing;
  end loop;

  -- 2. hand out digests that need sending (or were abandoned mid-send)
  for dg in
    select x.* from acq.digests x join acq.organizations og on og.id = x.org_id and og.status = 'active'
    where (x.status = 'sending' and (x.locked_until is null or x.locked_until < now())) order by x.created_at limit least(greatest(p_limit, 1), 5) for update of x skip locked
  loop
    if dg.attempts >= 3 then update acq.digests set status = 'failed', last_error = coalesce(last_error, 'max_attempts'), locked_until = null where id = dg.id; continue; end if;
    s := acq.setting(dg.org_id, 'sender', '{}'::jsonb);
    w8 := dg.summary;
    txt := 'Good morning,' || E'\n\nHere is what needs a person today:\n\n' ||
      concat_ws(E'\n',
        case when (w8 ->> 'drafts_awaiting_approval')::int > 0 then '- ' || (w8 ->> 'drafts_awaiting_approval') || ' outreach draft(s) waiting for approval' end,
        case when (w8 ->> 'replies_to_handle')::int > 0 then '- ' || (w8 ->> 'replies_to_handle') || ' repl' || case when (w8 ->> 'replies_to_handle') = '1' then 'y' else 'ies' end || ' to handle' end,
        case when (w8 ->> 'reply_responses_pending')::int > 0 then '- ' || (w8 ->> 'reply_responses_pending') || ' suggested response(s) waiting for approval' end,
        case when (w8 ->> 'meetings_next_36h')::int > 0 then '- ' || (w8 ->> 'meetings_next_36h') || ' sales call(s) in the next 36 hours' end,
        case when (w8 ->> 'overdue_onboarding_tasks')::int > 0 then '- ' || (w8 ->> 'overdue_onboarding_tasks') || ' overdue onboarding task(s)' end,
        case when (w8 ->> 'followups_due_today')::int > 0 then '- ' || (w8 ->> 'followups_due_today') || ' follow-up(s) due within 24 hours' end) ||
      E'\n\nOpen the dashboard to review. Nothing is sent to prospects without an approval.\n\n(Internal digest. Turn it off in Settings: daily_digest.)';
    update acq.digests set attempts = attempts + 1, locked_until = now() + interval '10 minutes' where id = dg.id;
    sender := coalesce(nullif(s ->> 'from_name', ''), 'Booking OS') || ' <' || (s ->> 'from_email') || '>';
    return next jsonb_build_object('digest_id', dg.id, 'org_id', dg.org_id, 'from', sender, 'to', dg.to_email,
      'subject', 'Daily digest: ' || (select sum(value::int) from jsonb_each_text(w8)) || ' item(s) need attention', 'text', txt,
      'idempotency_key', 'acq-digest-' || dg.id::text);
  end loop;
end $$;

create or replace function acq.complete_digest(p_digest uuid, p_http_status int, p_body jsonb, p_error text default null)
returns jsonb language plpgsql as $$
declare dg acq.digests; ok boolean; permanent boolean;
begin
  select * into dg from acq.digests where id = p_digest for update;
  if dg.id is null then return jsonb_build_object('ok', false, 'error', 'digest_not_found'); end if;
  if dg.status <> 'sending' then return jsonb_build_object('ok', true, 'note', 'already ' || dg.status); end if;
  ok := coalesce(p_http_status, 0) between 200 and 299 and coalesce(p_body ->> 'id', '') <> '';
  if ok then
    update acq.digests set status = 'sent', provider_message_id = p_body ->> 'id', locked_until = null, last_error = null where id = dg.id;
    return jsonb_build_object('ok', true, 'status', 'sent');
  end if;
  permanent := p_http_status between 400 and 499 and p_http_status not in (401, 403, 408, 409, 425, 429);
  update acq.digests set status = case when permanent or dg.attempts >= 3 then 'failed' else 'sending' end,
         locked_until = now() + make_interval(mins => 10 * greatest(dg.attempts, 1)),
         last_error = left(coalesce(p_error, '') || ' http=' || coalesce(p_http_status::text, 'none') || ' ' || coalesce(p_body ->> 'message', p_body #>> '{error,message}', ''), 300)
   where id = dg.id;
  return jsonb_build_object('ok', false, 'status', case when permanent or dg.attempts >= 3 then 'failed' else 'retry' end);
end $$;

-- housekeeping (n8n, daily): expire demos, trim counters / webhook de-dupe rows / old digests
create or replace function acq.maintenance()
returns jsonb language plpgsql as $$
declare a int; b int; c int; d int;
begin
  update acq.demos set status = 'expired' where status in ('ready', 'sent', 'opened', 'clicked') and expires_at <= now();
  get diagnostics a = row_count;
  delete from acq.rate_limits where window_start < now() - interval '2 days';
  get diagnostics b = row_count;
  delete from acq.webhook_events where received_at < now() - interval '45 days';
  get diagnostics c = row_count;
  delete from acq.digests where created_at < now() - interval '90 days';
  get diagnostics d = row_count;
  return jsonb_build_object('ok', true, 'demos_expired', a, 'rate_limits_deleted', b, 'webhook_events_deleted', c, 'digests_deleted', d);
end $$;

-- existing organisations get the two new settings
insert into acq.system_settings (org_id, key, value, description)
select o.id, 'notify_email', '""'::jsonb, 'Where the daily digest of pending work is sent. Empty = digest off.' from acq.organizations o
on conflict (org_id, key) do nothing;
insert into acq.system_settings (org_id, key, value, description)
select o.id, 'daily_digest', 'true'::jsonb, 'Send the daily digest (needs notify_email and a sender address)' from acq.organizations o
on conflict (org_id, key) do nothing;

-- Defense in depth: the auto_followup approval source is only ever valid on follow-up messages.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'outreach_auto_approval_followups_only' and conrelid = 'acq.outreach_messages'::regclass) then
    alter table acq.outreach_messages add constraint outreach_auto_approval_followups_only
      check (approval_source is distinct from 'auto_followup' or kind = 'followup');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- D. Dashboard metrics (cohort = leads created in the last N days; funnel from the pipeline event log)
-- ---------------------------------------------------------------------

create or replace function acq.pct(p_num numeric, p_den numeric)
returns numeric language sql immutable as $$ select case when coalesce(p_den, 0) = 0 then null else round(100.0 * p_num / p_den, 1) end $$;

create or replace function acq.performance_breakdown(p_dim text, p_days int default 90)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o uuid := acq.require_role('viewer'); since timestamptz := now() - make_interval(days => least(greatest(coalesce(p_days, 90), 1), 730)); r jsonb;
begin
  if p_dim not in ('niche', 'source', 'campaign', 'city') then perform acq.fail('invalid_dimension', 'Use niche, source, campaign or city.'); end if;
  with cohort as (
    select l.id, l.score,
           case p_dim when 'niche' then coalesce(nullif(l.niche, ''), '(none)') when 'source' then coalesce(s.name, '(none)')
                      when 'campaign' then coalesce(cm.name, '(none)') else coalesce(nullif(l.city, ''), '(none)') end as k
    from acq.leads l
    left join acq.lead_sources s on s.id = l.source_id and s.org_id = l.org_id
    left join acq.outreach_campaigns cm on cm.id = l.campaign_id and cm.org_id = l.org_id
    where l.org_id = o and l.created_at >= since),
  ev as (
    select pe.lead_id,
           bool_or(pe.to_status = 'qualified') as q, bool_or(pe.to_status = 'contacted') as c, bool_or(pe.to_status = 'replied') as r,
           bool_or(pe.to_status = 'meeting_booked') as m, bool_or(pe.to_status = 'won') as w
    from acq.pipeline_events pe where pe.org_id = o group by pe.lead_id),
  pos as (select distinct lead_id from acq.replies where org_id = o and classification = 'positive' and lead_id is not null),
  agg as (
    select c.k, count(*) as leads, count(*) filter (where e.q) as qualified, count(*) filter (where e.c) as contacted,
           count(*) filter (where e.r) as replied, count(*) filter (where p.lead_id is not null) as positive,
           count(*) filter (where e.m) as meetings, count(*) filter (where e.w) as won, round(avg(c.score), 1) as avg_score
    from cohort c left join ev e on e.lead_id = c.id left join pos p on p.lead_id = c.id group by c.k)
  select coalesce(jsonb_agg(jsonb_build_object('key', a.k, 'leads', a.leads, 'qualified', a.qualified, 'contacted', a.contacted, 'replied', a.replied,
           'positive_replies', a.positive, 'meetings', a.meetings, 'won', a.won, 'avg_score', a.avg_score,
           'qualify_rate', acq.pct(a.qualified, a.leads), 'reply_rate', acq.pct(a.replied, a.contacted),
           'meeting_rate', acq.pct(a.meetings, a.contacted), 'win_rate', acq.pct(a.won, a.contacted)) order by a.leads desc, a.k), '[]'::jsonb)
    into r from (select * from agg order by leads desc, k limit 50) a;
  return jsonb_build_object('ok', true, 'dimension', p_dim, 'days', p_days, 'rows', r);
end $$;

create or replace function acq.dashboard_metrics(p_days int default 90)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  o uuid := acq.require_role('viewer'); days int := least(greatest(coalesce(p_days, 90), 1), 730); since timestamptz := now() - make_interval(days => days);
  total int; reached jsonb; by_status jsonb; funnel jsonb; outreach jsonb; replies jsonb; demos jsonb; meetings jsonb; fu jsonb; clients jsonb;
begin
  select count(*) into total from acq.leads where org_id = o and created_at >= since;
  select coalesce(jsonb_object_agg(to_status, n), '{}'::jsonb) into reached from (
    select pe.to_status, count(distinct pe.lead_id) n from acq.pipeline_events pe join acq.leads l on l.id = pe.lead_id and l.org_id = pe.org_id
    where pe.org_id = o and l.created_at >= since group by 1) x;
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into by_status from (select status, count(*) n from acq.leads where org_id = o group by 1) x;
  funnel := jsonb_build_object('leads', total, 'qualified', coalesce((reached ->> 'qualified')::int, 0), 'approved', coalesce((reached ->> 'approved')::int, 0),
      'contacted', coalesce((reached ->> 'contacted')::int, 0), 'replied', coalesce((reached ->> 'replied')::int, 0), 'demo_sent', coalesce((reached ->> 'demo_sent')::int, 0),
      'meeting_booked', coalesce((reached ->> 'meeting_booked')::int, 0), 'won', coalesce((reached ->> 'won')::int, 0), 'lost', coalesce((reached ->> 'lost')::int, 0));
  select jsonb_build_object(
      'sent',       count(*) filter (where sent_at is not null),
      'delivered',  count(*) filter (where delivered_at is not null),
      'opened',     count(*) filter (where open_count > 0),
      'clicked',    count(*) filter (where click_count > 0),
      'bounced',    count(*) filter (where status = 'bounced'),
      'complained', count(*) filter (where status = 'complained'),
      'rejected',   count(*) filter (where status = 'rejected'),
      'first_touch_sent', count(*) filter (where sent_at is not null and kind = 'outreach'),
      'followups_sent',   count(*) filter (where sent_at is not null and kind = 'followup'),
      'replies_sent',     count(*) filter (where sent_at is not null and kind = 'reply'))
    into outreach from acq.outreach_messages where org_id = o and created_at >= since;
  select coalesce(jsonb_object_agg(classification, n), '{}'::jsonb) into replies from (
    select classification, count(*) n from acq.replies where org_id = o and received_at >= since group by 1) x;
  select jsonb_build_object('created', count(*), 'sent', count(*) filter (where sent_at is not null), 'opened', count(*) filter (where open_count > 0),
      'clicked', count(*) filter (where click_count > 0), 'booked', count(*) filter (where booked_at is not null))
    into demos from acq.demos where org_id = o and created_at >= since;
  select jsonb_build_object('created', count(*), 'scheduled', count(*) filter (where status = 'scheduled'), 'completed', count(*) filter (where status = 'completed'),
      'cancelled', count(*) filter (where status = 'cancelled'), 'no_show', count(*) filter (where status = 'no_show'),
      'won', count(*) filter (where outcome = 'won'), 'from_demo_page', count(*) filter (where source = 'demo_booking'))
    into meetings from acq.meetings where org_id = o and created_at >= since;
  select jsonb_build_object('scheduled', count(*) filter (where status = 'scheduled'), 'drafted', count(*) filter (where status = 'drafted'),
      'cancelled', count(*) filter (where status = 'cancelled'), 'skipped', count(*) filter (where status = 'skipped'))
    into fu from acq.followups where org_id = o and created_at >= since;
  select jsonb_build_object('total', count(*), 'onboarding', count(*) filter (where status = 'onboarding'), 'active', count(*) filter (where status = 'active'),
      'paused', count(*) filter (where status = 'paused'), 'churned', count(*) filter (where status = 'churned'),
      'mrr', coalesce(sum(monthly_fee) filter (where status = 'active'), 0))
    into clients from acq.clients where org_id = o;
  return jsonb_build_object('ok', true, 'days', days, 'generated_at', now(),
    'leads_by_status', by_status, 'funnel', funnel,
    'conversion', jsonb_build_object(
      'lead_to_qualified',    acq.pct((funnel ->> 'qualified')::numeric, total),
      'qualified_to_contacted', acq.pct((funnel ->> 'contacted')::numeric, (funnel ->> 'qualified')::numeric),
      'contacted_to_replied', acq.pct((funnel ->> 'replied')::numeric, (funnel ->> 'contacted')::numeric),
      'contacted_to_meeting', acq.pct((funnel ->> 'meeting_booked')::numeric, (funnel ->> 'contacted')::numeric),
      'meeting_to_won',       acq.pct((funnel ->> 'won')::numeric, (funnel ->> 'meeting_booked')::numeric),
      'lead_to_won',          acq.pct((funnel ->> 'won')::numeric, total),
      'open_rate',            acq.pct((outreach ->> 'opened')::numeric, (outreach ->> 'sent')::numeric),
      'click_rate',           acq.pct((outreach ->> 'clicked')::numeric, (outreach ->> 'sent')::numeric),
      'bounce_rate',          acq.pct((outreach ->> 'bounced')::numeric, (outreach ->> 'sent')::numeric)),
    'outreach', outreach, 'replies', replies, 'demos', demos, 'meetings', meetings, 'followups', fu, 'clients', clients,
    'pending_work', acq.pending_work(o),
    'by_niche', acq.performance_breakdown('niche', days) -> 'rows', 'by_source', acq.performance_breakdown('source', days) -> 'rows');
end $$;

-- ---------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['digests'] loop
    execute format('create or replace trigger tg_touch before insert or update on acq.%I for each row execute function acq.tg_touch()', t);
    execute format('create or replace trigger tg_org_immutable before update on acq.%I for each row execute function acq.tg_org_immutable()', t);
  end loop;
end $$;

revoke execute on all functions in schema acq from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on all tables in schema acq to authenticated;
    revoke select on acq.rate_limits, acq.webhook_events from authenticated;
    grant execute on function acq.cancel_lead_followups(uuid), acq.skip_followup(uuid), acq.set_followup_due(uuid, timestamptz),
      acq.convert_lead_to_client(uuid), acq.update_client_config(uuid, text, jsonb), acq.set_client_status(uuid, text), acq.provision_bos_business(uuid),
      acq.dashboard_metrics(int), acq.performance_breakdown(text, int) to authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant all on all tables in schema acq to service_role;
    grant execute on all functions in schema acq to service_role;
  end if;
end $$;
