-- =====================================================================
-- ACQ Phase 4 — replies (intake, matching, classification, approved responses), demos (token pages + tracking),
-- meetings (public slot booking, Google Calendar sync queue).
-- Re-runnable. Additive only (no drops of data). Requires 020, 021, 022.
--
-- Trust model:
--   * service-only functions (n8n / edge functions with the service role): ingest_reply, claim_replies_for_classification,
--     classification_failed, apply_classification, demo_view, demo_click, meeting_slots, book_meeting,
--     claim_meeting_calendar, complete_meeting_calendar
--   * user RPCs (SECURITY DEFINER + acq.require_role): reply responses, demos, meetings
--   * nothing here ever sends a message without a person approving it first
-- =====================================================================

alter table acq.replies add column if not exists classify_attempts int not null default 0;
alter table acq.replies add column if not exists classify_locked_until timestamptz;
alter table acq.replies add column if not exists classify_error text;
create index if not exists replies_to_classify on acq.replies (received_at) where classification = 'unclassified';
create index if not exists meetings_calendar_queue on acq.meetings (calendar_sync, calendar_locked_until) where calendar_sync in ('pending', 'processing');
create index if not exists meetings_org_time on acq.meetings (org_id, starts_at) where status = 'scheduled';

-- RFC 3986 percent-encoding (calendar ids / event ids go into URL paths)
create or replace function acq.urlenc(p text)
returns text language sql immutable as $$
  select coalesce(string_agg(case when x.c ~ '^[A-Za-z0-9._~-]$' then x.c
                                  else (select string_agg('%' || upper(lpad(to_hex(get_byte(x.b, i)), 2, '0')), '' order by i) from generate_series(0, length(x.b) - 1) i) end, '' order by x.ord), '')
  from (select t.ch as c, t.ord, convert_to(t.ch, 'UTF8') as b from regexp_split_to_table(coalesce(p, ''), '') with ordinality t(ch, ord)) x
$$;

-- ---------------------------------------------------------------------
-- Reply text helpers
-- ---------------------------------------------------------------------

-- The part of an email the person actually wrote (drops quoted history). Heuristic: only used for classification.
create or replace function acq.reply_fresh_text(p text)
returns text language sql immutable as $$
  select left(btrim(coalesce((regexp_split_to_array(replace(coalesce(p, ''), E'\r', ''),
           E'\n(?=On [^\n]{5,200} wrote:|-{2,} ?Original Message|From: [^\n]{3,200}\n|>)'))[1], '')), 4000)
$$;

create or replace function acq.addr_of(p text)
returns text language sql immutable as $$
  select acq.norm_email(coalesce((regexp_match(coalesce(p, ''), '<([^<>]+)>'))[1], p))
$$;

create or replace function acq.org_for_inbound(p_to text)
returns uuid language plpgsql stable as $$
declare a text := acq.addr_of(p_to); orgs uuid[];
begin
  if a is null then return null; end if;
  a := regexp_replace(a, '\+[^@]*@', '@');                      -- jay+tag@x.com -> jay@x.com
  select array_agg(distinct s.org_id) into orgs from acq.system_settings s
   where s.key = 'sender' and (lower(s.value->>'from_email') = a or lower(s.value->>'reply_to_email') = a);
  if orgs is null or cardinality(orgs) <> 1 then return null; end if;
  return orgs[1];
end $$;

create or replace function acq.match_reply(p_org uuid, p_from text, p_in_reply_to text)
returns table (lead_id uuid, message_id uuid) language plpgsql stable as $$
declare ids text[]; dom text := split_part(p_from, '@', 2); n int;
  freemail text[] := array['gmail.com','googlemail.com','yahoo.com','yahoo.co.uk','outlook.com','hotmail.com','hotmail.co.uk','live.com','live.co.uk',
                           'icloud.com','me.com','msn.com','aol.com','proton.me','protonmail.com','btinternet.com','sky.com','talktalk.net'];
begin
  -- 1) the reply references a message we sent (provider id appears in In-Reply-To / References)
  ids := coalesce(array(select distinct x[1] from regexp_matches(coalesce(p_in_reply_to, ''), '([A-Za-z0-9_-]{8,100})', 'g') x), '{}');
  if cardinality(ids) > 0 then
    return query select m.lead_id, m.id from acq.outreach_messages m
     where m.org_id = p_org and m.provider_message_id = any (ids) order by m.sent_at desc nulls last limit 1;
    if found then return; end if;
  end if;
  -- 2) exact address of a lead we have written to
  return query select l.id, (select m.id from acq.outreach_messages m where m.lead_id = l.id and m.sent_at is not null order by m.sent_at desc limit 1)
    from acq.leads l where l.org_id = p_org and l.email = p_from
    order by l.last_contacted_at desc nulls last limit 1;
  if found then return; end if;
  -- 3) same business domain (never for free-mail domains), only when it is unambiguous
  if dom <> '' and not (dom = any (freemail)) then
    select count(*) into n from acq.leads l where l.org_id = p_org and l.domain = dom;
    if n = 1 then
      return query select l.id, (select m.id from acq.outreach_messages m where m.lead_id = l.id and m.sent_at is not null order by m.sent_at desc limit 1)
        from acq.leads l where l.org_id = p_org and l.domain = dom;
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Reply intake (service only). One call per inbound email. Idempotent on the provider message id.
-- ---------------------------------------------------------------------

create or replace function acq.ingest_reply(p_to text, p_from text, p_subject text, p_body text, p_provider_id text,
                                            p_in_reply_to text default null, p_received_at timestamptz default null,
                                            p_headers jsonb default '{}'::jsonb, p_org uuid default null)
returns jsonb language plpgsql as $$
declare
  v_org uuid := coalesce(p_org, acq.org_for_inbound(p_to)); v_from text := acq.addr_of(p_from);
  v_lead uuid; v_msg uuid; l acq.leads; v_hdr jsonb; v_auto boolean; v_fresh text; v_cls text := 'unclassified'; v_by text;
  v_pid text; v_id uuid; v_unsub boolean; v_recent int; v_subj text := acq.clip(p_subject, 500);
begin
  if v_org is null then return jsonb_build_object('ok', true, 'action', 'ignored', 'reason', 'unknown_recipient'); end if;
  if not exists (select 1 from acq.organizations where id = v_org and status = 'active') then
    return jsonb_build_object('ok', true, 'action', 'ignored', 'reason', 'org_inactive');
  end if;
  if v_from is null then return jsonb_build_object('ok', true, 'action', 'ignored', 'reason', 'invalid_sender'); end if;
  if coalesce(btrim(p_body), '') = '' then return jsonb_build_object('ok', true, 'action', 'ignored', 'reason', 'empty_body'); end if;
  if auth.uid() is null then perform set_config('acq.actor', coalesce(nullif(current_setting('acq.actor', true), ''), 'n8n'), true); end if;

  -- lower-case, bounded copy of the interesting headers
  select coalesce(jsonb_object_agg(lower(k), left(v #>> '{}', 300)), '{}'::jsonb) into v_hdr
    from (select e.key k, e.value v from jsonb_each(case when jsonb_typeof(p_headers) = 'object' then p_headers else '{}'::jsonb end) e limit 40) h;

  -- bounce notices belong to the delivery-event path, not to replies
  if split_part(v_from, '@', 1) in ('mailer-daemon', 'postmaster') or lower(coalesce(v_hdr->>'content-type', '')) like '%report-type=delivery-status%' then
    return jsonb_build_object('ok', true, 'action', 'ignored', 'reason', 'bounce_notice');
  end if;
  v_auto := lower(coalesce(v_hdr->>'auto-submitted', 'no')) <> 'no' or v_hdr ? 'x-autoreply' or v_hdr ? 'x-autorespond'
            or lower(coalesce(v_hdr->>'precedence', '')) in ('bulk', 'auto_reply', 'junk')
            or coalesce(v_subj, '') ~* '^(automatic reply|auto(matic)?[- ]?reply|out of office)';

  -- flood guard: one address cannot fill the inbox
  select count(*) into v_recent from acq.replies where org_id = v_org and from_address = v_from and created_at > now() - interval '1 day';
  if v_recent >= 20 then return jsonb_build_object('ok', true, 'action', 'ignored', 'reason', 'flood'); end if;

  v_pid := coalesce(nullif(btrim(p_provider_id), ''), 'md5:' || md5(v_from || '|' || coalesce(v_subj, '') || '|' || p_body));
  if exists (select 1 from acq.replies where org_id = v_org and channel = 'email' and provider_message_id = v_pid) then
    return jsonb_build_object('ok', true, 'action', 'duplicate');
  end if;

  select m.lead_id, m.message_id into v_lead, v_msg from acq.match_reply(v_org, v_from, p_in_reply_to) m;
  v_fresh := acq.reply_fresh_text(p_body);

  -- cheap, safe rules first: out-of-office, and clear "remove me" requests (acted on immediately, no AI needed)
  v_unsub := lower(left(v_fresh, 600)) ~ '\m(unsubscribe|remove me|take me off|stop (emailing|contacting|sending|messaging)|do not (contact|email)|don''t (contact|email)|opt[- ]?out)\M';
  if v_auto then v_cls := 'out_of_office'; v_by := 'rules';
  elsif v_unsub then v_cls := 'unsubscribe'; v_by := 'rules'; end if;

  insert into acq.replies (org_id, lead_id, message_id, match_status, channel, from_address, to_address, subject, body, provider_message_id,
                           in_reply_to, received_at, classification, classified_by, raw)
  values (v_org, v_lead, v_msg, case when v_lead is null then 'unmatched' else 'matched' end, 'email', v_from, acq.addr_of(p_to), v_subj,
          left(p_body, 20000), v_pid, acq.clip(p_in_reply_to, 500), coalesce(p_received_at, now()), v_cls, v_by,
          jsonb_build_object('headers', v_hdr))
  returning id into v_id;

  if v_lead is not null then
    select * into l from acq.leads where id = v_lead for update;
    if v_cls = 'unsubscribe' then
      perform acq.suppress_lead(v_lead, 'unsubscribe', 'reply_rules');
      update acq.replies set handled_at = now() where id = v_id;
    elsif v_cls <> 'out_of_office' and l.status in ('contacted', 'demo_sent', 'meeting_booked') then
      perform set_config('acq.reason', 'reply_received', true);
      update acq.leads set status = 'replied' where id = v_lead;       -- trigger stops follow-ups
      perform set_config('acq.reason', '', true);
    end if;
    if v_cls <> 'out_of_office' then update acq.leads set last_reply_at = now() where id = v_lead; end if;
  end if;
  return jsonb_build_object('ok', true, 'action', 'stored', 'reply_id', v_id, 'matched', v_lead is not null, 'classification', v_cls);
end $$;

-- ---------------------------------------------------------------------
-- Classification (n8n + AI). The AI only labels and drafts; it never sends.
-- ---------------------------------------------------------------------

create or replace function acq.claim_replies_for_classification(p_limit int default 5)
returns setof jsonb language plpgsql as $$
declare r acq.replies; l acq.leads; o acq.outreach_messages;
begin
  for r in
    select x.* from acq.replies x join acq.organizations g on g.id = x.org_id and g.status = 'active'
    where x.classification = 'unclassified' and x.classify_attempts < 3
      and (x.classify_locked_until is null or x.classify_locked_until < now())
    order by x.received_at limit least(greatest(p_limit, 1), 10) for update of x skip locked
  loop
    update acq.replies set classify_attempts = classify_attempts + 1, classify_locked_until = now() + interval '10 minutes' where id = r.id;
    select * into l from acq.leads where id = r.lead_id;
    select * into o from acq.outreach_messages where id = r.message_id;
    return next jsonb_build_object('reply_id', r.id, 'org_id', r.org_id, 'channel', r.channel, 'matched', r.lead_id is not null,
      'from_address', r.from_address, 'subject', r.subject, 'text', acq.reply_fresh_text(r.body),
      'business_name', l.business_name, 'niche', l.niche, 'city', l.city, 'lead_status', l.status,
      'our_subject', o.subject, 'our_body', left(o.body, 1500),
      'sender_name', acq.setting(r.org_id, 'sender', '{}'::jsonb) ->> 'from_name',
      'offer_context', acq.setting(r.org_id, 'offer_context', '""'::jsonb) #>> '{}',
      'meeting_enabled', coalesce(acq.setting(r.org_id, 'demo_base_url', '""'::jsonb) #>> '{}', '') <> '',
      'model', coalesce(acq.setting(r.org_id, 'ai', '{}'::jsonb) ->> 'model', 'gpt-5-mini'));
  end loop;
end $$;

create or replace function acq.classification_failed(p_reply uuid, p_error text)
returns jsonb language plpgsql as $$
begin
  update acq.replies set classify_error = left(coalesce(p_error, 'failed'), 300),
         classify_locked_until = now() + make_interval(mins => 10 * greatest(classify_attempts, 1)) where id = p_reply;
  return jsonb_build_object('ok', found);
end $$;

create or replace function acq.apply_classification(p_reply uuid, p_result jsonb, p_model text default null)
returns jsonb language plpgsql as $$
declare
  r acq.replies; v_cls text := lower(coalesce(p_result->>'classification', '')); v_conf numeric;
  v_sug text := acq.clip(p_result->>'suggested_response', 2000); v_err text; v_sum text := acq.clip(p_result->>'summary', 500);
begin
  select * into r from acq.replies where id = p_reply for update;
  if r.id is null then perform acq.fail('reply_not_found', 'Reply not found.'); end if;
  if r.classification <> 'unclassified' then return jsonb_build_object('ok', true, 'note', 'already ' || r.classification); end if;
  if v_cls not in ('positive', 'negative', 'question', 'not_interested', 'follow_up_needed', 'unsubscribe', 'out_of_office') then
    perform acq.fail('invalid_classification', 'Unknown classification.');
  end if;
  begin v_conf := least(greatest((p_result->>'confidence')::numeric, 0), 1); exception when others then v_conf := null; end;
  if auth.uid() is null then perform set_config('acq.actor', coalesce(nullif(current_setting('acq.actor', true), ''), 'n8n'), true); end if;

  -- a suggested reply is only kept for conversations worth answering, and must pass the same safety rules as AI drafts
  if v_cls not in ('positive', 'question', 'follow_up_needed') then v_sug := null; end if;
  if v_sug is not null then
    v_err := acq.check_draft('email', 'Re: reply', v_sug, true);
    if v_err is not null then v_sug := null; v_sum := left(coalesce(v_sum, '') || ' [suggested reply dropped: ' || v_err || ']', 500); end if;
  end if;
  if r.lead_id is null then v_sug := null; end if;

  update acq.replies set classification = v_cls, classification_confidence = v_conf, classified_by = left(coalesce(p_model, 'ai'), 80),
         summary = v_sum, suggested_response = v_sug, response_status = case when v_sug is not null then 'pending_approval' else 'none' end,
         classify_error = null, classify_locked_until = null
   where id = r.id;

  if r.lead_id is not null then
    if v_cls = 'unsubscribe' then
      perform acq.suppress_lead(r.lead_id, 'unsubscribe', 'reply_ai');
      update acq.replies set handled_at = now() where id = r.id;
    elsif v_cls in ('negative', 'not_interested') then
      perform acq.suppress_lead(r.lead_id, 'negative_reply', 'reply_ai');
      update acq.replies set handled_at = now() where id = r.id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'classification', v_cls, 'suggestion_pending', v_sug is not null);
end $$;

-- ---------------------------------------------------------------------
-- Reply responses: a person edits / approves / rejects the suggested answer. Approving queues a normal approved message.
-- ---------------------------------------------------------------------

create or replace function acq.edit_reply_response(p_reply uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); r acq.replies; err text;
begin
  select * into r from acq.replies where id = p_reply and org_id = o for update;
  if r.id is null then perform acq.fail('reply_not_found', 'Reply not found.'); end if;
  if r.response_status not in ('none', 'pending_approval', 'rejected') then perform acq.fail('not_editable', 'This response is already ' || r.response_status || '.'); end if;
  err := acq.check_draft('email', 'Re: reply', p_body, false);
  if err is not null then perform acq.fail('invalid_draft', err); end if;
  update acq.replies set suggested_response = btrim(p_body), response_status = 'pending_approval' where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function acq.approve_reply_response(p_reply uuid, p_body text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o uuid := acq.require_role('member'); r acq.replies; l acq.leads; s jsonb; bod text; err text; mid uuid; subj text; n int;
begin
  select * into r from acq.replies where id = p_reply and org_id = o for update;
  if r.id is null then perform acq.fail('reply_not_found', 'Reply not found.'); end if;
  if r.response_status <> 'pending_approval' then perform acq.fail('not_pending', 'There is no response waiting for approval.'); end if;
  if r.lead_id is null then perform acq.fail('unmatched_reply', 'Match this reply to a lead before answering.'); end if;
  select * into l from acq.leads where id = r.lead_id for update;
  if l.do_not_contact or acq.is_suppressed(o, r.from_address, l.phone_e164, l.domain) or acq.is_suppressed(o, l.email, l.phone_e164, l.domain) then
    perform acq.fail('do_not_contact', 'This contact must not be emailed.');
  end if;
  bod := btrim(coalesce(p_body, r.suggested_response));
  err := acq.check_draft('email', 'Re: reply', bod, false);
  if err is not null then perform acq.fail('invalid_draft', err); end if;
  s := acq.setting(o, 'sender', '{}'::jsonb);
  subj := left('Re: ' || regexp_replace(coalesce(r.subject, 'your message'), '^(re|fwd?):\s*', '', 'i'), 150);
  select count(*) into n from acq.outreach_messages where lead_id = l.id and kind = 'reply';
  insert into acq.outreach_messages (org_id, lead_id, campaign_id, kind, channel, step, to_address, from_address, reply_to, subject, body,
                                     status, approval_status, approval_source, approved_by, approved_at, generated_by, idempotency_key, scheduled_at)
  values (o, l.id, null, 'reply', 'email', null, r.from_address, nullif(s->>'from_email', ''), nullif(coalesce(s->>'reply_to_email', s->>'from_email'), ''),
          subj, bod, 'approved', 'approved', 'user', auth.uid(), now(),
          case when p_body is null and r.suggested_response is not null then 'ai' else 'human' end,
          'reply:' || r.id || ':' || n, now())
  returning id into mid;
  update acq.replies set response_status = 'approved', response_message_id = mid, suggested_response = bod, handled_at = now() where id = r.id;
  perform acq.activity(o, 'reply.response_approved', 'reply', r.id::text, l.id, jsonb_build_object('message_id', mid));
  return jsonb_build_object('ok', true, 'message_id', mid);
end $$;

create or replace function acq.reject_reply_response(p_reply uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); n int;
begin
  update acq.replies set response_status = 'rejected' where id = p_reply and org_id = o and response_status = 'pending_approval';
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('not_pending', 'There is no response waiting for approval.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function acq.mark_reply_handled(p_reply uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); n int;
begin
  update acq.replies set handled_at = coalesce(handled_at, now()) where id = p_reply and org_id = o;
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('reply_not_found', 'Reply not found.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- A person can attach an unmatched reply to a lead (the only way an unmatched reply gets a lead).
create or replace function acq.match_reply_manually(p_reply uuid, p_lead uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); r acq.replies; l acq.leads;
begin
  select * into r from acq.replies where id = p_reply and org_id = o for update;
  if r.id is null or r.lead_id is not null then perform acq.fail('reply_not_found', 'Reply not found or already matched.'); end if;
  select * into l from acq.leads where id = p_lead and org_id = o for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  update acq.replies set lead_id = l.id, match_status = 'matched' where id = r.id;
  if r.classification not in ('out_of_office', 'unsubscribe') and l.status in ('contacted', 'demo_sent', 'meeting_booked') then
    perform set_config('acq.reason', 'reply_matched_manually', true);
    update acq.leads set status = 'replied', last_reply_at = now() where id = l.id;
    perform set_config('acq.reason', '', true);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- keep reply.response_status honest once the message actually leaves (or is stopped)
create or replace function acq.tg_outreach_reply_sync() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'reply' and new.status is distinct from old.status then
    if new.status in ('sent', 'delivered', 'opened', 'clicked') then
      update acq.replies set response_status = 'sent' where response_message_id = new.id and response_status = 'approved';
    elsif new.status in ('failed', 'cancelled', 'bounced', 'complained') then
      update acq.replies set response_status = 'rejected' where response_message_id = new.id and response_status = 'approved';
    end if;
  end if;
  -- a demo email that really went out: demo -> sent, lead -> Demo Sent
  if new.status in ('sent', 'delivered', 'opened', 'clicked') and old.status not in ('sent', 'delivered', 'opened', 'clicked') then
    if exists (select 1 from acq.demos d where d.sent_message_id = new.id) then
      update acq.demos set status = case when status in ('ready', 'draft') then 'sent' else status end, sent_at = coalesce(sent_at, now())
       where sent_message_id = new.id;
      perform set_config('acq.reason', 'demo_sent', true);
      update acq.leads set status = 'demo_sent'
       where id = new.lead_id and status in ('contacted', 'replied', 'meeting_booked') and not do_not_contact;
      perform set_config('acq.reason', '', true);
    end if;
  end if;
  return new;
end $$;
create or replace trigger tg_outreach_reply_sync after update of status on acq.outreach_messages
  for each row execute function acq.tg_outreach_reply_sync();

-- ---------------------------------------------------------------------
-- Demos
-- ---------------------------------------------------------------------

create or replace function acq.demo_url(p_org uuid, p_token text)
returns text language sql stable as $$
  select case when (acq.setting(p_org, 'demo_base_url', '""'::jsonb) #>> '{}') ~ '^https://'
              then (acq.setting(p_org, 'demo_base_url', '""'::jsonb) #>> '{}') || '?d=' || p_token end
$$;

-- Public demo content only. Plain text (no markup): the page must render it as text.
create or replace function acq.clean_demo_config(p_cfg jsonb, l acq.leads)
returns jsonb language plpgsql stable as $$
declare cfg jsonb := coalesce(p_cfg, '{}'::jsonb); k text; v jsonb; res jsonb; i int; q jsonb;
begin
  if jsonb_typeof(cfg) <> 'object' then perform acq.fail('invalid_config', 'config must be an object.'); end if;
  for k in select jsonb_object_keys(cfg) loop
    if k not in ('headline', 'subheadline', 'bullets', 'cta_text', 'receptionist_name', 'faqs', 'business_name') then
      perform acq.fail('invalid_config', 'Unknown demo field ' || k || '.');
    end if;
  end loop;
  if cfg::text ~ '[<>]' then perform acq.fail('invalid_config', 'Demo text cannot contain < or >.'); end if;
  res := jsonb_build_object(
    'business_name', coalesce(acq.clip(cfg->>'business_name', 120), l.business_name),
    'headline', coalesce(acq.clip(cfg->>'headline', 120), 'Never miss a booking again'),
    'subheadline', coalesce(acq.clip(cfg->>'subheadline', 200), 'An AI receptionist for ' || l.business_name || ' that answers every call and books straight into your diary.'),
    'cta_text', coalesce(acq.clip(cfg->>'cta_text', 60), 'Book a short walkthrough'),
    'receptionist_name', coalesce(acq.clip(cfg->>'receptionist_name', 40), 'Sophie'),
    'bullets', coalesce(case when jsonb_typeof(cfg->'bullets') = 'array' then to_jsonb(acq.text_array(cfg->'bullets', 6, 140)) end,
                        '["Answers every call, day and night","Books appointments straight into your calendar","Texts confirmations and reminders to cut no-shows","Handles reschedules and cancellations"]'::jsonb),
    'faqs', '[]'::jsonb);
  if jsonb_typeof(cfg->'faqs') = 'array' then
    if jsonb_array_length(cfg->'faqs') > 5 then perform acq.fail('invalid_config', 'At most 5 FAQs.'); end if;
    res := jsonb_set(res, '{faqs}', coalesce((select jsonb_agg(jsonb_build_object('q', left(btrim(f->>'q'), 120), 'a', left(btrim(f->>'a'), 300)))
                                                from jsonb_array_elements(cfg->'faqs') f where jsonb_typeof(f) = 'object' and coalesce(btrim(f->>'q'), '') <> '' and coalesce(btrim(f->>'a'), '') <> ''), '[]'::jsonb));
  end if;
  return res;
end $$;

create or replace function acq.create_demo(p_lead uuid, p_title text default null, p_config jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); l acq.leads; d acq.demos;
begin
  select * into l from acq.leads where id = p_lead and org_id = o for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  if l.do_not_contact then perform acq.fail('do_not_contact', 'This lead is marked do-not-contact.'); end if;
  if l.status in ('lost', 'won') then perform acq.fail('lead_closed', 'This lead is ' || l.status || '.'); end if;
  select * into d from acq.demos where lead_id = l.id and status not in ('expired', 'revoked');
  if d.id is not null then
    return jsonb_build_object('ok', true, 'demo_id', d.id, 'existing', true, 'url', acq.demo_url(o, d.token), 'status', d.status);
  end if;
  insert into acq.demos (org_id, lead_id, title, status, config, expires_at)
  values (o, l.id, acq.clip(coalesce(p_title, 'Demo for ' || l.business_name), 200), 'ready', acq.clean_demo_config(p_config, l), now() + interval '30 days')
  returning * into d;
  return jsonb_build_object('ok', true, 'demo_id', d.id, 'existing', false, 'url', acq.demo_url(o, d.token), 'status', d.status);
end $$;

create or replace function acq.revoke_demo(p_demo uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); n int;
begin
  update acq.demos set status = 'revoked' where id = p_demo and org_id = o and status not in ('revoked', 'expired');
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('demo_not_found', 'Demo not found or already closed.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- The person writes/confirms the email text; the system adds the link. Their click is the approval.
create or replace function acq.send_demo(p_demo uuid, p_subject text, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o uuid := acq.require_role('member'); d acq.demos; l acq.leads; s jsonb; url text; err text; mid uuid; n int; subj text := nullif(btrim(coalesce(p_subject, '')), '');
begin
  select * into d from acq.demos where id = p_demo and org_id = o for update;
  if d.id is null then perform acq.fail('demo_not_found', 'Demo not found.'); end if;
  if d.status not in ('ready', 'sent', 'opened', 'clicked') or d.expires_at <= now() then perform acq.fail('demo_closed', 'This demo is ' || d.status || '.'); end if;
  select * into l from acq.leads where id = d.lead_id for update;
  if l.do_not_contact or acq.is_suppressed(o, l.email, l.phone_e164, l.domain) then perform acq.fail('do_not_contact', 'This lead must not be contacted.'); end if;
  if l.email is null then perform acq.fail('no_recipient', 'The lead has no email address.'); end if;
  if l.status not in ('contacted', 'replied', 'meeting_booked', 'demo_sent') then
    perform acq.fail('lead_not_contacted', 'Send a demo only after the first message has gone out (lead is ' || l.status || ').');
  end if;
  url := acq.demo_url(o, d.token);
  if url is null then perform acq.fail('demo_url_not_set', 'Set demo_base_url (https) in settings first.'); end if;
  err := acq.check_draft('email', subj, p_body, false);
  if err is not null then perform acq.fail('invalid_draft', err); end if;
  if p_body ~* '(https?://|www\.)' then perform acq.fail('invalid_draft', 'Do not paste links; the demo link is added automatically.'); end if;
  s := acq.setting(o, 'sender', '{}'::jsonb);
  select count(*) into n from acq.outreach_messages where lead_id = l.id and kind = 'reply';
  insert into acq.outreach_messages (org_id, lead_id, kind, channel, step, to_address, from_address, reply_to, subject, body, status,
                                     approval_status, approval_source, approved_by, approved_at, generated_by, idempotency_key, scheduled_at)
  values (o, l.id, 'reply', 'email', null, l.email, nullif(s->>'from_email', ''), nullif(coalesce(s->>'reply_to_email', s->>'from_email'), ''),
          subj, btrim(p_body) || E'\n\nYour short demo: ' || url, 'approved', 'approved', 'user', auth.uid(), now(), 'human',
          'demo:' || d.id || ':' || n, now())
  returning id into mid;
  update acq.demos set sent_message_id = mid where id = d.id;
  perform acq.activity(o, 'demo.send_approved', 'demo', d.id::text, l.id, jsonb_build_object('message_id', mid));
  return jsonb_build_object('ok', true, 'message_id', mid);
end $$;

-- Public (service-only): the demo page loads. Same "not found" for unknown / expired / revoked tokens.
create or replace function acq.demo_view(p_token text)
returns jsonb language plpgsql as $$
declare d acq.demos; l acq.leads; cfg jsonb; mt jsonb;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', true, 'found', false); end if;
  select * into d from acq.demos where token = p_token for update;
  if d.id is null or d.status in ('revoked', 'expired', 'draft') or d.expires_at <= now() then return jsonb_build_object('ok', true, 'found', false); end if;
  if auth.uid() is null then perform set_config('acq.actor', coalesce(nullif(current_setting('acq.actor', true), ''), 'edge'), true); end if;
  update acq.demos set open_count = open_count + 1, first_opened_at = coalesce(first_opened_at, now()), last_opened_at = now(),
         status = case when status in ('ready', 'sent') then 'opened' else status end where id = d.id returning * into d;
  select * into l from acq.leads where id = d.lead_id;
  cfg := acq.setting(d.org_id, 'meeting', '{}'::jsonb);
  select jsonb_build_object('id', m.id, 'starts_at', m.starts_at, 'label', to_char(m.starts_at at time zone m.timezone, 'FMDay FMDD FMMonth "at" HH24:MI'), 'timezone', m.timezone)
    into mt from acq.meetings m where m.demo_id = d.id and m.status = 'scheduled' and m.starts_at > now() order by m.starts_at limit 1;
  return jsonb_build_object('ok', true, 'found', true, 'config', d.config, 'status', d.status,
    'sender_name', acq.setting(d.org_id, 'sender', '{}'::jsonb) ->> 'from_name',
    'booking', jsonb_build_object('enabled', coalesce((cfg->>'duration_min')::int, 30) > 0, 'duration_min', coalesce((cfg->>'duration_min')::int, 30),
                                  'timezone', coalesce(cfg->>'tz', 'Europe/London')),
    'booked_meeting', mt);
end $$;

create or replace function acq.demo_click(p_token text, p_what text default 'cta')
returns jsonb language plpgsql as $$
declare d acq.demos;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', true, 'found', false); end if;
  select * into d from acq.demos where token = p_token for update;
  if d.id is null or d.status in ('revoked', 'expired', 'draft') or d.expires_at <= now() then return jsonb_build_object('ok', true, 'found', false); end if;
  update acq.demos set click_count = click_count + 1, status = case when status in ('ready', 'sent', 'opened') then 'clicked' else status end where id = d.id;
  return jsonb_build_object('ok', true, 'found', true);
end $$;

-- ---------------------------------------------------------------------
-- Meetings: availability, booking, calendar sync queue
-- ---------------------------------------------------------------------

create or replace function acq.meeting_cfg(p_org uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'tz', coalesce(c->>'tz', 'Europe/London'),
    'duration_min', least(greatest(coalesce(nullif(c->>'duration_min', '')::int, 30), 10), 240),
    'slot_step_min', least(greatest(coalesce(nullif(c->>'slot_step_min', '')::int, 30), 5), 240),
    'min_notice_min', least(greatest(coalesce(nullif(c->>'min_notice_min', '')::int, 240), 0), 20160),
    'max_days_ahead', least(greatest(coalesce(nullif(c->>'max_days_ahead', '')::int, 21), 1), 90),
    'calendar_id', coalesce(nullif(c->>'calendar_id', ''), 'primary'),
    'hours', coalesce(c->'hours', '{}'::jsonb))
  from (select acq.setting(p_org, 'meeting', '{}'::jsonb) as c) x
$$;

create or replace function acq.meeting_slot_list(p_org uuid, p_from date, p_days int, p_limit int default 60)
returns table (starts_at timestamptz) language plpgsql stable as $$
declare cfg jsonb := acq.meeting_cfg(p_org); tz text := cfg->>'tz'; dur int := (cfg->>'duration_min')::int; step int := (cfg->>'slot_step_min')::int;
begin
  return query
  select s.st from (
    select distinct ((g)::timestamp at time zone tz) as st
    from generate_series(p_from::timestamp, (p_from + (least(greatest(p_days, 1), 60) - 1))::timestamp, interval '1 day') d
    cross join lateral (select cfg->'hours'->(extract(dow from d)::int)::text as h) hh
    cross join lateral generate_series(d::date + (hh.h->>0)::time, d::date + (hh.h->>1)::time - make_interval(mins => dur), make_interval(mins => step)) g
    where jsonb_typeof(hh.h) = 'array'
  ) s
  where s.st >= now() + make_interval(mins => (cfg->>'min_notice_min')::int)
    and s.st <= now() + make_interval(days => (cfg->>'max_days_ahead')::int)
    and not exists (select 1 from acq.meetings m where m.org_id = p_org and m.status = 'scheduled'
                      and tstzrange(m.starts_at, m.ends_at, '[)') && tstzrange(s.st, s.st + make_interval(mins => dur), '[)'))
  order by s.st
  limit p_limit;
exception when invalid_datetime_format or invalid_text_representation or datetime_field_overflow then
  return;    -- malformed hours setting: offer nothing rather than guess
end $$;

create or replace function acq.meeting_slots(p_token text, p_from date default null, p_days int default 14)
returns jsonb language plpgsql as $$
declare d acq.demos; cfg jsonb; tz text; slots jsonb;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', true, 'found', false); end if;
  select * into d from acq.demos where token = p_token;
  if d.id is null or d.status in ('revoked', 'expired', 'draft') or d.expires_at <= now() then return jsonb_build_object('ok', true, 'found', false); end if;
  cfg := acq.meeting_cfg(d.org_id); tz := cfg->>'tz';
  select coalesce(jsonb_agg(jsonb_build_object('start', to_char(x.starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'date', to_char(x.starts_at at time zone tz, 'YYYY-MM-DD'), 'time', to_char(x.starts_at at time zone tz, 'HH24:MI'),
           'label', to_char(x.starts_at at time zone tz, 'FMDy FMDD FMMon HH24:MI')) order by x.starts_at), '[]'::jsonb)
    into slots from acq.meeting_slot_list(d.org_id, coalesce(p_from, (now() at time zone tz)::date), p_days, 60) x;
  return jsonb_build_object('ok', true, 'found', true, 'timezone', tz, 'duration_min', (cfg->>'duration_min')::int, 'slots', slots);
end $$;

create or replace function acq.book_meeting(p_token text, p_start timestamptz, p_name text, p_email text,
                                            p_phone text default null, p_notes text default null)
returns jsonb language plpgsql as $$
declare
  d acq.demos; l acq.leads; cfg jsonb; tz text; dur int; m acq.meetings; v_email text := acq.norm_email(p_email); v_name text := acq.clip(p_name, 100);
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', true, 'found', false); end if;
  select * into d from acq.demos where token = p_token for update;
  if d.id is null or d.status in ('revoked', 'expired', 'draft') or d.expires_at <= now() then return jsonb_build_object('ok', true, 'found', false); end if;
  if v_name is null or length(v_name) < 2 then perform acq.fail('name_required', 'Please enter your name.'); end if;
  if v_email is null then perform acq.fail('email_required', 'Please enter a valid email address.'); end if;
  if p_start is null then perform acq.fail('time_required', 'Pick a time.'); end if;
  if auth.uid() is null then perform set_config('acq.actor', coalesce(nullif(current_setting('acq.actor', true), ''), 'edge'), true); end if;

  select * into m from acq.meetings where demo_id = d.id and status = 'scheduled' and ends_at > now() order by starts_at limit 1;
  if m.id is not null then
    return jsonb_build_object('ok', false, 'error', 'already_booked', 'message', 'A call is already booked for this demo.',
      'meeting', jsonb_build_object('starts_at', m.starts_at, 'timezone', m.timezone));
  end if;

  cfg := acq.meeting_cfg(d.org_id); tz := cfg->>'tz'; dur := (cfg->>'duration_min')::int;
  if not exists (select 1 from acq.meeting_slot_list(d.org_id, ((p_start at time zone tz)::date), 1, 200) s where s.starts_at = p_start) then
    perform acq.fail('slot_unavailable', 'That time is no longer available. Please pick another.');
  end if;
  select * into l from acq.leads where id = d.lead_id;
  begin
    insert into acq.meetings (org_id, lead_id, demo_id, title, starts_at, ends_at, timezone, channel, attendee_name, attendee_email, source, notes, calendar_id)
    values (d.org_id, d.lead_id, d.id, left('Demo call - ' || l.business_name, 200), p_start, p_start + make_interval(mins => dur), tz, 'google_meet',
            v_name, v_email, 'demo_booking', acq.clip(concat_ws(E'\n', 'Phone: ' || nullif(btrim(coalesce(p_phone, '')), ''), p_notes), 1000), cfg->>'calendar_id')
    returning * into m;
  exception when exclusion_violation then
    perform acq.fail('slot_unavailable', 'That time was just taken. Please pick another.');
  end;
  return jsonb_build_object('ok', true, 'meeting', jsonb_build_object('starts_at', m.starts_at, 'timezone', m.timezone,
    'label', to_char(m.starts_at at time zone tz, 'FMDay FMDD FMMonth "at" HH24:MI')));
end $$;

-- calendar version bump + lead/demo sync
create or replace function acq.tg_meetings_bi() returns trigger language plpgsql as $$
begin
  if new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at or new.status is distinct from old.status
     or new.title is distinct from old.title or new.attendee_email is distinct from old.attendee_email or new.notes is distinct from old.notes then
    new.calendar_version := old.calendar_version + 1;
    new.calendar_sync := 'pending'; new.calendar_sync_attempts := 0; new.calendar_locked_until := null; new.calendar_error := null;
  end if;
  return new;
end $$;
create or replace trigger tg_meetings_bi before update on acq.meetings for each row execute function acq.tg_meetings_bi();

create or replace function acq.tg_meetings_ai() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'scheduled' then
    if new.demo_id is not null then
      update acq.demos set status = 'booked', booked_at = now(), meeting_id = new.id where id = new.demo_id and status not in ('revoked', 'expired');
    end if;
    if new.lead_id is not null then
      perform set_config('acq.reason', 'meeting_booked', true);
      update acq.leads set status = 'meeting_booked' where id = new.lead_id and status in ('contacted', 'replied', 'demo_sent');
      perform set_config('acq.reason', '', true);
    end if;
  end if;
  return new;
end $$;
create or replace trigger tg_meetings_ai after insert on acq.meetings for each row execute function acq.tg_meetings_ai();

-- staff actions
create or replace function acq.schedule_meeting(p_lead uuid, p_start timestamptz, p_duration_min int, p_title text, p_channel text,
                                                p_attendee_name text, p_attendee_email text, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); l acq.leads; cfg jsonb; m acq.meetings; dur int; ch text := coalesce(p_channel, 'google_meet');
begin
  select * into l from acq.leads where id = p_lead and org_id = o for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  if ch not in ('google_meet', 'phone', 'in_person', 'zoom') then perform acq.fail('invalid_channel', 'Unknown meeting channel.'); end if;
  if p_start is null or p_start < now() - interval '5 minutes' then perform acq.fail('invalid_time', 'Pick a time in the future.'); end if;
  if p_attendee_email is not null and btrim(p_attendee_email) <> '' and acq.norm_email(p_attendee_email) is null then perform acq.fail('invalid_email', 'Attendee email is not valid.'); end if;
  cfg := acq.meeting_cfg(o);
  dur := least(greatest(coalesce(p_duration_min, (cfg->>'duration_min')::int), 10), 240);
  begin
    insert into acq.meetings (org_id, lead_id, title, starts_at, ends_at, timezone, channel, attendee_name, attendee_email, source, notes, calendar_id, created_by)
    values (o, l.id, coalesce(acq.clip(p_title, 200), 'Call with ' || l.business_name), p_start, p_start + make_interval(mins => dur), cfg->>'tz', ch,
            acq.clip(p_attendee_name, 100), acq.norm_email(p_attendee_email), 'manual', acq.clip(p_notes, 1000), cfg->>'calendar_id', auth.uid())
    returning * into m;
  exception when exclusion_violation then
    perform acq.fail('slot_taken', 'You already have a meeting at that time.');
  end;
  return jsonb_build_object('ok', true, 'meeting_id', m.id);
end $$;

create or replace function acq.cancel_meeting(p_meeting uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); n int;
begin
  update acq.meetings set status = 'cancelled', notes = concat_ws(E'\n', notes, nullif('Cancelled: ' || coalesce(btrim(p_reason), ''), 'Cancelled: '))
   where id = p_meeting and org_id = o and status = 'scheduled';
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('meeting_not_found', 'No scheduled meeting with that id.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function acq.set_meeting_outcome(p_meeting uuid, p_status text, p_outcome text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); n int;
begin
  if p_status not in ('completed', 'no_show') then perform acq.fail('invalid_status', 'Status must be completed or no_show.'); end if;
  if p_outcome is not null and p_outcome not in ('won', 'lost', 'follow_up', 'no_decision') then perform acq.fail('invalid_outcome', 'Unknown outcome.'); end if;
  update acq.meetings set status = p_status, outcome = p_outcome, outcome_notes = acq.clip(p_notes, 2000)
   where id = p_meeting and org_id = o and status in ('scheduled', 'completed', 'no_show');
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('meeting_not_found', 'Meeting not found.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Google Calendar sync queue (n8n worker)
-- ---------------------------------------------------------------------

create or replace function acq.claim_meeting_calendar(p_limit int default 5)
returns setof jsonb language plpgsql as $$
declare m acq.meetings; base text; ev jsonb; cal text; qs text; l acq.leads;
begin
  for m in
    select x.* from acq.meetings x
    where (x.calendar_sync = 'pending' and (x.calendar_locked_until is null or x.calendar_locked_until <= now()))   -- back-off after a failure is kept in locked_until
       or (x.calendar_sync = 'processing' and x.calendar_locked_until < now())
    order by x.updated_at limit least(greatest(p_limit, 1), 10) for update skip locked
  loop
    if m.calendar_sync_attempts >= 5 then
      update acq.meetings set calendar_sync = 'failed', calendar_locked_until = null, calendar_error = coalesce(calendar_error, 'max_attempts') where id = m.id;
      continue;
    end if;
    cal := coalesce(nullif(m.calendar_id, ''), acq.meeting_cfg(m.org_id)->>'calendar_id');
    if m.status = 'cancelled' and m.google_event_id is null then
      update acq.meetings set calendar_sync = 'skipped', calendar_locked_until = null where id = m.id; continue;
    end if;
    if m.status in ('completed', 'no_show') then
      update acq.meetings set calendar_sync = 'skipped', calendar_locked_until = null where id = m.id; continue;
    end if;
    base := 'https://www.googleapis.com/calendar/v3/calendars/' || acq.urlenc(cal) || '/events';
    update acq.meetings set calendar_sync = 'processing', calendar_sync_attempts = calendar_sync_attempts + 1,
           calendar_locked_until = now() + interval '5 minutes' where id = m.id;
    if m.status = 'cancelled' then
      return next jsonb_build_object('meeting_id', m.id, 'version', m.calendar_version, 'method', 'DELETE',
        'url', base || '/' || acq.urlenc(m.google_event_id) || '?sendUpdates=all', 'body', '{}'::jsonb);
      continue;
    end if;
    select * into l from acq.leads where id = m.lead_id;
    ev := jsonb_build_object(
      'summary', m.title,
      'description', concat_ws(E'\n', 'Booked via Booking OS.', 'Business: ' || coalesce(l.business_name, ''), 'Contact: ' || coalesce(m.attendee_name, ''), m.notes),
      'start', jsonb_build_object('dateTime', to_char(m.starts_at at time zone m.timezone, 'YYYY-MM-DD"T"HH24:MI:SS'), 'timeZone', m.timezone),
      'end',   jsonb_build_object('dateTime', to_char(m.ends_at   at time zone m.timezone, 'YYYY-MM-DD"T"HH24:MI:SS'), 'timeZone', m.timezone),
      'extendedProperties', jsonb_build_object('private', jsonb_build_object('acq_meeting_id', m.id::text)));
    if m.attendee_email is not null then ev := ev || jsonb_build_object('attendees', jsonb_build_array(jsonb_build_object('email', m.attendee_email))); end if;
    qs := '?sendUpdates=all';
    if m.google_event_id is null then
      if m.channel = 'google_meet' then
        ev := ev || jsonb_build_object('conferenceData', jsonb_build_object('createRequest',
                jsonb_build_object('requestId', m.id::text || '-v' || m.calendar_version, 'conferenceSolutionKey', jsonb_build_object('type', 'hangoutsMeet'))));
        qs := qs || '&conferenceDataVersion=1';
      end if;
      return next jsonb_build_object('meeting_id', m.id, 'version', m.calendar_version, 'method', 'POST', 'url', base || qs, 'body', ev);
    else
      return next jsonb_build_object('meeting_id', m.id, 'version', m.calendar_version, 'method', 'PUT',
        'url', base || '/' || acq.urlenc(m.google_event_id) || qs, 'body', ev);
    end if;
  end loop;
end $$;

create or replace function acq.complete_meeting_calendar(p_meeting uuid, p_version int, p_http_status int, p_body jsonb, p_error text default null)
returns jsonb language plpgsql as $$
declare m acq.meetings; ok boolean; permanent boolean; v_eid text := p_body->>'id'; v_stale boolean;
begin
  select * into m from acq.meetings where id = p_meeting for update;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'meeting_not_found'); end if;
  if m.calendar_sync <> 'processing' then return jsonb_build_object('ok', true, 'note', 'already ' || m.calendar_sync); end if;
  ok := coalesce(p_http_status, 0) between 200 and 299 or (m.status = 'cancelled' and p_http_status in (404, 410));
  v_stale := m.calendar_version <> p_version;
  if ok then
    update acq.meetings set google_event_id = case when m.status = 'cancelled' then null else coalesce(v_eid, google_event_id) end,
           meeting_url = coalesce(p_body->>'hangoutLink', meeting_url), calendar_sync = case when v_stale then 'pending' else 'synced' end,
           calendar_locked_until = null, calendar_error = null where id = m.id;
    return jsonb_build_object('ok', true, 'status', case when v_stale then 'resync' else 'synced' end);
  end if;
  if m.google_event_id is not null and p_http_status in (404, 410) then       -- event deleted by hand: recreate on retry
    update acq.meetings set google_event_id = null where id = m.id;
  end if;
  permanent := p_http_status between 400 and 499 and p_http_status not in (401, 403, 404, 408, 409, 410, 429);
  update acq.meetings set calendar_sync = case when permanent or m.calendar_sync_attempts >= 5 then 'failed' else 'pending' end,
         calendar_locked_until = now() + make_interval(mins => case when p_http_status in (401, 403) then 30 else least(power(2, m.calendar_sync_attempts)::int, 60) end),
         calendar_error = left(coalesce(p_error, '') || ' http=' || coalesce(p_http_status::text, 'none') || ' ' || coalesce(p_body #>> '{error,message}', p_body->>'message', ''), 400)
   where id = m.id;
  return jsonb_build_object('ok', false, 'status', case when permanent or m.calendar_sync_attempts >= 5 then 'failed' else 'retry' end);
end $$;

-- ---------------------------------------------------------------------
-- Views + privileges
-- ---------------------------------------------------------------------

create or replace view acq.v_replies with (security_invoker = true) as
select r.id, r.org_id, r.lead_id, l.business_name, l.status as lead_status, r.channel, r.from_address, r.subject, left(r.body, 600) as body_preview,
       r.classification, r.classification_confidence, r.summary, r.suggested_response, r.response_status, r.received_at, r.handled_at, r.match_status
from acq.replies r left join acq.leads l on l.id = r.lead_id and l.org_id = r.org_id;

create or replace view acq.v_meetings with (security_invoker = true) as
select m.id, m.org_id, m.lead_id, l.business_name, m.title, m.starts_at, m.ends_at, m.timezone, m.status, m.channel, m.meeting_url,
       m.attendee_name, m.attendee_email, m.source, m.outcome, m.calendar_sync, m.calendar_error
from acq.meetings m left join acq.leads l on l.id = m.lead_id and l.org_id = m.org_id;

revoke execute on all functions in schema acq from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on all tables in schema acq to authenticated;
    revoke select on acq.rate_limits, acq.webhook_events from authenticated;
    grant execute on function acq.edit_reply_response(uuid, text), acq.approve_reply_response(uuid, text), acq.reject_reply_response(uuid),
      acq.mark_reply_handled(uuid), acq.match_reply_manually(uuid, uuid), acq.create_demo(uuid, text, jsonb), acq.revoke_demo(uuid),
      acq.send_demo(uuid, text, text), acq.schedule_meeting(uuid, timestamptz, int, text, text, text, text, text),
      acq.cancel_meeting(uuid, text), acq.set_meeting_outcome(uuid, text, text, text) to authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant all on all tables in schema acq to service_role;
    grant execute on all functions in schema acq to service_role;
  end if;
end $$;
