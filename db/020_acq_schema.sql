-- =====================================================================
-- ACQ — client-acquisition CRM + outreach engine
-- Phase 1: schema, constraints, triggers, RLS, grants.
--
-- Separate schema `acq` (the booking engine in `bos` is untouched and stays unexposed).
-- Expose `acq` to the Supabase API (Settings > API > Exposed schemas: public, acq) so the
-- frontend can SELECT under RLS and call RPCs. NEVER expose `bos`.
--
-- Rules baked in here (not in n8n):
--   * outreach_messages cannot reach a sendable status without approval_status = 'approved'
--   * every child row carries org_id and composite FKs keep it equal to its parent's org_id
--   * authenticated users get SELECT + a few column-limited writes; everything else is an RPC
--   * pipeline_events / activity_logs are append-only
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE).
-- =====================================================================

create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;
create schema if not exists acq;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

create or replace function acq.fail(p_code text, p_message text)
returns void language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = p_message;
end $$;

create or replace function acq.role_rank(p text)
returns int language sql immutable as $$
  select case p when 'owner' then 4 when 'admin' then 3 when 'member' then 2 when 'viewer' then 1 else 0 end
$$;

create or replace function acq.valid_followup_steps(p jsonb)
returns boolean language sql immutable as $$
  select case when jsonb_typeof(p) = 'array' and jsonb_array_length(p) <= 6 then
    not exists (
      select 1 from jsonb_array_elements(p) e
      where jsonb_typeof(e) <> 'object'
         or coalesce(e->>'delay_days', '') !~ '^[0-9]{1,2}$'
         or (e->>'delay_days')::int not between 1 and 60)
  else false end
$$;

create or replace function acq.norm_email(p text)
returns text language sql immutable as $$
  select case when lower(btrim(p)) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(btrim(p)) <= 254
              then lower(btrim(p)) end
$$;

create or replace function acq.norm_domain(p text)
returns text language plpgsql immutable as $$
declare d text;
begin
  if p is null or btrim(p) = '' then return null; end if;
  d := lower(btrim(p));
  d := regexp_replace(d, '^[a-z][a-z0-9+.-]*://', '');
  d := regexp_replace(d, '[/?#].*$', '');
  d := regexp_replace(d, '^[^@]*@', '');
  d := regexp_replace(d, ':[0-9]+$', '');
  d := regexp_replace(d, '^www[0-9]*\.', '');
  d := regexp_replace(d, '\.+$', '');
  if d !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' then return null; end if;
  -- must end in an alphabetic TLD (rejects IP literals) and must not be an internal-only name (SSRF guard for site fetching)
  if d !~ '\.[a-z]{2,}$' or d ~ '\.(local|localhost|internal|lan|home|corp|intranet|test|invalid|example)$' or d = 'localhost' then return null; end if;
  -- social / directory / booking-marketplace hosts are not a business's own domain
  if d = any (array['facebook.com','m.facebook.com','instagram.com','linktr.ee','linkedin.com','twitter.com','x.com',
                    'yelp.com','google.com','maps.google.com','booksy.com','fresha.com','treatwell.co.uk','yell.com',
                    'tiktok.com','youtube.com','wa.me','g.page','goo.gl','bit.ly']) then return null; end if;
  return d;
end $$;

create or replace function acq.dial_code(p_cc text)
returns text language sql immutable as $$
  select case upper(p_cc)
    when 'GB' then '44' when 'US' then '1' when 'CA' then '1' when 'AU' then '61' when 'IE' then '353'
    when 'PH' then '63' when 'NZ' then '64' when 'AE' then '971' when 'SG' then '65' when 'ZA' then '27'
    when 'IN' then '91' when 'DE' then '49' when 'FR' then '33' when 'ES' then '34' when 'NL' then '31'
    else null end
$$;

-- E.164 or NULL (never guesses a country code for an unknown country).
create or replace function acq.norm_phone(p text, p_country text default null)
returns text language plpgsql immutable as $$
declare s text; cc text := acq.dial_code(p_country); r text;
begin
  if p is null or btrim(p) = '' then return null; end if;
  s := regexp_replace(btrim(p), '[^0-9+]', '', 'g');
  if s like '+%' then r := '+' || regexp_replace(s, '[^0-9]', '', 'g');
  elsif s like '00%' then r := '+' || substr(s, 3);
  elsif s like '0%' and cc is not null then r := '+' || cc || substr(s, 2);
  elsif cc is not null and length(s) >= 10 and s like cc || '%' then r := '+' || s;
  else return null; end if;
  return case when r ~ '^\+[1-9][0-9]{7,14}$' then r end;
end $$;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table if not exists acq.organizations (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(btrim(name)) between 2 and 120),
  slug             text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  status           text not null default 'active' check (status in ('active','suspended')),
  outreach_enabled boolean not null default false,       -- nothing is ever sent until an operator flips this
  timezone         text not null default 'Europe/London',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid
);

create table if not exists acq.profiles (
  id        uuid primary key references auth.users(id) on delete cascade,
  org_id    uuid not null references acq.organizations(id) on delete cascade,
  email     text,
  full_name text,
  role      text not null default 'member' check (role in ('owner','admin','member','viewer')),
  active    boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid
);
create index if not exists profiles_org on acq.profiles (org_id);

create table if not exists acq.system_settings (
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  key         text not null check (key ~ '^[a-z0-9_]{2,60}$'),
  value       jsonb not null,
  description text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  primary key (org_id, key)
);

create table if not exists acq.lead_sources (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references acq.organizations(id) on delete cascade,
  key        text not null check (key ~ '^[a-z0-9_]{2,40}$'),
  name       text not null check (length(btrim(name)) between 1 and 100),
  provider   text not null default 'manual'
             check (provider in ('manual','csv','osm_overpass','google_places','apify','apollo','hunter','other')),
  config     jsonb not null default '{}'::jsonb
             check (jsonb_typeof(config) = 'object' and config::text !~* '(api[_-]?key|secret|token|password)'),
  active     boolean not null default true,
  daily_limit int not null default 200 check (daily_limit between 0 and 5000),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (org_id, key), unique (id, org_id)
);

create table if not exists acq.lead_search_runs (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references acq.organizations(id) on delete cascade,
  source_id    uuid not null,
  niche        text not null check (length(btrim(niche)) between 2 and 80),
  city         text check (city is null or length(city) <= 80),
  region       text check (region is null or length(region) <= 80),
  country_code text not null check (country_code ~ '^[A-Z]{2}$'),
  max_results  int not null default 20 check (max_results between 1 and 60),
  status       text not null default 'queued' check (status in ('queued','running','completed','failed','cancelled')),
  found_count  int not null default 0, new_count int not null default 0, dup_count int not null default 0,
  attempts     int not null default 0, locked_until timestamptz,
  error        text,
  started_at   timestamptz, finished_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id),
  foreign key (source_id, org_id) references acq.lead_sources (id, org_id) on delete cascade
);
create index if not exists lead_search_runs_queue on acq.lead_search_runs (status, created_at);

create table if not exists acq.outreach_campaigns (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references acq.organizations(id) on delete cascade,
  name             text not null check (length(btrim(name)) between 1 and 120),
  channel          text not null default 'email' check (channel in ('email','sms')),
  status           text not null default 'draft' check (status in ('draft','active','paused','archived')),
  niche            text,                                  -- NULL = any niche
  country_code     text check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  min_score        int  not null default 60 check (min_score between 0 and 100),
  daily_limit      int  not null default 20 check (daily_limit between 1 and 200),
  offer            text check (offer is null or length(offer) <= 1000),
  subject_template text check (subject_template is null or length(subject_template) <= 200),
  body_template    text check (body_template is null or length(body_template) <= 3000),
  followup_steps   jsonb not null default '[]'::jsonb check (acq.valid_followup_steps(followup_steps)),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (org_id, name), unique (id, org_id)
);

create table if not exists acq.leads (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references acq.organizations(id) on delete cascade,
  source_id     uuid,
  search_run_id uuid,
  campaign_id   uuid,
  external_id   text,
  business_name text not null check (length(btrim(business_name)) between 1 and 200),
  website       text check (website is null or length(website) <= 500),
  domain        text,
  phone         text check (phone is null or length(phone) <= 40),
  phone_e164    text check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  email         text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  category      text check (category is null or length(category) <= 120),
  niche         text check (niche is null or length(niche) <= 80),
  address       text check (address is null or length(address) <= 300),
  city          text check (city is null or length(city) <= 80),
  region        text check (region is null or length(region) <= 80),
  country_code  text check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  rating        numeric(2,1) check (rating is null or rating between 0 and 5),
  review_count  int check (review_count is null or review_count >= 0),
  status        text not null default 'new_lead'
                check (status in ('new_lead','qualified','approved','contacted','replied','demo_sent','meeting_booked','won','lost')),
  score         int check (score is null or score between 0 and 100),
  qualified_at  timestamptz,
  owner_id      uuid,
  tags          text[] not null default '{}',
  notes         text check (notes is null or length(notes) <= 5000),
  do_not_contact boolean not null default false,
  unsubscribed_at timestamptz,
  dnc_reason    text,
  lost_reason   text, lost_at timestamptz, won_at timestamptz,
  last_contacted_at timestamptz, last_reply_at timestamptz,
  raw           jsonb not null default '{}'::jsonb check (jsonb_typeof(raw) = 'object'),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id),
  foreign key (source_id, org_id)     references acq.lead_sources (id, org_id)       on delete set null (source_id),
  foreign key (search_run_id, org_id) references acq.lead_search_runs (id, org_id)   on delete set null (search_run_id),
  foreign key (campaign_id, org_id)   references acq.outreach_campaigns (id, org_id) on delete set null (campaign_id)
);
-- duplicate prevention (the ingest function merges before it ever hits these)
create unique index if not exists leads_uq_domain on acq.leads (org_id, domain)     where domain is not null;
create unique index if not exists leads_uq_phone  on acq.leads (org_id, phone_e164) where phone_e164 is not null;
create unique index if not exists leads_uq_email  on acq.leads (org_id, email)      where email is not null;
create unique index if not exists leads_uq_ext    on acq.leads (org_id, source_id, external_id) where external_id is not null;
create unique index if not exists leads_uq_name   on acq.leads (org_id, lower(btrim(business_name)), lower(coalesce(city, '')))
  where domain is null and phone_e164 is null and email is null;
create index if not exists leads_status on acq.leads (org_id, status);
create index if not exists leads_niche  on acq.leads (org_id, niche, status);
create index if not exists leads_source on acq.leads (org_id, source_id);
create index if not exists leads_score  on acq.leads (org_id, score desc nulls last);

create table if not exists acq.lead_qualification (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  lead_id     uuid not null,
  score       int  not null check (score between 0 and 100),
  fit         text not null check (fit in ('poor','fair','good','excellent')),
  is_fit      boolean not null,
  reasons     text[] not null default '{}',
  pain_points text[] not null default '{}',
  website_quality text not null default 'unknown' check (website_quality in ('none','poor','fair','good','unknown')),
  has_online_booking text not null default 'unknown' check (has_online_booking in ('yes','no','unknown')),
  booking_availability text,
  recommended_offer text,
  summary     text,
  model       text, prompt_version text, input_hash text,
  is_current  boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  foreign key (lead_id, org_id) references acq.leads (id, org_id) on delete cascade
);
create unique index if not exists lead_qualification_current on acq.lead_qualification (lead_id) where is_current;
create index if not exists lead_qualification_lead on acq.lead_qualification (lead_id, created_at desc);

create table if not exists acq.pipeline_events (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  lead_id     uuid not null,
  from_status text,
  to_status   text not null,
  actor_type  text not null default 'system' check (actor_type in ('user','system','n8n','edge')),
  actor_id    uuid,
  reason      text,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  foreign key (lead_id, org_id) references acq.leads (id, org_id) on delete cascade
);
create index if not exists pipeline_events_lead on acq.pipeline_events (lead_id, created_at);
create index if not exists pipeline_events_org_time on acq.pipeline_events (org_id, created_at);

create table if not exists acq.outreach_messages (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references acq.organizations(id) on delete cascade,
  lead_id       uuid not null,
  campaign_id   uuid,
  followup_id   uuid,
  kind          text not null default 'outreach' check (kind in ('outreach','followup','reply')),
  channel       text not null check (channel in ('email','sms')),
  step          int check (step between 0 and 10),
  to_address    text not null check (length(to_address) between 3 and 254),
  from_address  text, reply_to text,
  subject       text check (subject is null or length(subject) <= 300),
  body          text not null check (length(body) between 1 and 5000),
  status        text not null default 'pending_approval'
                check (status in ('draft','pending_approval','approved','queued','sending','sent','delivered','opened',
                                  'clicked','bounced','complained','failed','rejected','cancelled')),
  approval_status text not null default 'pending' check (approval_status in ('pending','approved','rejected')),
  approval_source text check (approval_source in ('user','auto_followup')),
  approved_by   uuid, approved_at timestamptz, rejected_reason text,
  generated_by  text not null default 'ai' check (generated_by in ('ai','human','template')),
  ai_model      text,
  scheduled_at  timestamptz,
  sent_at timestamptz, delivered_at timestamptz, opened_at timestamptz, clicked_at timestamptz, bounced_at timestamptz,
  provider      text check (provider is null or provider in ('resend','gmail','twilio')),
  provider_message_id text,
  reply_token       text not null default replace(gen_random_uuid()::text, '-', ''),
  unsubscribe_token text not null default replace(gen_random_uuid()::text, '-', ''),
  attempts int not null default 0, max_attempts int not null default 3,
  locked_until timestamptz, last_error text,
  open_count int not null default 0, click_count int not null default 0,
  idempotency_key text not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id), unique (org_id, idempotency_key), unique (reply_token), unique (unsubscribe_token),
  foreign key (lead_id, org_id)     references acq.leads (id, org_id) on delete cascade,
  foreign key (campaign_id, org_id) references acq.outreach_campaigns (id, org_id) on delete set null (campaign_id),
  -- THE approval gate: nothing can be queued, sent or tracked unless a person (or the explicit follow-up rule) approved it
  constraint outreach_requires_approval check (
    status in ('draft','pending_approval','rejected','cancelled') or approval_status = 'approved'),
  constraint outreach_approver_recorded check (
    approval_status <> 'approved'
    or (approval_source is not null and (approval_source = 'auto_followup' or approved_by is not null))),
  constraint outreach_step_for_kind check ((kind = 'reply') = (step is null))
);
create unique index if not exists outreach_uq_provider on acq.outreach_messages (provider, provider_message_id)
  where provider_message_id is not null;
create unique index if not exists outreach_uq_lead_step on acq.outreach_messages (lead_id, step)
  where step is not null and status not in ('rejected','cancelled','failed');
create index if not exists outreach_send_queue on acq.outreach_messages (status, scheduled_at);
create index if not exists outreach_lead on acq.outreach_messages (lead_id, created_at);
create index if not exists outreach_org_status on acq.outreach_messages (org_id, status, created_at);

create table if not exists acq.replies (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references acq.organizations(id) on delete cascade,
  lead_id       uuid,
  message_id    uuid,
  match_status  text not null default 'unmatched' check (match_status in ('matched','unmatched')),
  channel       text not null check (channel in ('email','sms')),
  from_address  text not null, to_address text,
  subject       text check (subject is null or length(subject) <= 500),
  body          text not null check (length(body) <= 20000),
  provider_message_id text,
  in_reply_to   text,
  received_at   timestamptz not null default now(),
  classification text not null default 'unclassified'
                 check (classification in ('positive','negative','question','not_interested','follow_up_needed',
                                           'unsubscribe','out_of_office','unclassified')),
  classification_confidence numeric(3,2) check (classification_confidence is null or classification_confidence between 0 and 1),
  classified_by text, summary text,
  suggested_response text check (suggested_response is null or length(suggested_response) <= 5000),
  response_status text not null default 'none' check (response_status in ('none','pending_approval','approved','rejected','sent')),
  response_message_id uuid,
  handled_at timestamptz,
  raw           jsonb not null default '{}'::jsonb check (jsonb_typeof(raw) = 'object'),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id),
  foreign key (lead_id, org_id)             references acq.leads (id, org_id) on delete cascade,
  foreign key (message_id, org_id)          references acq.outreach_messages (id, org_id) on delete set null (message_id),
  foreign key (response_message_id, org_id) references acq.outreach_messages (id, org_id) on delete set null (response_message_id),
  constraint replies_matched_has_lead check ((match_status = 'matched') = (lead_id is not null))
);
create unique index if not exists replies_uq_provider on acq.replies (org_id, channel, provider_message_id) where provider_message_id is not null;
create index if not exists replies_lead on acq.replies (lead_id, received_at);
create index if not exists replies_triage on acq.replies (org_id, classification, handled_at);

create table if not exists acq.demos (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  lead_id     uuid not null,
  token       text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  title       text,
  status      text not null default 'ready' check (status in ('draft','ready','sent','opened','clicked','booked','expired','revoked')),
  config      jsonb not null default '{}'::jsonb check (jsonb_typeof(config) = 'object'),   -- public demo content only
  expires_at  timestamptz not null default now() + interval '30 days',
  sent_at timestamptz, sent_message_id uuid,
  first_opened_at timestamptz, last_opened_at timestamptz,
  open_count int not null default 0, click_count int not null default 0,
  booked_at timestamptz, meeting_id uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id),
  foreign key (lead_id, org_id) references acq.leads (id, org_id) on delete cascade
);
create unique index if not exists demos_one_active on acq.demos (lead_id) where status not in ('expired','revoked');

create table if not exists acq.clients (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  lead_id     uuid,
  business_name text not null check (length(btrim(business_name)) between 1 and 200),
  contact_name text, email text, phone text, website text, industry text,
  plan        text, monthly_fee numeric(10,2) check (monthly_fee is null or monthly_fee >= 0),
  status      text not null default 'onboarding' check (status in ('onboarding','active','paused','churned')),
  bos_business_id uuid,                                   -- link to bos.businesses once provisioned (no FK: bos is a separate module)
  business_details     jsonb not null default '{}'::jsonb check (jsonb_typeof(business_details) = 'object'),
  receptionist_config  jsonb not null default '{}'::jsonb check (jsonb_typeof(receptionist_config) = 'object'),
  booking_requirements jsonb not null default '{}'::jsonb check (jsonb_typeof(booking_requirements) = 'object'),
  faqs         jsonb not null default '[]'::jsonb check (jsonb_typeof(faqs) = 'array'),
  integrations jsonb not null default '{}'::jsonb check (jsonb_typeof(integrations) = 'object'
                 and integrations::text !~* '(api[_-]?key|secret|token|password)'),   -- store references, never credentials
  won_at timestamptz not null default now(), go_live_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id),
  foreign key (lead_id, org_id) references acq.leads (id, org_id) on delete set null (lead_id)
);
create unique index if not exists clients_one_per_lead on acq.clients (lead_id) where lead_id is not null;

create table if not exists acq.onboarding_tasks (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  client_id   uuid not null,
  key         text not null check (key ~ '^[a-z0-9_]{2,60}$'),
  title       text not null check (length(title) between 1 and 200),
  description text, category text,
  status      text not null default 'todo' check (status in ('todo','in_progress','blocked','done','skipped')),
  assignee_id uuid, due_at timestamptz, completed_at timestamptz,
  sort_order  int not null default 0, notes text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (client_id, key),
  foreign key (client_id, org_id) references acq.clients (id, org_id) on delete cascade
);
create index if not exists onboarding_tasks_client on acq.onboarding_tasks (client_id, sort_order);

create table if not exists acq.meetings (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  lead_id     uuid,
  client_id   uuid,
  demo_id     uuid,
  host_id     uuid,
  title       text not null check (length(title) between 1 and 200),
  starts_at   timestamptz not null, ends_at timestamptz not null,
  timezone    text not null default 'Europe/London',
  status      text not null default 'scheduled' check (status in ('scheduled','completed','cancelled','no_show')),
  channel     text not null default 'google_meet' check (channel in ('google_meet','phone','in_person','zoom')),
  meeting_url text, attendee_name text, attendee_email text,
  source      text not null default 'manual' check (source in ('manual','demo_booking','ai')),
  outcome     text check (outcome is null or outcome in ('won','lost','follow_up','no_decision')),
  outcome_notes text, notes text,
  google_event_id text, calendar_id text,
  calendar_sync text not null default 'pending' check (calendar_sync in ('pending','processing','synced','failed','skipped')),
  calendar_sync_attempts int not null default 0, calendar_locked_until timestamptz, calendar_error text,
  calendar_version int not null default 1,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id),
  check (ends_at > starts_at),
  foreign key (lead_id, org_id)   references acq.leads (id, org_id)   on delete set null (lead_id),
  foreign key (client_id, org_id) references acq.clients (id, org_id) on delete set null (client_id),
  foreign key (demo_id, org_id)   references acq.demos (id, org_id)   on delete set null (demo_id),
  -- one host cannot be double-booked
  constraint meetings_no_overlap exclude using gist (
    org_id with =, (coalesce(host_id, org_id)) with =, tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'scheduled')
);
create index if not exists meetings_lead on acq.meetings (lead_id, starts_at);
create index if not exists meetings_org_time on acq.meetings (org_id, starts_at);
create index if not exists meetings_cal_queue on acq.meetings (calendar_sync, updated_at) where calendar_sync in ('pending','processing');

create table if not exists acq.followups (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  lead_id     uuid not null,
  campaign_id uuid,
  step        int not null check (step between 1 and 6),
  channel     text not null check (channel in ('email','sms')),
  due_at      timestamptz not null,
  status      text not null default 'scheduled' check (status in ('scheduled','drafting','drafted','cancelled','skipped')),
  message_id  uuid,
  cancel_reason text,
  attempts int not null default 0, locked_until timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid,
  unique (id, org_id), unique (lead_id, step),
  foreign key (lead_id, org_id)     references acq.leads (id, org_id) on delete cascade,
  foreign key (campaign_id, org_id) references acq.outreach_campaigns (id, org_id) on delete set null (campaign_id),
  foreign key (message_id, org_id)  references acq.outreach_messages (id, org_id) on delete set null (message_id)
);
create index if not exists followups_due on acq.followups (status, due_at);

-- deferred FKs (circular order)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'outreach_followup_fk') then
    alter table acq.outreach_messages add constraint outreach_followup_fk
      foreign key (followup_id, org_id) references acq.followups (id, org_id) on delete set null (followup_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'demos_meeting_fk') then
    alter table acq.demos add constraint demos_meeting_fk
      foreign key (meeting_id, org_id) references acq.meetings (id, org_id) on delete set null (meeting_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'demos_sent_message_fk') then
    alter table acq.demos add constraint demos_sent_message_fk
      foreign key (sent_message_id, org_id) references acq.outreach_messages (id, org_id) on delete set null (sent_message_id);
  end if;
end $$;

create table if not exists acq.suppressions (               -- never contact these again, even if re-discovered
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references acq.organizations(id) on delete cascade,
  kind       text not null check (kind in ('email','phone','domain')),
  value      text not null check (length(value) between 3 and 254),
  reason     text not null check (reason in ('unsubscribe','bounce','complaint','manual','erasure','negative_reply')),
  source     text, lead_id uuid,
  created_at timestamptz not null default now(), created_by uuid,
  unique (org_id, kind, value)
);

create table if not exists acq.activity_logs (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references acq.organizations(id) on delete cascade,
  actor_type  text not null default 'system' check (actor_type in ('user','system','n8n','edge')),
  actor_id    uuid,
  action      text not null,
  entity_type text, entity_id text, lead_id uuid,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists activity_logs_org_time on acq.activity_logs (org_id, created_at desc);
create index if not exists activity_logs_entity on acq.activity_logs (entity_type, entity_id);

create table if not exists acq.rate_limits (                -- fixed-window counters for edge functions / public endpoints
  key          text not null,
  window_start timestamptz not null,
  hits         int not null default 0,
  primary key (key, window_start)
);

-- ---------------------------------------------------------------------
-- Auth helpers (SECURITY DEFINER so RLS policies don't recurse into profiles)
-- ---------------------------------------------------------------------

create or replace function acq.current_org_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select p.org_id from acq.profiles p join acq.organizations o on o.id = p.org_id
  where p.id = auth.uid() and p.active and o.status = 'active'
$$;

create or replace function acq.my_role()
returns text language sql stable security definer set search_path = '' as $$
  select p.role from acq.profiles p where p.id = auth.uid() and p.active
$$;

create or replace function acq.require_role(p_min text)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare o uuid := acq.current_org_id(); r text := acq.my_role();
begin
  if o is null or acq.role_rank(r) < acq.role_rank(p_min) then
    raise exception using errcode = '42501', message = 'forbidden', detail = 'Requires role ' || p_min || ' or higher.';
  end if;
  return o;
end $$;

create or replace function acq.setting(p_org uuid, p_key text, p_default jsonb default null)
returns jsonb language sql stable as $$
  select coalesce((select s.value from acq.system_settings s where s.org_id = p_org and s.key = p_key), p_default)
$$;

create or replace function acq.activity(p_org uuid, p_action text, p_entity_type text, p_entity_id text,
                                        p_lead uuid default null, p_meta jsonb default '{}'::jsonb,
                                        p_actor_type text default null)
returns void language sql security definer set search_path = '' as $$
  insert into acq.activity_logs (org_id, actor_type, actor_id, action, entity_type, entity_id, lead_id, metadata)
  values (p_org, coalesce(p_actor_type, case when auth.uid() is null then 'system' else 'user' end),
          auth.uid(), p_action, p_entity_type, p_entity_id, p_lead, coalesce(p_meta, '{}'::jsonb))
$$;

-- ---------------------------------------------------------------------
-- Triggers: audit fields, tenant immutability, lead normalisation, append-only, audit log
-- ---------------------------------------------------------------------

create or replace function acq.tg_touch() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
    new.created_at := coalesce(new.created_at, now());
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

create or replace function acq.tg_org_immutable() returns trigger language plpgsql as $$
begin
  if new.org_id is distinct from old.org_id then
    raise exception using errcode = '42501', message = 'org_id is immutable';
  end if;
  return new;
end $$;

create or replace function acq.tg_leads_normalize() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.business_name := btrim(new.business_name);
  new.email := acq.norm_email(new.email);
  new.domain := acq.norm_domain(new.website);
  new.phone_e164 := acq.norm_phone(new.phone, new.country_code);
  new.country_code := upper(new.country_code);
  return new;
end $$;

create or replace function acq.tg_append_only() returns trigger language plpgsql as $$
begin
  -- cascade deletes (lead / org removal) run one trigger level deeper and are allowed
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if;
  raise exception using errcode = '42501', message = tg_table_name || ' is append-only';
end $$;

create or replace function acq.tg_audit() returns trigger language plpgsql security definer set search_path = '' as $$
declare r jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end); changed jsonb := '[]'::jsonb;
begin
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_agg(e.key order by e.key), '[]'::jsonb) into changed
    from jsonb_each(to_jsonb(new)) e
    where to_jsonb(old) -> e.key is distinct from e.value and e.key not in ('updated_at', 'updated_by');
    if jsonb_array_length(changed) = 0 then return new; end if;
  end if;
  insert into acq.activity_logs (org_id, actor_type, actor_id, action, entity_type, entity_id, lead_id, metadata)
  values ((coalesce(r->>'org_id', r->>'id'))::uuid,
          case when auth.uid() is null then 'system' else 'user' end, auth.uid(),
          tg_table_name || '.' || lower(tg_op), tg_table_name,
          coalesce(r->>'id', r->>'key'), nullif(r->>'lead_id', '')::uuid,
          jsonb_build_object('changed', changed));
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['organizations','profiles','system_settings','lead_sources','lead_search_runs','outreach_campaigns',
                           'leads','lead_qualification','outreach_messages','replies','demos','clients','onboarding_tasks',
                           'meetings','followups'] loop
    execute format('create or replace trigger tg_touch before insert or update on acq.%I for each row execute function acq.tg_touch()', t);
  end loop;
  foreach t in array array['profiles','system_settings','lead_sources','lead_search_runs','outreach_campaigns','leads',
                           'lead_qualification','pipeline_events','outreach_messages','replies','demos','clients',
                           'onboarding_tasks','meetings','followups','suppressions','activity_logs'] loop
    execute format('create or replace trigger tg_org_immutable before update on acq.%I for each row execute function acq.tg_org_immutable()', t);
  end loop;
  foreach t in array array['pipeline_events','activity_logs'] loop
    execute format('create or replace trigger tg_append_only before update or delete on acq.%I for each row execute function acq.tg_append_only()', t);
  end loop;
  foreach t in array array['organizations','profiles','system_settings','lead_sources','outreach_campaigns',
                           'outreach_messages','demos','clients','meetings','suppressions'] loop
    execute format('create or replace trigger tg_audit after insert or update or delete on acq.%I for each row execute function acq.tg_audit()', t);
  end loop;
end $$;

create or replace trigger tg_leads_normalize before insert or update on acq.leads
  for each row execute function acq.tg_leads_normalize();

-- ---------------------------------------------------------------------
-- Organisation bootstrap (service / SQL editor only — never callable from the frontend)
-- ---------------------------------------------------------------------

create or replace function acq.seed_org_settings(p_org uuid)
returns void language sql as $$
  insert into acq.system_settings (org_id, key, value, description) values
    (p_org, 'qualify_threshold',        '60', 'Minimum AI score (0-100) for a lead to become Qualified'),
    (p_org, 'send_window',              '{"tz":"Europe/London","start":"09:00","end":"17:00","days":[1,2,3,4,5]}', 'When outreach may be sent (local time)'),
    (p_org, 'daily_send_limit',         '{"email":25,"sms":0}', 'Max outreach sends per day per channel. 0 disables the channel.'),
    (p_org, 'per_domain_daily_limit',   '1',   'Max emails per recipient domain per day'),
    (p_org, 'min_send_gap_seconds',     '120', 'Minimum gap between two sends'),
    (p_org, 'followups_require_approval','true','If false, follow-ups to leads already approved once are auto-approved (still capped and windowed)'),
    (p_org, 'followup_max_steps',       '3',   'Hard cap on follow-ups per lead'),
    (p_org, 'sms_outreach_enabled',     'false','Cold SMS is legally restricted in many countries. Keep off unless you have a lawful basis.'),
    (p_org, 'sender',                   '{"from_name":"","from_email":"","reply_to_email":"","postal_address":""}', 'Email sender identity. Sending is blocked until from_email and postal_address are set.'),
    (p_org, 'demo_base_url',            '""',  'Public base URL of the demo page, e.g. https://site.com/demo'),
    (p_org, 'tracking_base_url',        '""',  'Base URL of the track / unsubscribe edge function'),
    (p_org, 'meeting',                  '{"duration_min":30,"tz":"Europe/London","hours":{"1":["09:00","17:00"],"2":["09:00","17:00"],"3":["09:00","17:00"],"4":["09:00","17:00"],"5":["09:00","17:00"]},"min_notice_min":240,"max_days_ahead":21,"calendar_id":"primary","slot_step_min":30}', 'Sales call availability'),
    (p_org, 'ai',                       '{"prompt_version":"v1","model":"gpt-5-mini"}', 'AI prompt version and model name used by n8n'),
    (p_org, 'notify_email',             '""', 'Where the daily digest of pending work is sent. Empty = digest off.'),
    (p_org, 'daily_digest',             'true', 'Send the daily digest (needs notify_email and a sender address)'),
    (p_org, 'max_search_runs_per_day',  '20',  'Cap on lead-finder searches per day'),
    (p_org, 'default_country',          '"GB"','Country (ISO-2) assumed for imported leads that do not state one; used to read local phone numbers'),
    (p_org, 'offer_context',            '"We sell an AI receptionist and online booking system for appointment-based small businesses: it answers calls and website voice chat 24/7, books into their calendar, sends confirmations and reminders by SMS, and handles reschedules and cancellations. Best fit: clinics, dentists, salons, spas, physio, gyms, garages, tutors and consultants that take bookings by phone or have no online booking."', 'What we sell and who it fits (used in AI prompts)')
  on conflict (org_id, key) do nothing
$$;

create or replace function acq.create_organization(p_name text, p_slug text, p_owner_email text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare o uuid; u record;
begin
  insert into acq.organizations (name, slug) values (p_name, lower(p_slug)) returning id into o;
  perform acq.seed_org_settings(o);
  insert into acq.lead_sources (org_id, key, name, provider) values (o, 'manual', 'Manual entry', 'manual'), (o, 'csv', 'CSV import', 'csv')
  on conflict do nothing;
  if p_owner_email is not null then
    select id, email into u from auth.users where lower(email) = lower(p_owner_email);
    if u.id is null then perform acq.fail('user_not_found', 'No auth user with that email. Create the user first.'); end if;
    insert into acq.profiles (id, org_id, email, role) values (u.id, o, u.email, 'owner');
  end if;
  return o;
end $$;

create or replace function acq.add_member(p_email text, p_role text default 'member')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('admin'); u record; me text := acq.my_role();
begin
  if p_role not in ('admin','member','viewer') then perform acq.fail('invalid_role', 'Role must be admin, member or viewer.'); end if;
  if p_role = 'admin' and me <> 'owner' then perform acq.fail('forbidden', 'Only an owner can add an admin.'); end if;
  select id, email into u from auth.users where lower(email) = lower(btrim(p_email));
  if u.id is null then perform acq.fail('user_not_found', 'That person has no account yet. Invite them in Supabase Auth first.'); end if;
  if exists (select 1 from acq.profiles where id = u.id and org_id <> o) then
    perform acq.fail('belongs_to_other_org', 'That user already belongs to another organisation.');
  end if;
  insert into acq.profiles (id, org_id, email, role) values (u.id, o, u.email, p_role)
  on conflict (id) do update set role = excluded.role, active = true
  where acq.profiles.role <> 'owner';
  perform acq.activity(o, 'member.added', 'profile', u.id::text, null, jsonb_build_object('role', p_role));
  return jsonb_build_object('ok', true, 'user_id', u.id, 'role', p_role);
end $$;

-- ---------------------------------------------------------------------
-- RLS + grants
-- ---------------------------------------------------------------------

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'acq' loop
    execute format('alter table acq.%I enable row level security', t);
  end loop;
end $$;

do $$
declare t text;
begin
  -- read access: members of the org (any role, including viewer)
  foreach t in array array['profiles','system_settings','lead_sources','lead_search_runs','outreach_campaigns','leads',
                           'lead_qualification','pipeline_events','outreach_messages','replies','demos','clients',
                           'onboarding_tasks','meetings','followups','suppressions','activity_logs'] loop
    if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = t and policyname = t || '_select') then
      execute format('alter policy %I on acq.%I to authenticated using (org_id = (select acq.current_org_id()))', t || '_select', t);
    else
      execute format('create policy %I on acq.%I for select to authenticated using (org_id = (select acq.current_org_id()))', t || '_select', t);
    end if;
  end loop;
end $$;

do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'organizations' and policyname = 'organizations_select') then
    alter policy organizations_select on acq.organizations to authenticated
      using (id = (select acq.current_org_id()));
  else
    create policy organizations_select on acq.organizations for select to authenticated
      using (id = (select acq.current_org_id()));
  end if;
end $$;

-- limited direct writes (everything else goes through RPCs that re-check role + org)
do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'leads' and policyname = 'leads_update') then
    alter policy leads_update on acq.leads to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 2)
  with check (org_id = (select acq.current_org_id()));
  else
    create policy leads_update on acq.leads for update to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 2)
      with check (org_id = (select acq.current_org_id()));
  end if;
end $$;

do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'onboarding_tasks' and policyname = 'onboarding_tasks_update') then
    alter policy onboarding_tasks_update on acq.onboarding_tasks to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 2)
  with check (org_id = (select acq.current_org_id()));
  else
    create policy onboarding_tasks_update on acq.onboarding_tasks for update to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 2)
      with check (org_id = (select acq.current_org_id()));
  end if;
end $$;

do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'clients' and policyname = 'clients_update') then
    alter policy clients_update on acq.clients to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 2)
  with check (org_id = (select acq.current_org_id()));
  else
    create policy clients_update on acq.clients for update to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 2)
      with check (org_id = (select acq.current_org_id()));
  end if;
end $$;

do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'lead_sources' and policyname = 'lead_sources_write') then
    alter policy lead_sources_write on acq.lead_sources to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3)
  with check (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3);
  else
    create policy lead_sources_write on acq.lead_sources for all to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3)
      with check (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3);
  end if;
end $$;

do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'outreach_campaigns' and policyname = 'outreach_campaigns_write') then
    alter policy outreach_campaigns_write on acq.outreach_campaigns to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3)
  with check (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3);
  else
    create policy outreach_campaigns_write on acq.outreach_campaigns for all to authenticated
      using (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3)
      with check (org_id = (select acq.current_org_id()) and acq.role_rank((select acq.my_role())) >= 3);
  end if;
end $$;

revoke all on schema acq from public;
revoke all on all tables in schema acq from public;
revoke all on all functions in schema acq from public;
alter default privileges in schema acq revoke execute on functions from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant usage on schema acq to authenticated;
    grant select on all tables in schema acq to authenticated;
    revoke select on acq.rate_limits from authenticated;
    -- column-limited direct writes
    grant update (notes, tags, owner_id) on acq.leads to authenticated;
    grant update (status, assignee_id, due_at, notes) on acq.onboarding_tasks to authenticated;
    grant update (contact_name, email, phone, website, industry, plan, monthly_fee, business_details, receptionist_config,
                  booking_requirements, faqs, integrations, go_live_at) on acq.clients to authenticated;
    grant insert, update, delete on acq.lead_sources to authenticated;
    grant insert, update, delete on acq.outreach_campaigns to authenticated;
    grant execute on function acq.current_org_id(), acq.my_role(), acq.require_role(text), acq.role_rank(text),
                              acq.setting(uuid, text, jsonb), acq.add_member(text, text) to authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema acq to service_role;
    grant all on all tables in schema acq to service_role;
    grant execute on all functions in schema acq to service_role;
    grant usage, select on all sequences in schema acq to service_role;
  end if;
end $$;
revoke execute on function acq.create_organization(text, text, text) from public;
revoke execute on function acq.seed_org_settings(uuid) from public;

-- Make the schema reachable from the API (also set under Settings > API > Exposed schemas):
--   alter role authenticator set pgrst.db_schemas = 'public, acq';  notify pgrst, 'reload config';
