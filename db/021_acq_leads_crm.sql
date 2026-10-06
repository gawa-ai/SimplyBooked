-- =====================================================================
-- ACQ Phase 2 — lead finder, qualification, CRM pipeline
--   * pipeline state machine enforced in the database (guard trigger), every move logged
--   * dedupe-aware lead ingest (merge, never overwrite; suppression list respected)
--   * search-run queue + qualification queue for n8n (claim / complete, skip locked)
--   * user RPCs re-check role + org; service functions are NOT executable by `authenticated`
-- Safe to re-run.
-- =====================================================================

alter table acq.leads add column if not exists qual_locked_until timestamptz;
alter table acq.leads add column if not exists qual_attempts int not null default 0;
alter table acq.leads add column if not exists qual_error text;
alter table acq.leads add column if not exists requalify_requested_at timestamptz;
alter table acq.lead_qualification add column if not exists signals jsonb not null default '{}'::jsonb;
create index if not exists leads_qual_queue on acq.leads (created_at) where status = 'new_lead';

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

create or replace function acq.setting_int(p_org uuid, p_key text, p_default int)
returns int language sql stable as $$
  select coalesce((select case when (s.value #>> '{}') ~ '^[0-9]{1,9}$' then (s.value #>> '{}')::int end
                   from acq.system_settings s where s.org_id = p_org and s.key = p_key), p_default)
$$;

create or replace function acq.setting_bool(p_org uuid, p_key text, p_default boolean)
returns boolean language sql stable as $$
  select coalesce((select case when (s.value #>> '{}') in ('true','false') then (s.value #>> '{}')::boolean end
                   from acq.system_settings s where s.org_id = p_org and s.key = p_key), p_default)
$$;

-- start of "today" in the organisation's timezone (used by every daily cap)
create or replace function acq.day_start(p_org uuid)
returns timestamptz language sql stable as $$
  select (((now() at time zone o.timezone)::date)::timestamp) at time zone o.timezone
  from acq.organizations o where o.id = p_org
$$;

create or replace function acq.clip(p text, p_len int)
returns text language sql immutable as $$ select nullif(left(btrim(p), p_len), '') $$;

create or replace function acq.text_array(p jsonb, p_max int, p_len int)
returns text[] language sql immutable as $$
  select coalesce(array(
    select left(btrim(e.v #>> '{}'), p_len)
    from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality e(v, i)
    where jsonb_typeof(e.v) = 'string' and btrim(e.v #>> '{}') <> ''
    order by e.i limit p_max), '{}'::text[])
$$;

create or replace function acq.actor_type()
returns text language sql stable as $$
  select case when auth.uid() is not null then 'user'
              when current_setting('acq.actor', true) in ('n8n', 'edge') then current_setting('acq.actor', true)
              else 'system' end
$$;

create or replace function acq.status_rank(p text)
returns int language sql immutable as $$
  select case p when 'new_lead' then 1 when 'qualified' then 2 when 'approved' then 3 when 'contacted' then 4
                when 'replied' then 5 when 'demo_sent' then 6 when 'meeting_booked' then 7 when 'won' then 8 when 'lost' then 9 end
$$;

-- the only legal pipeline moves
create or replace function acq.status_allowed(p_from text, p_to text)
returns boolean language sql immutable as $$
  select exists (select 1 from (values
    ('new_lead','qualified'), ('new_lead','lost'),
    ('qualified','new_lead'), ('qualified','approved'), ('qualified','lost'),
    ('approved','qualified'), ('approved','contacted'), ('approved','lost'),
    ('contacted','replied'), ('contacted','demo_sent'), ('contacted','meeting_booked'), ('contacted','lost'),
    ('replied','demo_sent'), ('replied','meeting_booked'), ('replied','won'), ('replied','lost'),
    ('demo_sent','replied'), ('demo_sent','meeting_booked'), ('demo_sent','won'), ('demo_sent','lost'),
    ('meeting_booked','demo_sent'), ('meeting_booked','replied'), ('meeting_booked','won'), ('meeting_booked','lost'),
    ('lost','new_lead'), ('lost','qualified')
  ) v(f, t) where v.f = p_from and v.t = p_to)
$$;

-- ---------------------------------------------------------------------
-- Stopping automation (follow-ups / pending outreach)
-- ---------------------------------------------------------------------

create or replace function acq.stop_followups(p_lead uuid, p_reason text)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update acq.followups set status = 'cancelled', cancel_reason = left(p_reason, 200), updated_at = now()
   where lead_id = p_lead and status in ('scheduled','drafting','drafted');
  get diagnostics n = row_count;
  -- drafted follow-up messages that have not gone out yet
  update acq.outreach_messages set status = 'cancelled', last_error = left(p_reason, 200), updated_at = now()
   where lead_id = p_lead and kind = 'followup' and status in ('draft','pending_approval','approved','queued');
  return n;
end $$;

create or replace function acq.cancel_pending_outreach(p_lead uuid, p_reason text)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform acq.stop_followups(p_lead, p_reason);
  update acq.outreach_messages set status = 'cancelled', last_error = left(p_reason, 200), updated_at = now()
   where lead_id = p_lead and status in ('draft','pending_approval','approved','queued');
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Pipeline guard + event log
-- ---------------------------------------------------------------------

create or replace function acq.tg_leads_guard() returns trigger language plpgsql security definer set search_path = '' as $$
declare reason text := nullif(current_setting('acq.reason', true), '');
        allow_clear boolean := coalesce(current_setting('acq.allow_dnc_clear', true), '') = 'on';
begin
  if not allow_clear and ((old.do_not_contact and not new.do_not_contact)
                          or (old.unsubscribed_at is not null and new.unsubscribed_at is null)) then
    perform acq.fail('dnc_locked', 'Do-not-contact and unsubscribe flags cannot be cleared here.');
  end if;

  if new.status is distinct from old.status then
    if old.status = 'won' then perform acq.fail('won_is_final', 'A won lead cannot change status.'); end if;
    if not acq.status_allowed(old.status, new.status) then
      perform acq.fail('invalid_transition', 'Cannot move a lead from ' || old.status || ' to ' || new.status || '.');
    end if;
    if new.status in ('approved','contacted','demo_sent') and new.do_not_contact then
      perform acq.fail('do_not_contact', 'This lead is marked do-not-contact.');
    end if;
    if new.status = 'approved' and not exists (
         select 1 from acq.outreach_messages m
         where m.lead_id = new.id and m.approval_status = 'approved' and m.status not in ('rejected','cancelled','failed')) then
      perform acq.fail('approval_required', 'A lead can only be Approved once an outreach message has been approved.');
    end if;
    if new.status = 'contacted' and not exists (
         select 1 from acq.outreach_messages m
         where m.lead_id = new.id and m.kind in ('outreach','followup') and m.status in ('sent','delivered','opened','clicked')) then
      perform acq.fail('no_sent_message', 'A lead can only be Contacted once a message has actually been sent.');
    end if;

    if new.status = 'qualified' then new.qualified_at := coalesce(new.qualified_at, now()); end if;
    if new.status = 'contacted' then new.last_contacted_at := coalesce(new.last_contacted_at, now()); end if;
    if new.status = 'replied'   then new.last_reply_at := now(); end if;
    if new.status = 'won'       then new.won_at := now(); end if;
    if new.status = 'lost' then
      new.lost_at := now();
      new.lost_reason := coalesce(reason, new.lost_reason, 'unspecified');
    elsif old.status = 'lost' then
      new.lost_at := null; new.lost_reason := null;
    end if;
  end if;
  return new;
end $$;

create or replace function acq.tg_leads_after() returns trigger language plpgsql security definer set search_path = '' as $$
declare reason text := nullif(current_setting('acq.reason', true), '');
begin
  if tg_op = 'INSERT' then
    insert into acq.pipeline_events (org_id, lead_id, from_status, to_status, actor_type, actor_id, reason)
    values (new.org_id, new.id, null, new.status, acq.actor_type(), auth.uid(), coalesce(reason, 'created'));
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into acq.pipeline_events (org_id, lead_id, from_status, to_status, actor_type, actor_id, reason)
    values (new.org_id, new.id, old.status, new.status, acq.actor_type(), auth.uid(), reason);
    if new.status in ('replied','meeting_booked','won') then
      perform acq.stop_followups(new.id, 'lead_' || new.status);
    elsif new.status = 'lost' then
      perform acq.cancel_pending_outreach(new.id, 'lead_lost');
    end if;
  end if;
  if new.do_not_contact and not old.do_not_contact then
    perform acq.cancel_pending_outreach(new.id, 'do_not_contact');
  end if;
  return new;
end $$;

create or replace trigger tg_leads_guard before update on acq.leads for each row execute function acq.tg_leads_guard();
create or replace trigger tg_leads_after after insert or update on acq.leads for each row execute function acq.tg_leads_after();

-- ---------------------------------------------------------------------
-- Suppression / do-not-contact
-- ---------------------------------------------------------------------

create or replace function acq.suppress_lead(p_lead uuid, p_reason text, p_source text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare l acq.leads;
begin
  if p_reason not in ('unsubscribe','bounce','complaint','manual','erasure','negative_reply') then
    perform acq.fail('invalid_reason', 'Unknown suppression reason.');
  end if;
  select * into l from acq.leads where id = p_lead for update;
  if l.id is null then return jsonb_build_object('ok', false, 'error', 'lead_not_found'); end if;

  insert into acq.suppressions (org_id, kind, value, reason, source, lead_id)
  select l.org_id, v.k,
         case when p_reason = 'erasure' then 'sha256:' || encode(sha256(convert_to(v.val, 'UTF8')), 'hex') else v.val end,
         p_reason, left(p_source, 100), case when p_reason = 'erasure' then null else l.id end
  from (values ('email', l.email), ('phone', l.phone_e164), ('domain', l.domain)) v(k, val)
  where v.val is not null
  on conflict (org_id, kind, value) do nothing;

  perform set_config('acq.reason', 'dnc_' || p_reason, true);
  update acq.leads set do_not_contact = true,
         dnc_reason = coalesce(dnc_reason, p_reason),
         unsubscribed_at = case when p_reason = 'unsubscribe' then coalesce(unsubscribed_at, now()) else unsubscribed_at end,
         status = case when status in ('won','lost') then status else 'lost' end
   where id = l.id;
  perform set_config('acq.reason', '', true);
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'reason', p_reason);
end $$;

-- ---------------------------------------------------------------------
-- Lead ingest (the one way leads enter the system)
-- ---------------------------------------------------------------------

create or replace function acq.is_suppressed(p_org uuid, p_email text, p_phone text, p_domain text)
returns boolean language sql stable as $$
  select exists (
    select 1 from acq.suppressions s
    where s.org_id = p_org and (
      (s.kind = 'email'  and p_email  is not null and s.value in (p_email,  'sha256:' || encode(sha256(convert_to(p_email,  'UTF8')), 'hex'))) or
      (s.kind = 'phone'  and p_phone  is not null and s.value in (p_phone,  'sha256:' || encode(sha256(convert_to(p_phone,  'UTF8')), 'hex'))) or
      (s.kind = 'domain' and p_domain is not null and s.value in (p_domain, 'sha256:' || encode(sha256(convert_to(p_domain, 'UTF8')), 'hex')))))
$$;

create or replace function acq.upsert_lead(p_org uuid, p_source uuid, p_run uuid, p_item jsonb, p_defaults jsonb default '{}'::jsonb,
                                           p_allow_create boolean default true)
returns jsonb language plpgsql as $$
declare
  it jsonb := coalesce(p_item, '{}'::jsonb); df jsonb := coalesce(p_defaults, '{}'::jsonb);
  nm text := acq.clip(it->>'business_name', 200);
  cc text := upper(nullif(btrim(coalesce(it->>'country_code', df->>'country_code', acq.setting(p_org, 'default_country') #>> '{}', '')), ''));
  web text := acq.clip(it->>'website', 500); ph text := acq.clip(it->>'phone', 40);
  em text := acq.norm_email(it->>'email');
  cat text := acq.clip(it->>'category', 120);
  nic text := acq.clip(coalesce(it->>'niche', df->>'niche'), 80);
  adr text := acq.clip(it->>'address', 300);
  cty text := acq.clip(coalesce(it->>'city', df->>'city'), 80);
  reg text := acq.clip(coalesce(it->>'region', df->>'region'), 80);
  ext text := acq.clip(it->>'external_id', 200);
  rt numeric := case when (it->>'rating') ~ '^[0-9](\.[0-9]+)?$' and (it->>'rating')::numeric <= 5 then round((it->>'rating')::numeric, 1) end;
  rc int := case when (it->>'review_count') ~ '^[0-9]{1,9}$' then (it->>'review_count')::int end;
  raw jsonb := case when length(coalesce(it->'raw', '{}'::jsonb)::text) <= 20000 and jsonb_typeof(it->'raw') = 'object' then it->'raw' else '{}'::jsonb end;
  dom text; ph164 text; ex acq.leads; lid uuid; changed boolean;
begin
  if nm is null then return jsonb_build_object('status', 'invalid', 'error', 'business_name is required'); end if;
  if cc is not null and cc !~ '^[A-Z]{2}$' then cc := null; end if;
  dom := acq.norm_domain(web); ph164 := acq.norm_phone(ph, cc);

  if acq.is_suppressed(p_org, em, ph164, dom) then
    return jsonb_build_object('status', 'suppressed');
  end if;

  for attempt in 1..2 loop
    ex := null;
    if ext is not null and p_source is not null then
      select * into ex from acq.leads where org_id = p_org and source_id = p_source and external_id = ext;
    end if;
    if ex.id is null and dom is not null   then select * into ex from acq.leads where org_id = p_org and domain = dom; end if;
    if ex.id is null and ph164 is not null then select * into ex from acq.leads where org_id = p_org and phone_e164 = ph164; end if;
    if ex.id is null and em is not null    then select * into ex from acq.leads where org_id = p_org and email = em; end if;
    if ex.id is null and dom is null and ph164 is null and em is null then
      select * into ex from acq.leads where org_id = p_org and lower(btrim(business_name)) = lower(nm)
        and lower(coalesce(city, '')) = lower(coalesce(cty, '')) order by created_at limit 1;
    end if;

    if ex.id is not null then
      -- merge: fill blanks only, never overwrite; skip identifiers that belong to a different lead
      update acq.leads l set
        website   = case when l.website is null and dom is not null and not exists (select 1 from acq.leads x where x.org_id = p_org and x.domain = dom and x.id <> l.id) then web else l.website end,
        phone     = case when l.phone is null and ph is not null and (ph164 is null or not exists (select 1 from acq.leads x where x.org_id = p_org and x.phone_e164 = ph164 and x.id <> l.id)) then ph else l.phone end,
        email     = case when l.email is null and em is not null and not exists (select 1 from acq.leads x where x.org_id = p_org and x.email = em and x.id <> l.id) then em else l.email end,
        category  = coalesce(l.category, cat), niche = coalesce(l.niche, nic), address = coalesce(l.address, adr),
        city = coalesce(l.city, cty), region = coalesce(l.region, reg), country_code = coalesce(l.country_code, cc),
        rating = coalesce(l.rating, rt), review_count = coalesce(l.review_count, rc),
        external_id = case when l.external_id is null and ext is not null and l.source_id is not distinct from p_source then ext else l.external_id end
      where l.id = ex.id
        and (l.website is null or l.phone is null or l.email is null or l.category is null or l.niche is null or l.address is null
             or l.city is null or l.region is null or l.country_code is null or l.rating is null or l.review_count is null)
      returning (l.website, l.phone, l.email, l.category, l.niche, l.address, l.city, l.region, l.country_code, l.rating, l.review_count)
        is distinct from (ex.website, ex.phone, ex.email, ex.category, ex.niche, ex.address, ex.city, ex.region, ex.country_code, ex.rating, ex.review_count)
        into changed;
      return jsonb_build_object('status', case when coalesce(changed, false) then 'merged' else 'duplicate' end, 'lead_id', ex.id);
    end if;

    if not p_allow_create then return jsonb_build_object('status', 'limited'); end if;
    begin
      insert into acq.leads (org_id, source_id, search_run_id, external_id, business_name, website, phone, email, category, niche,
                             address, city, region, country_code, rating, review_count, raw)
      values (p_org, p_source, p_run, ext, nm, web, ph, em, cat, nic, adr, cty, reg, cc, rt, rc, raw)
      returning id into lid;
      return jsonb_build_object('status', 'created', 'lead_id', lid);
    exception when unique_violation then
      null;   -- raced with another writer: loop once more and merge into the winner
    end;
  end loop;
  return jsonb_build_object('status', 'invalid', 'error', 'could not insert (concurrent duplicate)');
end $$;

create or replace function acq.ingest_leads(p_org uuid, p_source uuid, p_run uuid, p_items jsonb, p_defaults jsonb default '{}'::jsonb)
returns jsonb language plpgsql as $$
declare
  src acq.lead_sources; e jsonb; r jsonb; remaining int; n int := 0;
  c_created int := 0; c_merged int := 0; c_dup int := 0; c_supp int := 0; c_invalid int := 0; c_limited int := 0;
  errs jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_items) is distinct from 'array' then perform acq.fail('invalid_items', 'items must be a JSON array.'); end if;
  if jsonb_array_length(p_items) > 200 then perform acq.fail('batch_too_large', 'At most 200 leads per call.'); end if;
  select * into src from acq.lead_sources where id = p_source and org_id = p_org and active;
  if src.id is null then perform acq.fail('source_not_found', 'Lead source not found or inactive.'); end if;
  if p_run is not null and not exists (select 1 from acq.lead_search_runs where id = p_run and org_id = p_org and source_id = p_source) then
    perform acq.fail('run_not_found', 'Search run does not belong to this source.');
  end if;
  if auth.uid() is null then perform set_config('acq.actor', coalesce(nullif(current_setting('acq.actor', true), ''), 'n8n'), true); end if;

  remaining := src.daily_limit - (select count(*) from acq.leads
                                   where org_id = p_org and source_id = p_source and created_at >= acq.day_start(p_org))::int;
  for e in select value from jsonb_array_elements(p_items) loop
    n := n + 1;
    if jsonb_typeof(e) <> 'object' then c_invalid := c_invalid + 1; continue; end if;
    begin
      r := acq.upsert_lead(p_org, p_source, p_run, e, p_defaults, remaining > 0);   -- over the daily cap: merge only, create nothing
    exception when others then
      r := jsonb_build_object('status', 'invalid', 'error', sqlerrm);
    end;
    case r->>'status'
      when 'created'    then c_created := c_created + 1; remaining := remaining - 1;
      when 'merged'     then c_merged := c_merged + 1;
      when 'duplicate'  then c_dup := c_dup + 1;
      when 'suppressed' then c_supp := c_supp + 1;
      when 'limited'    then c_limited := c_limited + 1;
      else c_invalid := c_invalid + 1;
           if jsonb_array_length(errs) < 5 and r ? 'error' then errs := errs || to_jsonb(left(r->>'error', 200)); end if;
    end case;
  end loop;

  if p_run is not null then
    update acq.lead_search_runs set found_count = found_count + n, new_count = new_count + c_created,
           dup_count = dup_count + c_merged + c_dup, updated_at = now() where id = p_run;
  end if;
  return jsonb_build_object('ok', true, 'received', n, 'created', c_created, 'merged', c_merged, 'duplicate', c_dup,
                            'suppressed', c_supp, 'invalid', c_invalid, 'limited', c_limited, 'errors', errs);
end $$;

-- ---------------------------------------------------------------------
-- Search runs (n8n lead finder queue)
-- ---------------------------------------------------------------------

create or replace function acq.queue_search_run(p_source_key text, p_niche text, p_city text, p_region text,
                                                p_country text, p_max int default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); src acq.lead_sources; cc text := upper(btrim(coalesce(p_country, ''))); rid uuid; ex uuid;
        cap int;
begin
  select * into src from acq.lead_sources where org_id = o and key = lower(btrim(coalesce(p_source_key, ''))) and active;
  if src.id is null then perform acq.fail('source_not_found', 'Lead source not found or inactive.'); end if;
  if src.provider in ('manual', 'csv') then perform acq.fail('not_searchable', 'That source is for manual entry / CSV import, not searching.'); end if;
  if cc !~ '^[A-Z]{2}$' then perform acq.fail('invalid_country', 'Country must be a 2-letter code, e.g. GB.'); end if;
  if length(btrim(coalesce(p_niche, ''))) not between 2 and 80 then perform acq.fail('invalid_niche', 'Niche must be 2-80 characters.'); end if;
  if coalesce(p_max, 20) not between 1 and 60 then perform acq.fail('invalid_max', 'max_results must be 1-60.'); end if;
  if length(coalesce(p_city, '')) > 80 or length(coalesce(p_region, '')) > 80 then perform acq.fail('invalid_location', 'City / region too long.'); end if;

  select r.id into ex from acq.lead_search_runs r
   where r.org_id = o and r.source_id = src.id and r.status in ('queued', 'running') and lower(r.niche) = lower(btrim(p_niche))
     and lower(coalesce(r.city, '')) = lower(btrim(coalesce(p_city, ''))) and r.country_code = cc limit 1;
  if ex is not null then return jsonb_build_object('ok', true, 'run_id', ex, 'duplicate', true); end if;

  cap := acq.setting_int(o, 'max_search_runs_per_day', 20);
  if (select count(*) from acq.lead_search_runs where org_id = o and created_at >= acq.day_start(o)) >= cap then
    perform acq.fail('daily_search_cap', 'Daily search limit reached (' || cap || ').');
  end if;

  insert into acq.lead_search_runs (org_id, source_id, niche, city, region, country_code, max_results)
  values (o, src.id, btrim(p_niche), nullif(btrim(coalesce(p_city, '')), ''), nullif(btrim(coalesce(p_region, '')), ''), cc, coalesce(p_max, 20))
  returning lead_search_runs.id into rid;
  return jsonb_build_object('ok', true, 'run_id', rid);
end $$;

create or replace function acq.claim_search_runs(p_limit int default 3)
returns setof jsonb language plpgsql as $$
declare r acq.lead_search_runs; src acq.lead_sources;
begin
  for r in
    select * from acq.lead_search_runs
    where status = 'queued' or (status = 'running' and locked_until < now())
    order by created_at limit least(greatest(p_limit, 1), 10) for update skip locked
  loop
    if r.attempts >= 3 then
      update acq.lead_search_runs set status = 'failed', error = coalesce(error, 'max_attempts'), finished_at = now(), locked_until = null where id = r.id;
      continue;
    end if;
    select * into src from acq.lead_sources where id = r.source_id and org_id = r.org_id and active;
    if src.id is null then
      update acq.lead_search_runs set status = 'failed', error = 'source_inactive', finished_at = now(), locked_until = null where id = r.id;
      continue;
    end if;
    update acq.lead_search_runs set status = 'running', attempts = attempts + 1, locked_until = now() + interval '10 minutes',
           started_at = coalesce(started_at, now()) where id = r.id;
    return next jsonb_build_object('run_id', r.id, 'org_id', r.org_id, 'source_id', r.source_id, 'provider', src.provider,
      'config', src.config, 'niche', r.niche, 'city', r.city, 'region', r.region, 'country_code', r.country_code,
      'max_results', r.max_results, 'attempt', r.attempts + 1);
  end loop;
end $$;

create or replace function acq.complete_search_run(p_run uuid, p_ok boolean, p_error text default null)
returns jsonb language plpgsql as $$
begin
  update acq.lead_search_runs set status = case when p_ok then 'completed' else 'failed' end,
         error = case when p_ok then null else left(coalesce(p_error, 'failed'), 500) end,
         finished_at = now(), locked_until = null
   where id = p_run and status = 'running';
  return jsonb_build_object('ok', found);
end $$;

-- ---------------------------------------------------------------------
-- Qualification (n8n asks the AI; the database validates and decides)
-- ---------------------------------------------------------------------

create or replace function acq.claim_leads_for_qualification(p_limit int default 10)
returns setof jsonb language plpgsql as $$
declare l acq.leads;
begin
  for l in
    select x.* from acq.leads x join acq.organizations o on o.id = x.org_id and o.status = 'active'
    where not x.do_not_contact and x.qual_attempts < 3
      and (x.qual_locked_until is null or x.qual_locked_until < now())
      and ((x.status = 'new_lead' and not exists (select 1 from acq.lead_qualification q where q.lead_id = x.id and q.is_current))
           or (x.requalify_requested_at is not null and x.status in ('new_lead', 'qualified')))
    order by x.created_at limit least(greatest(p_limit, 1), 25) for update of x skip locked
  loop
    update acq.leads set qual_attempts = qual_attempts + 1, qual_locked_until = now() + interval '10 minutes' where id = l.id;
    return next jsonb_build_object('lead_id', l.id, 'org_id', l.org_id, 'business_name', l.business_name, 'website', l.website,
      'domain', l.domain, 'phone', l.phone_e164, 'email', l.email, 'category', l.category, 'niche', l.niche, 'address', l.address,
      'city', l.city, 'region', l.region, 'country_code', l.country_code, 'rating', l.rating, 'review_count', l.review_count,
      'raw', l.raw, 'attempt', l.qual_attempts + 1,
      'offer_context', acq.setting(l.org_id, 'offer_context', '""'::jsonb) #>> '{}',
      'threshold', acq.setting_int(l.org_id, 'qualify_threshold', 60),
      'prompt_version', coalesce(acq.setting(l.org_id, 'ai', '{}'::jsonb) ->> 'prompt_version', 'v1'),
      'model', coalesce(acq.setting(l.org_id, 'ai', '{}'::jsonb) ->> 'model', 'gpt-5-mini'));
  end loop;
end $$;

create or replace function acq.qualification_failed(p_lead uuid, p_error text)
returns jsonb language plpgsql as $$
begin
  update acq.leads set qual_error = left(coalesce(p_error, 'failed'), 300),
         qual_locked_until = now() + make_interval(mins => 10 * greatest(qual_attempts, 1)) where id = p_lead;
  return jsonb_build_object('ok', found);
end $$;

create or replace function acq.record_qualification(p_lead uuid, p_result jsonb, p_model text default null, p_prompt_version text default null)
returns jsonb language plpgsql as $$
declare
  l acq.leads; res jsonb := coalesce(p_result, '{}'::jsonb); sc int; thr int; v_fit text; v_is_fit boolean; wq text; ob text; qid uuid;
  new_status text;
begin
  select * into l from acq.leads where id = p_lead for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  if coalesce(res->>'score', '') !~ '^[0-9]{1,3}(\.[0-9]+)?$' then perform acq.fail('invalid_score', 'score must be a number 0-100.'); end if;
  sc := round((res->>'score')::numeric)::int;
  if sc not between 0 and 100 then perform acq.fail('invalid_score', 'score must be between 0 and 100.'); end if;

  thr := acq.setting_int(l.org_id, 'qualify_threshold', 60);
  v_is_fit := sc >= thr;
  v_fit := case when sc < 40 then 'poor' when sc < 60 then 'fair' when sc < 80 then 'good' else 'excellent' end;
  wq := case when res->>'website_quality' in ('none','poor','fair','good','unknown') then res->>'website_quality' else 'unknown' end;
  ob := case when res->>'has_online_booking' in ('yes','no','unknown') then res->>'has_online_booking' else 'unknown' end;

  update acq.lead_qualification set is_current = false, updated_at = now() where lead_id = l.id and is_current;
  insert into acq.lead_qualification (org_id, lead_id, score, fit, is_fit, reasons, pain_points, website_quality, has_online_booking,
                                      booking_availability, recommended_offer, summary, signals, model, prompt_version)
  values (l.org_id, l.id, sc, v_fit, v_is_fit, acq.text_array(res->'reasons', 8, 300), acq.text_array(res->'pain_points', 8, 300), wq, ob,
          acq.clip(res->>'booking_availability', 500), acq.clip(res->>'recommended_offer', 500), acq.clip(res->>'summary', 1500),
          case when jsonb_typeof(res->'signals') = 'object' and length((res->'signals')::text) <= 20000 then res->'signals' else '{}'::jsonb end,
          left(p_model, 80), left(p_prompt_version, 40))
  returning id into qid;

  new_status := l.status;
  if auth.uid() is null then perform set_config('acq.actor', coalesce(nullif(current_setting('acq.actor', true), ''), 'n8n'), true); end if;
  perform set_config('acq.reason', 'ai_score_' || sc, true);
  update acq.leads set score = sc, qual_locked_until = null, qual_error = null, requalify_requested_at = null, qual_attempts = 0,
         status = case when status = 'new_lead' and v_is_fit and not do_not_contact then 'qualified' else status end
   where id = l.id returning status into new_status;
  perform set_config('acq.reason', '', true);
  return jsonb_build_object('ok', true, 'qualification_id', qid, 'score', sc, 'fit', v_fit, 'is_fit', v_is_fit, 'status', new_status);
end $$;

create or replace function acq.requalify_lead(p_lead uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member');
begin
  update acq.leads set requalify_requested_at = now(), qual_attempts = 0, qual_locked_until = null, qual_error = null
   where id = p_lead and org_id = o and status in ('new_lead', 'qualified') and not do_not_contact;
  if not found then perform acq.fail('lead_not_found', 'Lead not found, or not in a status that can be re-qualified.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- User RPCs (frontend / edge function, role + org re-checked inside)
-- ---------------------------------------------------------------------

create or replace function acq.import_leads(p_items jsonb, p_source_key text default 'csv')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); sid uuid; res jsonb;
begin
  select id into sid from acq.lead_sources where org_id = o and key = lower(btrim(p_source_key)) and active and provider in ('manual', 'csv');
  if sid is null then perform acq.fail('source_not_found', 'Use the manual or csv source for imports.'); end if;
  res := acq.ingest_leads(o, sid, null, p_items, '{}'::jsonb);
  perform acq.activity(o, 'leads.imported', 'lead_source', sid::text, null, res - 'errors');
  return res;
end $$;

create or replace function acq.move_lead(p_lead uuid, p_to text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member'); l acq.leads;
begin
  select * into l from acq.leads where id = p_lead and org_id = o for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  if p_to = 'lost' and nullif(btrim(coalesce(p_reason, '')), '') is null then perform acq.fail('reason_required', 'Give a reason when marking a lead lost.'); end if;
  perform set_config('acq.reason', left(coalesce(p_reason, 'manual'), 200), true);
  update acq.leads set status = p_to where id = l.id;
  perform set_config('acq.reason', '', true);
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'from', l.status, 'to', p_to);
end $$;

create or replace function acq.mark_do_not_contact(p_lead uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('member');
begin
  if not exists (select 1 from acq.leads where id = p_lead and org_id = o) then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  return acq.suppress_lead(p_lead, 'manual', 'user:' || coalesce(left(p_note, 80), ''));
end $$;

create or replace function acq.erase_lead(p_lead uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('admin');
begin
  if not exists (select 1 from acq.leads where id = p_lead and org_id = o) then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  perform acq.suppress_lead(p_lead, 'erasure', 'user');     -- keeps only hashed identifiers so the lead is never re-imported
  delete from acq.leads where id = p_lead and org_id = o;
  perform acq.activity(o, 'lead.erased', 'lead', p_lead::text, null, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

create or replace function acq.reinstate_lead(p_lead uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('owner'); l acq.leads;
begin
  select * into l from acq.leads where id = p_lead and org_id = o for update;
  if l.id is null then perform acq.fail('lead_not_found', 'Lead not found.'); end if;
  if not l.do_not_contact then perform acq.fail('not_suppressed', 'This lead is not marked do-not-contact.'); end if;
  if coalesce(l.dnc_reason, '') not in ('manual', 'negative_reply') or l.unsubscribed_at is not null then
    perform acq.fail('cannot_reinstate', 'Unsubscribes, bounces, complaints and erasures can never be reinstated.');
  end if;
  delete from acq.suppressions where org_id = o and reason in ('manual', 'negative_reply') and lead_id = l.id;
  perform set_config('acq.allow_dnc_clear', 'on', true);
  perform set_config('acq.reason', 'reinstated', true);
  update acq.leads set do_not_contact = false, dnc_reason = null, status = case when status = 'lost' then 'new_lead' else status end where id = l.id;
  perform set_config('acq.allow_dnc_clear', '', true);
  perform set_config('acq.reason', '', true);
  perform acq.activity(o, 'lead.reinstated', 'lead', l.id::text, l.id, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Rate limiting (fixed window) for edge functions and public endpoints — service only
-- ---------------------------------------------------------------------

create or replace function acq.hit_rate_limit(p_key text, p_limit int, p_window_s int)
returns jsonb language plpgsql as $$
declare w timestamptz; h int;
begin
  if p_key is null or length(p_key) > 200 or p_limit < 1 or p_window_s < 1 then perform acq.fail('invalid_rate_limit', 'Bad rate-limit arguments.'); end if;
  w := to_timestamp(floor(extract(epoch from now()) / p_window_s) * p_window_s);
  insert into acq.rate_limits as r (key, window_start, hits) values (p_key, w, 1)
  on conflict (key, window_start) do update set hits = r.hits + 1 returning r.hits into h;
  if random() < 0.01 then delete from acq.rate_limits where window_start < now() - interval '1 day'; end if;
  return jsonb_build_object('allowed', h <= p_limit, 'hits', h, 'limit', p_limit,
                            'retry_after_s', case when h <= p_limit then 0 else ceil(extract(epoch from (w + make_interval(secs => p_window_s) - now())))::int end);
end $$;

-- ---------------------------------------------------------------------
-- Read models for the CRM board (respect RLS of the caller)
-- ---------------------------------------------------------------------

create or replace view acq.v_leads with (security_invoker = true) as
select l.id, l.org_id, l.business_name, l.website, l.domain, l.phone, l.email, l.category, l.niche, l.city, l.region, l.country_code,
       l.status, l.score, l.rating, l.review_count, l.owner_id, l.tags, l.notes, l.do_not_contact, l.source_id, s.key as source_key,
       l.created_at, l.updated_at, l.last_contacted_at, l.last_reply_at, l.lost_reason,
       q.fit, q.is_fit, q.reasons, q.pain_points, q.website_quality, q.has_online_booking, q.booking_availability,
       q.recommended_offer, q.summary as qualification_summary, q.created_at as qualified_on
from acq.leads l
left join acq.lead_sources s on s.id = l.source_id and s.org_id = l.org_id
left join acq.lead_qualification q on q.lead_id = l.id and q.is_current;

create or replace view acq.v_pipeline with (security_invoker = true) as
select org_id, status, count(*)::int as leads, round(avg(score))::int as avg_score
from acq.leads group by org_id, status;

-- ---------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------

revoke execute on all functions in schema acq from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on all tables in schema acq to authenticated;
    revoke select on acq.rate_limits from authenticated;
    grant execute on function acq.import_leads(jsonb, text), acq.move_lead(uuid, text, text), acq.mark_do_not_contact(uuid, text),
                              acq.erase_lead(uuid), acq.reinstate_lead(uuid), acq.requalify_lead(uuid),
                              acq.queue_search_run(text, text, text, text, text, int) to authenticated;
    -- helpers used inside RLS / views
    grant execute on function acq.status_allowed(text, text), acq.status_rank(text), acq.setting_int(uuid, text, int),
                              acq.setting_bool(uuid, text, boolean) to authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant all on all tables in schema acq to service_role;
    grant execute on all functions in schema acq to service_role;
    grant usage, select on all sequences in schema acq to service_role;
  end if;
end $$;
revoke execute on function acq.create_organization(text, text, text) from public;

-- existing organisations pick up the new settings
select acq.seed_org_settings(id) from acq.organizations;
