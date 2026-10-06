-- =====================================================================
-- ACQ Phase 3 — outreach: draft -> human approval -> controlled send -> delivery log
--   * AI only ever creates `pending_approval` drafts; a person approves (the CHECK constraint from 020 enforces it)
--   * the send queue enforces: org kill-switch, sender identity + postal address + unsubscribe URL, send window,
--     daily cap per channel / campaign / recipient domain, minimum gap, DNC + suppression re-check at send time
--   * delivery events (Resend/Twilio) update status monotonically; hard bounce / complaint suppress the lead;
--     a bad bounce or complaint rate switches outreach off automatically
-- Safe to re-run.
-- =====================================================================

alter table acq.leads add column if not exists draft_locked_until timestamptz;
alter table acq.leads add column if not exists draft_attempts int not null default 0;
alter table acq.leads add column if not exists draft_error text;
alter table acq.leads add column if not exists redraft_requested_at timestamptz;

create table if not exists acq.webhook_events (          -- provider webhook de-duplication
  provider    text not null,
  event_id    text not null,
  received_at timestamptz not null default now(),
  primary key (provider, event_id)
);
alter table acq.webhook_events enable row level security;

-- ---------------------------------------------------------------------
-- Settings validation + update (admin+; sensitive keys owner-only)
-- ---------------------------------------------------------------------

create or replace function acq.validate_setting(p_key text, p_val jsonb)
returns text language plpgsql stable as $$
declare k text; v text;
begin
  case p_key
    when 'qualify_threshold' then
      if jsonb_typeof(p_val) <> 'number' or (p_val #>> '{}') !~ '^[0-9]{1,3}$' or (p_val #>> '{}')::int > 100 then return 'must be an integer 0-100'; end if;
    when 'per_domain_daily_limit' then
      if jsonb_typeof(p_val) <> 'number' or (p_val #>> '{}') !~ '^[0-9]$' or (p_val #>> '{}')::int not between 1 and 5 then return 'must be an integer 1-5'; end if;
    when 'min_send_gap_seconds' then
      if jsonb_typeof(p_val) <> 'number' or (p_val #>> '{}') !~ '^[0-9]{2,4}$' or (p_val #>> '{}')::int not between 30 and 3600 then return 'must be 30-3600 seconds'; end if;
    when 'followup_max_steps' then
      if jsonb_typeof(p_val) <> 'number' or (p_val #>> '{}') !~ '^[0-9]$' or (p_val #>> '{}')::int > 5 then return 'must be an integer 0-5'; end if;
    when 'max_search_runs_per_day' then
      if jsonb_typeof(p_val) <> 'number' or (p_val #>> '{}') !~ '^[0-9]{1,3}$' or (p_val #>> '{}')::int > 100 then return 'must be an integer 0-100'; end if;
    when 'followups_require_approval', 'sms_outreach_enabled' then
      if jsonb_typeof(p_val) <> 'boolean' then return 'must be true or false'; end if;
    when 'notify_email' then
      if jsonb_typeof(p_val) <> 'string' or ((p_val #>> '{}') <> '' and acq.norm_email(p_val #>> '{}') is null) then return 'must be empty or a valid email address'; end if;
    when 'daily_digest' then
      if jsonb_typeof(p_val) <> 'boolean' then return 'must be true or false'; end if;
    when 'default_country' then
      if jsonb_typeof(p_val) <> 'string' or (p_val #>> '{}') !~ '^[A-Z]{2}$' then return 'must be a 2-letter country code'; end if;
    when 'offer_context' then
      if jsonb_typeof(p_val) <> 'string' or length(p_val #>> '{}') > 3000 then return 'must be text up to 3000 characters'; end if;
    when 'demo_base_url', 'tracking_base_url' then
      if jsonb_typeof(p_val) <> 'string' or ((p_val #>> '{}') <> '' and (p_val #>> '{}') !~ '^https://[^\s]{4,250}$') then return 'must be empty or an https:// URL'; end if;
    when 'daily_send_limit' then
      if jsonb_typeof(p_val) <> 'object' or not (p_val ? 'email' and p_val ? 'sms') then return 'must be {"email":n,"sms":n}'; end if;
      if (p_val->>'email') !~ '^[0-9]{1,3}$' or (p_val->>'email')::int > 200 then return 'email limit must be 0-200'; end if;
      if (p_val->>'sms') !~ '^[0-9]{1,2}$' or (p_val->>'sms')::int > 50 then return 'sms limit must be 0-50'; end if;
    when 'send_window' then
      if jsonb_typeof(p_val) <> 'object' then return 'must be an object'; end if;
      if not exists (select 1 from pg_timezone_names where name = p_val->>'tz') then return 'unknown timezone'; end if;
      if coalesce(p_val->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(p_val->>'end', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
         or (p_val->>'start') >= (p_val->>'end') then return 'start/end must be HH:MM with start before end'; end if;
      if jsonb_typeof(p_val->'days') <> 'array' or jsonb_array_length(p_val->'days') = 0
         or exists (select 1 from jsonb_array_elements(p_val->'days') d where jsonb_typeof(d) <> 'number' or (d #>> '{}') !~ '^[0-6]$') then
        return 'days must be a list of 0-6 (0 = Sunday)'; end if;
    when 'sender' then
      if jsonb_typeof(p_val) <> 'object' then return 'must be an object'; end if;
      for k, v in select key, value #>> '{}' from jsonb_each(p_val) loop
        if k not in ('from_name','from_email','reply_to_email','postal_address','sms_from','twilio_account_sid') then return 'unknown sender field ' || k; end if;
        if jsonb_typeof(p_val->k) <> 'string' or length(v) > 300 then return k || ' must be text up to 300 characters'; end if;
      end loop;
      if coalesce(p_val->>'from_email', '') <> '' and acq.norm_email(p_val->>'from_email') is null then return 'from_email is not a valid address'; end if;
      if coalesce(p_val->>'reply_to_email', '') <> '' and acq.norm_email(p_val->>'reply_to_email') is null then return 'reply_to_email is not a valid address'; end if;
      if coalesce(p_val->>'sms_from', '') <> '' and (p_val->>'sms_from') !~ '^\+[1-9][0-9]{7,14}$' then return 'sms_from must be E.164'; end if;
      if coalesce(p_val->>'twilio_account_sid', '') <> '' and (p_val->>'twilio_account_sid') !~ '^AC[0-9a-fA-F]{32}$' then return 'twilio_account_sid looks wrong'; end if;
    when 'meeting' then
      if jsonb_typeof(p_val) <> 'object' then return 'must be an object'; end if;
      for k in select jsonb_object_keys(p_val) loop
        if k not in ('duration_min','slot_step_min','min_notice_min','max_days_ahead','tz','hours','calendar_id') then return 'unknown meeting field ' || k; end if;
      end loop;
      if p_val ? 'tz' and not exists (select 1 from pg_timezone_names where name = p_val->>'tz') then return 'unknown timezone'; end if;
      if p_val ? 'duration_min' and (jsonb_typeof(p_val->'duration_min') <> 'number' or (p_val->>'duration_min') !~ '^[0-9]{2,3}$' or (p_val->>'duration_min')::int not between 10 and 240) then return 'duration_min must be 10-240'; end if;
      if p_val ? 'slot_step_min' and (jsonb_typeof(p_val->'slot_step_min') <> 'number' or (p_val->>'slot_step_min') !~ '^[0-9]{1,3}$' or (p_val->>'slot_step_min')::int not between 5 and 240) then return 'slot_step_min must be 5-240'; end if;
      if p_val ? 'min_notice_min' and (jsonb_typeof(p_val->'min_notice_min') <> 'number' or (p_val->>'min_notice_min') !~ '^[0-9]{1,5}$' or (p_val->>'min_notice_min')::int > 20160) then return 'min_notice_min must be 0-20160'; end if;
      if p_val ? 'max_days_ahead' and (jsonb_typeof(p_val->'max_days_ahead') <> 'number' or (p_val->>'max_days_ahead') !~ '^[0-9]{1,2}$' or (p_val->>'max_days_ahead')::int not between 1 and 90) then return 'max_days_ahead must be 1-90'; end if;
      if p_val ? 'calendar_id' and (jsonb_typeof(p_val->'calendar_id') <> 'string' or length(p_val->>'calendar_id') > 200 or (p_val->>'calendar_id') ~ '\s') then return 'calendar_id looks wrong'; end if;
      if p_val ? 'hours' then
        if jsonb_typeof(p_val->'hours') <> 'object' then return 'hours must be an object keyed 0-6 (0 = Sunday)'; end if;
        for k, v in select e.key, e.value::text from jsonb_each(p_val->'hours') e loop
          if k !~ '^[0-6]$' then return 'hours keys must be 0-6'; end if;
          if jsonb_typeof(p_val->'hours'->k) <> 'array' or jsonb_array_length(p_val->'hours'->k) <> 2
             or (p_val->'hours'->k->>0) !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or (p_val->'hours'->k->>1) !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
             or (p_val->'hours'->k->>0) >= (p_val->'hours'->k->>1) then return 'hours[' || k || '] must be ["HH:MM","HH:MM"] with start before end'; end if;
        end loop;
      end if;
    when 'ai' then
      if jsonb_typeof(p_val) <> 'object' or exists (select 1 from jsonb_object_keys(p_val) x where x not in ('prompt_version','model')) then return 'only prompt_version and model are allowed'; end if;
    else return 'unknown setting';
  end case;
  return null;
end $$;

create or replace function acq.update_setting(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('admin'); err text;
begin
  if p_key in ('sms_outreach_enabled', 'sender', 'tracking_base_url') and acq.my_role() <> 'owner' then
    raise exception using errcode = '42501', message = 'forbidden', detail = 'Only an owner can change ' || p_key || '.';
  end if;
  err := acq.validate_setting(p_key, p_value);
  if err is not null then perform acq.fail('invalid_setting', p_key || ': ' || err); end if;
  insert into acq.system_settings (org_id, key, value) values (o, p_key, p_value)
  on conflict (org_id, key) do update set value = excluded.value;
  return jsonb_build_object('ok', true, 'key', p_key);
end $$;

create or replace function acq.sender_problem(p_org uuid)
returns text language sql stable as $$
  select case
    when acq.norm_email(s->>'from_email') is null then 'sender.from_email is not set'
    when coalesce(btrim(s->>'from_name'), '') = '' then 'sender.from_name is not set'
    when length(btrim(coalesce(s->>'postal_address', ''))) < 10 then 'sender.postal_address is not set'
    when coalesce(acq.setting(p_org, 'tracking_base_url', '""'::jsonb) #>> '{}', '') !~ '^https://' then 'tracking_base_url is not set (unsubscribe link needs it)'
  end
  from (select acq.setting(p_org, 'sender', '{}'::jsonb) as s) x
$$;

create or replace function acq.set_outreach_enabled(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('owner'); prob text;
begin
  if p_enabled then
    prob := acq.sender_problem(o);
    if prob is not null then perform acq.fail('sender_not_ready', prob); end if;
  end if;
  update acq.organizations set outreach_enabled = p_enabled where id = o;
  perform acq.activity(o, case when p_enabled then 'outreach.enabled' else 'outreach.disabled' end, 'organization', o::text, null, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'outreach_enabled', p_enabled);
end $$;

create or replace function acq.in_send_window(p_org uuid)
returns boolean language plpgsql stable as $$
declare w jsonb := acq.setting(p_org, 'send_window', '{}'::jsonb); loc timestamp;
begin
  loc := now() at time zone (w->>'tz');
  return (w->'days') @> to_jsonb(extract(dow from loc)::int)
     and loc::time >= (w->>'start')::time and loc::time < (w->>'end')::time;
exception when others then return false;
end $$;

-- ---------------------------------------------------------------------
-- Drafting (n8n + AI -> pending_approval drafts only)
-- ---------------------------------------------------------------------

create or replace function acq.pick_campaign(p_lead acq.leads)
returns uuid language sql stable as $$
  select c.id from acq.outreach_campaigns c
  where c.org_id = p_lead.org_id and c.status = 'active'
    and (c.niche is null or lower(c.niche) = lower(coalesce(p_lead.niche, '')))
    and (c.country_code is null or c.country_code = p_lead.country_code)
    and coalesce(p_lead.score, 0) >= c.min_score
    and ((c.channel = 'email' and p_lead.email is not null)
         or (c.channel = 'sms' and p_lead.phone_e164 is not null and acq.setting_bool(p_lead.org_id, 'sms_outreach_enabled', false)))
  order by (c.niche is not null) desc, (c.country_code is not null) desc, c.created_at
  limit 1
$$;

create or replace function acq.claim_leads_for_drafting(p_limit int default 5)
returns setof jsonb language plpgsql as $$
declare l acq.leads; cid uuid; c acq.outreach_campaigns; q acq.lead_qualification;
begin
  for l in
    select x.* from acq.leads x join acq.organizations o on o.id = x.org_id and o.status = 'active'
    where x.status = 'qualified' and not x.do_not_contact and x.draft_attempts < 3
      and acq.pick_campaign(x) is not null   -- filter in the query, or un-draftable leads at the top would starve the queue
      and (x.draft_locked_until is null or x.draft_locked_until < now())
      and (not exists (select 1 from acq.outreach_messages m where m.lead_id = x.id and m.step = 0 and m.status not in ('failed', 'cancelled'))
           or (x.redraft_requested_at is not null
               and not exists (select 1 from acq.outreach_messages m where m.lead_id = x.id and m.step = 0
                               and m.status not in ('failed', 'cancelled', 'rejected'))))
    order by x.score desc nulls last, x.created_at limit least(greatest(p_limit, 1), 10) for update of x skip locked
  loop
    cid := acq.pick_campaign(l);
    if cid is null then continue; end if;
    select * into c from acq.outreach_campaigns where id = cid;
    select * into q from acq.lead_qualification where lead_id = l.id and is_current;
    update acq.leads set draft_attempts = draft_attempts + 1, draft_locked_until = now() + interval '10 minutes' where id = l.id;
    return next jsonb_build_object('lead_id', l.id, 'org_id', l.org_id, 'campaign_id', c.id, 'channel', c.channel,
      'business_name', l.business_name, 'category', l.category, 'niche', l.niche, 'city', l.city, 'country_code', l.country_code,
      'website', l.website, 'rating', l.rating, 'review_count', l.review_count, 'score', l.score,
      'reasons', coalesce(to_jsonb(q.reasons), '[]'::jsonb), 'pain_points', coalesce(to_jsonb(q.pain_points), '[]'::jsonb),
      'recommended_offer', q.recommended_offer, 'qualification_summary', q.summary, 'has_online_booking', q.has_online_booking,
      'campaign_offer', c.offer, 'subject_template', c.subject_template, 'body_template', c.body_template,
      'sender_name', acq.setting(l.org_id, 'sender', '{}'::jsonb) ->> 'from_name',
      'offer_context', acq.setting(l.org_id, 'offer_context', '""'::jsonb) #>> '{}',
      'model', coalesce(acq.setting(l.org_id, 'ai', '{}'::jsonb) ->> 'model', 'gpt-5-mini'));
  end loop;
end $$;

create or replace function acq.draft_failed(p_lead uuid, p_error text)
returns jsonb language plpgsql as $$
begin
  update acq.leads set draft_error = left(coalesce(p_error, 'failed'), 300),
         draft_locked_until = now() + make_interval(mins => 10 * greatest(draft_attempts, 1)) where id = p_lead;
  return jsonb_build_object('ok', found);
end $$;

-- shared text rules for drafts. p_strict (AI drafts): no links, no leftover placeholders.
create or replace function acq.check_draft(p_channel text, p_subject text, p_body text, p_strict boolean)
returns text language plpgsql immutable as $$
begin
  if p_channel = 'email' then
    if length(btrim(coalesce(p_subject, ''))) not between 3 and 150 then return 'subject must be 3-150 characters'; end if;
    if p_subject ~ '[\r\n]' then return 'subject must be a single line'; end if;
    if length(btrim(coalesce(p_body, ''))) not between 20 and 2000 then return 'body must be 20-2000 characters'; end if;
  else
    if length(btrim(coalesce(p_body, ''))) not between 10 and 320 then return 'SMS must be 10-320 characters'; end if;
  end if;
  if p_body ~ '\{\{|\}\}|\[(name|business|first_name|company)[^\]]*\]|\{[a-z_ ]{2,30}\}' then return 'draft still contains a placeholder'; end if;
  if p_strict and (p_body ~* '(https?://|www\.)' or coalesce(p_subject, '') ~* '(https?://|www\.)') then return 'AI drafts may not contain links'; end if;
  return null;
end $$;

create or replace function acq.create_outreach_draft(p_lead uuid, p_campaign uuid, p_subject text, p_body text, p_model text default null)
returns jsonb language plpgsql as $$
declare l acq.leads; c acq.outreach_campaigns; err text; to_addr text; s jsonb; mid uuid; n int; subj text := nullif(btrim(coalesce(p_subject, '')), '');
begin
  select * into l from acq.leads where id = p_lead for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  select * into c from acq.outreach_campaigns where id = p_campaign and org_id = l.org_id and status = 'active';
  if c.id is null then perform acq.fail('campaign_not_found', 'Campaign not found or not active.'); end if;
  if l.status <> 'qualified' then perform acq.fail('lead_not_qualified', 'Drafts are only created for Qualified leads.'); end if;
  if l.do_not_contact or acq.is_suppressed(l.org_id, l.email, l.phone_e164, l.domain) then perform acq.fail('do_not_contact', 'This lead must not be contacted.'); end if;
  if c.channel = 'sms' and not acq.setting_bool(l.org_id, 'sms_outreach_enabled', false) then perform acq.fail('sms_disabled', 'SMS outreach is disabled for this organisation.'); end if;
  to_addr := case c.channel when 'email' then l.email else l.phone_e164 end;
  if to_addr is null then perform acq.fail('no_recipient', 'The lead has no ' || c.channel || ' address.'); end if;
  err := acq.check_draft(c.channel, subj, p_body, true);
  if err is not null then perform acq.fail('invalid_draft', err); end if;
  if exists (select 1 from acq.outreach_messages where lead_id = l.id and step = 0 and status not in ('rejected', 'cancelled', 'failed')) then
    perform acq.fail('draft_exists', 'This lead already has a live outreach message.');
  end if;
  s := acq.setting(l.org_id, 'sender', '{}'::jsonb);
  select count(*) into n from acq.outreach_messages where lead_id = l.id and step = 0;
  insert into acq.outreach_messages (org_id, lead_id, campaign_id, kind, channel, step, to_address, from_address, reply_to, subject, body,
                                     status, approval_status, generated_by, ai_model, idempotency_key)
  values (l.org_id, l.id, c.id, 'outreach', c.channel, 0, to_addr,
          case c.channel when 'email' then nullif(s->>'from_email', '') else nullif(s->>'sms_from', '') end,
          nullif(coalesce(s->>'reply_to_email', s->>'from_email'), ''),
          case when c.channel = 'email' then subj end, btrim(p_body), 'pending_approval', 'pending', 'ai', left(p_model, 80),
          'draft:' || l.id || ':0:' || n)
  returning id into mid;
  update acq.leads set draft_locked_until = null, draft_error = null, draft_attempts = 0, redraft_requested_at = null where id = l.id;
  return jsonb_build_object('ok', true, 'message_id', mid);
end $$;

-- ---------------------------------------------------------------------
-- Approval (frontend RPCs; role + org re-checked)
-- ---------------------------------------------------------------------

create or replace function acq.edit_draft(p_message uuid, p_subject text, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); m acq.outreach_messages; err text;
begin
  select * into m from acq.outreach_messages where id = p_message and org_id = o for update;
  if m.id is null then perform acq.fail('message_not_found', 'Message not found.'); end if;
  if m.status <> 'pending_approval' then perform acq.fail('not_editable', 'Only drafts waiting for approval can be edited.'); end if;
  err := acq.check_draft(m.channel, nullif(btrim(coalesce(p_subject, '')), ''), p_body, false);
  if err is not null then perform acq.fail('invalid_draft', err); end if;
  update acq.outreach_messages set subject = case when m.channel = 'email' then btrim(p_subject) end, body = btrim(p_body), generated_by = 'human' where id = m.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function acq.approve_message(p_message uuid, p_subject text default null, p_body text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); m acq.outreach_messages; l acq.leads; err text; subj text; bod text;
begin
  select * into m from acq.outreach_messages where id = p_message and org_id = o for update;
  if m.id is null then perform acq.fail('message_not_found', 'Message not found.'); end if;
  if m.status <> 'pending_approval' then perform acq.fail('not_pending', 'This message is not waiting for approval (it is ' || m.status || ').'); end if;
  select * into l from acq.leads where id = m.lead_id for update;
  if l.do_not_contact or acq.is_suppressed(l.org_id, l.email, l.phone_e164, l.domain) then perform acq.fail('do_not_contact', 'This lead must not be contacted.'); end if;
  if m.kind = 'outreach' and l.status <> 'qualified' then perform acq.fail('lead_not_qualified', 'The lead is ' || l.status || ', not Qualified.'); end if;
  if m.kind = 'followup' and l.status <> 'contacted' then perform acq.fail('lead_not_contacted', 'Follow-ups only go to leads still in Contacted.'); end if;
  if m.kind = 'reply' and l.status in ('lost', 'won', 'new_lead', 'qualified', 'approved') then perform acq.fail('lead_status', 'The lead is ' || l.status || '.'); end if;
  if m.channel = 'sms' and not acq.setting_bool(o, 'sms_outreach_enabled', false) and m.kind <> 'reply' then perform acq.fail('sms_disabled', 'SMS outreach is disabled.'); end if;
  subj := coalesce(nullif(btrim(coalesce(p_subject, '')), ''), m.subject); bod := coalesce(nullif(btrim(coalesce(p_body, '')), ''), m.body);
  err := acq.check_draft(m.channel, subj, bod, false);
  if err is not null then perform acq.fail('invalid_draft', err); end if;

  update acq.outreach_messages set subject = subj, body = bod,
         generated_by = case when subj is distinct from m.subject or bod is distinct from m.body then 'human' else generated_by end,
         approval_status = 'approved', approval_source = 'user', approved_by = auth.uid(), approved_at = now(),
         status = 'approved', scheduled_at = coalesce(scheduled_at, now())
   where id = m.id;
  if m.kind = 'outreach' then
    perform set_config('acq.reason', 'message_approved', true);
    update acq.leads set status = 'approved' where id = l.id;
    perform set_config('acq.reason', '', true);
  end if;
  return jsonb_build_object('ok', true, 'message_id', m.id, 'status', 'approved');
end $$;

create or replace function acq.reject_message(p_message uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); m acq.outreach_messages;
begin
  select * into m from acq.outreach_messages where id = p_message and org_id = o for update;
  if m.id is null then perform acq.fail('message_not_found', 'Message not found.'); end if;
  if m.status not in ('pending_approval', 'draft') then perform acq.fail('not_pending', 'Only drafts waiting for approval can be rejected.'); end if;
  update acq.outreach_messages set status = 'rejected', approval_status = 'rejected', rejected_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300) where id = m.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function acq.approve_messages(p_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); id uuid; r jsonb := '[]'::jsonb; res jsonb;
begin
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 50 then perform acq.fail('invalid_batch', 'Approve 1-50 messages at a time.'); end if;
  foreach id in array p_ids loop
    begin
      res := acq.approve_message(id);
    exception when others then
      res := jsonb_build_object('ok', false, 'message_id', id, 'error', sqlerrm);
    end;
    r := r || jsonb_build_array(res);
  end loop;
  return jsonb_build_object('ok', true, 'results', r);
end $$;

create or replace function acq.redraft_lead(p_lead uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member');
begin
  if not exists (select 1 from acq.leads where id = p_lead and org_id = o and status = 'qualified' and not do_not_contact) then
    perform acq.fail('lead_not_found', 'Lead not found or not Qualified.'); end if;
  if exists (select 1 from acq.outreach_messages where lead_id = p_lead and step = 0 and status not in ('failed', 'cancelled', 'rejected')) then
    perform acq.fail('draft_exists', 'This lead already has a live outreach message.'); end if;
  update acq.leads set redraft_requested_at = now(), draft_attempts = 0, draft_locked_until = null, draft_error = null where id = p_lead;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Sending (n8n sender) — every gate lives here
-- ---------------------------------------------------------------------

create or replace function acq.html_escape(p text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$$;

create or replace function acq.claim_outbound(p_limit int default 1)
returns setof jsonb language plpgsql as $$
declare
  m acq.outreach_messages; l acq.leads; s jsonb; lim jsonb; cap int; n int; gap int; considered int := 0; given int := 0;
  claimed_orgs uuid[] := '{}'; url text; dom text; unsub text; footer text; day0 timestamptz; blocker text; last_sent timestamptz; payload jsonb;
begin
  for m in
    select x.* from acq.outreach_messages x join acq.organizations o on o.id = x.org_id and o.status = 'active' and o.outreach_enabled
    where (x.status = 'approved' and (x.scheduled_at is null or x.scheduled_at <= now()))
       or (x.status = 'sending' and x.locked_until < now())
    order by x.scheduled_at nulls first, x.created_at limit 60 for update of x skip locked
  loop
    exit when given >= least(greatest(p_limit, 1), 5);
    considered := considered + 1;
    if m.attempts >= m.max_attempts then
      update acq.outreach_messages set status = 'failed', last_error = coalesce(last_error, 'max_attempts'), locked_until = null where id = m.id;
      continue;
    end if;
    select * into l from acq.leads where id = m.lead_id;
    -- permanent blockers: cancel rather than wait
    blocker := case
      when l.do_not_contact then 'do_not_contact'
      when acq.is_suppressed(l.org_id, l.email, l.phone_e164, l.domain) then 'suppressed'
      when l.status in ('lost', 'won') then 'lead_' || l.status
      when m.kind = 'outreach' and l.status <> 'approved' then 'lead_status_' || l.status
      when m.kind = 'followup' and l.status <> 'contacted' then 'lead_status_' || l.status
      end;
    if blocker is not null then
      update acq.outreach_messages set status = 'cancelled', last_error = blocker, locked_until = null where id = m.id;
      continue;
    end if;
    -- soft blockers: leave the message approved and try again later
    if m.org_id = any (claimed_orgs) then continue; end if;
    if acq.sender_problem(m.org_id) is not null and m.channel = 'email' then continue; end if;
    if not acq.in_send_window(m.org_id) then continue; end if;
    s := acq.setting(m.org_id, 'sender', '{}'::jsonb);
    if m.channel = 'sms' and (not acq.setting_bool(m.org_id, 'sms_outreach_enabled', false) or coalesce(s->>'sms_from', '') = '' or coalesce(s->>'twilio_account_sid', '') = '') then continue; end if;
    day0 := acq.day_start(m.org_id);
    lim := acq.setting(m.org_id, 'daily_send_limit', '{"email":0,"sms":0}'::jsonb);
    cap := coalesce((lim->>m.channel)::int, 0);
    select count(*) into n from acq.outreach_messages
     where org_id = m.org_id and channel = m.channel and id <> m.id and (sent_at >= day0 or (status = 'sending' and locked_until > now()));
    if n >= cap then continue; end if;
    if m.campaign_id is not null then
      select count(*) into n from acq.outreach_messages
       where campaign_id = m.campaign_id and id <> m.id and (sent_at >= day0 or (status = 'sending' and locked_until > now()));
      if n >= (select daily_limit from acq.outreach_campaigns where id = m.campaign_id) then continue; end if;
    end if;
    if m.channel = 'email' then
      dom := lower(split_part(m.to_address, '@', 2));
      select count(*) into n from acq.outreach_messages
       where org_id = m.org_id and channel = 'email' and id <> m.id and lower(split_part(to_address, '@', 2)) = dom
         and (sent_at >= day0 or (status = 'sending' and locked_until > now()));
      if n >= acq.setting_int(m.org_id, 'per_domain_daily_limit', 1) then continue; end if;
    end if;
    gap := acq.setting_int(m.org_id, 'min_send_gap_seconds', 120);
    select max(greatest(sent_at, case when status = 'sending' then locked_until - interval '5 minutes' end)) into last_sent
      from acq.outreach_messages where org_id = m.org_id and id <> m.id and (sent_at >= now() - interval '1 day' or (status = 'sending' and locked_until > now()));
    if last_sent is not null and last_sent + make_interval(secs => gap) > now() then continue; end if;

    url := acq.setting(m.org_id, 'tracking_base_url', '""'::jsonb) #>> '{}';
    unsub := rtrim(url, '/') || '/unsubscribe?t=' || m.unsubscribe_token;
    if m.channel = 'email' then
      footer := E'\n\n--\n' || coalesce(s->>'from_name', '') || E'\n' || coalesce(s->>'postal_address', '') ||
                E'\nNot interested? Unsubscribe here: ' || unsub;
      payload := jsonb_build_object('kind', 'email', 'provider', 'resend', 'message_id', m.id,
        'from', (s->>'from_name') || ' <' || (s->>'from_email') || '>', 'to', m.to_address, 'reply_to', coalesce(m.reply_to, s->>'from_email'),
        'subject', m.subject, 'text', m.body || footer,
        'html', '<div>' || (select string_agg('<p>' || replace(acq.html_escape(p), E'\n', '<br>') || '</p>', '' order by ord)
                             from unnest(regexp_split_to_array(btrim(m.body), E'\n{2,}')) with ordinality t(p, ord)) ||
                '<p style="color:#666;font-size:12px">' || acq.html_escape(coalesce(s->>'from_name', '')) || '<br>' ||
                replace(acq.html_escape(coalesce(s->>'postal_address', '')), E'\n', '<br>') ||
                '<br>Not interested? <a href="' || acq.html_escape(unsub) || '">Unsubscribe</a></p></div>',
        'headers', jsonb_build_object('List-Unsubscribe', '<' || unsub || '>', 'List-Unsubscribe-Post', 'List-Unsubscribe=One-Click'),
        'tags', jsonb_build_array(jsonb_build_object('name', 'message_id', 'value', m.id::text)),
        'idempotency_key', 'acq-' || m.id::text);
    else
      payload := jsonb_build_object('kind', 'sms', 'provider', 'twilio', 'message_id', m.id, 'account_sid', s->>'twilio_account_sid',
        'to', m.to_address, 'from', s->>'sms_from', 'body', m.body || ' Reply STOP to opt out.');
    end if;
    update acq.outreach_messages set status = 'sending', attempts = attempts + 1, locked_until = now() + interval '5 minutes',
           provider = payload->>'provider', scheduled_at = coalesce(scheduled_at, now()) where id = m.id;
    claimed_orgs := claimed_orgs || m.org_id;
    given := given + 1;
    return next payload;
  end loop;
end $$;

create or replace function acq.complete_outbound(p_message uuid, p_http_status int, p_body jsonb, p_error text default null)
returns jsonb language plpgsql as $$
declare m acq.outreach_messages; l acq.leads; ok boolean; permanent boolean; pid text; err text;
begin
  select * into m from acq.outreach_messages where id = p_message for update;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'message_not_found'); end if;
  if m.status <> 'sending' then return jsonb_build_object('ok', true, 'note', 'already ' || m.status); end if;
  ok := coalesce(p_http_status, 0) between 200 and 299;
  pid := coalesce(p_body->>'id', p_body->>'sid');
  if ok and pid is not null then
    update acq.outreach_messages set status = 'sent', sent_at = now(), provider_message_id = pid, locked_until = null, last_error = null where id = m.id;
    select * into l from acq.leads where id = m.lead_id for update;
    if m.kind in ('outreach', 'followup') then
      update acq.leads set last_contacted_at = now() where id = l.id;
      if l.status = 'approved' then
        perform set_config('acq.reason', 'message_sent', true);
        update acq.leads set status = 'contacted' where id = l.id;
        perform set_config('acq.reason', '', true);
      end if;
    end if;
    return jsonb_build_object('ok', true, 'status', 'sent');
  end if;
  err := left(coalesce(p_error, '') || ' http=' || coalesce(p_http_status::text, 'none') || ' ' ||
              coalesce(p_body->>'message', p_body #>> '{error,message}', p_body->>'name', ''), 400);
  permanent := p_http_status between 400 and 499 and p_http_status not in (401, 403, 408, 409, 425, 429);
  if ok then permanent := false; err := 'no_provider_id ' || err; end if;
  update acq.outreach_messages
     set status = case when permanent or m.attempts >= m.max_attempts then 'failed' else 'approved' end,
         scheduled_at = now() + make_interval(mins => case when p_http_status in (401, 403) then 30 else 5 * m.attempts end),
         locked_until = null, last_error = err
   where id = m.id;
  return jsonb_build_object('ok', false, 'status', case when permanent or m.attempts >= m.max_attempts then 'failed' else 'retry' end);
end $$;

-- ---------------------------------------------------------------------
-- Delivery events (Resend / Twilio) + reputation guard
-- ---------------------------------------------------------------------

create or replace function acq.guard_reputation(p_org uuid)
returns boolean language plpgsql as $$
declare sent_n int; bounced_n int; complaints int;
begin
  select count(*) filter (where sent_at >= now() - interval '7 days'),
         count(*) filter (where bounced_at >= now() - interval '7 days'),
         count(*) filter (where status = 'complained' and updated_at >= now() - interval '7 days')
    into sent_n, bounced_n, complaints from acq.outreach_messages where org_id = p_org and channel = 'email';
  if complaints >= 2 or (sent_n >= 20 and bounced_n::numeric / sent_n > 0.08) then
    update acq.organizations set outreach_enabled = false where id = p_org and outreach_enabled;
    if found then
      perform acq.activity(p_org, 'outreach.auto_paused', 'organization', p_org::text, null,
        jsonb_build_object('sent_7d', sent_n, 'bounced_7d', bounced_n, 'complaints_7d', complaints), 'system');
      return true;
    end if;
  end if;
  return false;
end $$;

create or replace function acq.record_delivery_event(p_provider text, p_event_id text, p_type text, p_provider_message_id text,
                                                     p_at timestamptz default null, p_meta jsonb default '{}'::jsonb)
returns jsonb language plpgsql as $$
declare m acq.outreach_messages; at_ts timestamptz := coalesce(p_at, now()); paused boolean := false; hard boolean;
begin
  if p_provider not in ('resend', 'twilio') then perform acq.fail('invalid_provider', 'Unknown provider.'); end if;
  if coalesce(p_event_id, '') <> '' then
    insert into acq.webhook_events (provider, event_id) values (p_provider, p_event_id) on conflict do nothing;
    if not found then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  end if;
  select * into m from acq.outreach_messages where provider = p_provider and provider_message_id = p_provider_message_id for update;
  if m.id is null then return jsonb_build_object('ok', true, 'matched', false); end if;
  if auth.uid() is null then perform set_config('acq.actor', coalesce(nullif(current_setting('acq.actor', true), ''), 'edge'), true); end if;

  case p_type
    when 'email.delivered', 'sms.delivered' then
      update acq.outreach_messages set delivered_at = coalesce(delivered_at, at_ts), status = case when status = 'sent' then 'delivered' else status end where id = m.id;
    when 'email.opened' then
      update acq.outreach_messages set opened_at = coalesce(opened_at, at_ts), open_count = open_count + 1,
             status = case when status in ('sent', 'delivered') then 'opened' else status end where id = m.id;
    when 'email.clicked' then
      update acq.outreach_messages set clicked_at = coalesce(clicked_at, at_ts), click_count = click_count + 1,
             status = case when status in ('sent', 'delivered', 'opened') then 'clicked' else status end where id = m.id;
    when 'email.bounced' then
      hard := lower(coalesce(p_meta->>'bounce_type', 'permanent')) = 'permanent';
      if hard then
        update acq.outreach_messages set status = 'bounced', bounced_at = coalesce(bounced_at, at_ts), last_error = left('bounce: ' || coalesce(p_meta->>'bounce_message', ''), 300) where id = m.id;
        perform acq.suppress_lead(m.lead_id, 'bounce', 'resend');
        paused := acq.guard_reputation(m.org_id);
      else
        update acq.outreach_messages set last_error = left('soft bounce: ' || coalesce(p_meta->>'bounce_message', ''), 300) where id = m.id;
      end if;
    when 'email.complained' then
      update acq.outreach_messages set status = 'complained', last_error = 'spam complaint' where id = m.id;
      perform acq.suppress_lead(m.lead_id, 'complaint', 'resend');
      paused := acq.guard_reputation(m.org_id);
    when 'email.suppressed' then
      update acq.outreach_messages set status = 'bounced', bounced_at = coalesce(bounced_at, at_ts), last_error = 'suppressed by provider' where id = m.id;
      perform acq.suppress_lead(m.lead_id, 'bounce', 'resend_suppressed');
    when 'email.failed', 'sms.failed' then
      update acq.outreach_messages set status = case when status in ('sent', 'delivered') then status else 'failed' end,
             last_error = left('provider failure: ' || coalesce(p_meta->>'reason', ''), 300) where id = m.id;
    when 'email.delivery_delayed' then
      update acq.outreach_messages set last_error = 'delivery delayed' where id = m.id and status in ('sent', 'delivered');
    else null;   -- email.sent / email.scheduled / unknown: nothing to do
  end case;
  return jsonb_build_object('ok', true, 'matched', true, 'message_id', m.id, 'auto_paused', paused);
end $$;

create or replace function acq.unsubscribe_by_token(p_token text)
returns jsonb language plpgsql as $$
declare m acq.outreach_messages;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', true, 'found', false); end if;
  select * into m from acq.outreach_messages where unsubscribe_token = p_token;
  if m.id is null then return jsonb_build_object('ok', true, 'found', false); end if;
  if auth.uid() is null then perform set_config('acq.actor', 'edge', true); end if;
  perform acq.suppress_lead(m.lead_id, 'unsubscribe', 'email_link');
  return jsonb_build_object('ok', true, 'found', true);
end $$;

-- ---------------------------------------------------------------------
-- Read model: approval queue
-- ---------------------------------------------------------------------

create or replace view acq.v_outreach with (security_invoker = true) as
select m.id, m.org_id, m.lead_id, l.business_name, l.niche, l.city, l.score, l.status as lead_status, m.campaign_id, m.kind, m.channel, m.step,
       m.to_address, m.subject, m.body, m.status, m.approval_status, m.generated_by, m.ai_model, m.created_at, m.scheduled_at, m.sent_at,
       m.delivered_at, m.opened_at, m.clicked_at, m.bounced_at, m.open_count, m.click_count, m.last_error
from acq.outreach_messages m join acq.leads l on l.id = m.lead_id and l.org_id = m.org_id;

-- ---------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------

revoke execute on all functions in schema acq from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on all tables in schema acq to authenticated;
    revoke select on acq.rate_limits, acq.webhook_events from authenticated;
    grant execute on function acq.edit_draft(uuid, text, text), acq.approve_message(uuid, text, text), acq.reject_message(uuid, text),
                              acq.approve_messages(uuid[]), acq.redraft_lead(uuid), acq.update_setting(text, jsonb),
                              acq.set_outreach_enabled(boolean) to authenticated;
    grant execute on function acq.status_allowed(text, text), acq.status_rank(text), acq.setting_int(uuid, text, int),
                              acq.setting_bool(uuid, text, boolean), acq.import_leads(jsonb, text), acq.move_lead(uuid, text, text),
                              acq.mark_do_not_contact(uuid, text), acq.erase_lead(uuid), acq.reinstate_lead(uuid), acq.requalify_lead(uuid),
                              acq.queue_search_run(text, text, text, text, text, int) to authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant all on all tables in schema acq to service_role;
    grant execute on all functions in schema acq to service_role;
    grant usage, select on all sequences in schema acq to service_role;
  end if;
end $$;
revoke execute on function acq.create_organization(text, text, text) from public;
