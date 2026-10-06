-- =====================================================================
-- ACQ 026 — Front desk hardening (after review of 025)
--   * client users lose access when the client is paused/churned or the organisation is suspended
--   * client_users.org_id must be the client's own organisation (composite foreign key)
--   * one booking business can belong to one client only
--   * the diary keeps bookings of staff who were later deactivated
--   * phone numbers and email addresses are masked inside call summaries and texts
--   * the upcoming list is not cut short on busy weeks; portal_clients returns each business's time zone
-- Requires 025. Safe to re-run. No destructive statements.
-- =====================================================================

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'client_users_client_org_fk') then
    alter table acq.client_users add constraint client_users_client_org_fk
      foreign key (client_id, org_id) references acq.clients (id, org_id) on delete cascade;
  end if;
end $$;
create unique index if not exists clients_one_per_bos_business on acq.clients (bos_business_id) where bos_business_id is not null;

-- Masks phone numbers and email addresses in free text written by callers, texters or the AI.
create or replace function acq.portal_redact(p text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(
           regexp_replace(coalesce(p, ''), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]', 'g'),
           '\+?[0-9](?:[ ()-]{0,2}[0-9]){8,}', '[phone]', 'g')
$$;

create or replace function acq.portal_business(p_client uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare c acq.clients; uid uuid := auth.uid(); allowed boolean := false;
begin
  if uid is null then raise exception using errcode = '42501', message = 'forbidden', detail = 'Sign in first.'; end if;
  select * into c from acq.clients where id = p_client;
  if c.id is not null then
    -- coalesce: a NULL organisation (client users have none) must mean "no", never "unknown"
    allowed := coalesce(c.org_id = acq.current_org_id(), false)
               or (c.status in ('onboarding', 'active')
                   and exists (select 1 from acq.organizations o where o.id = c.org_id and o.status = 'active')
                   and exists (select 1 from acq.client_users u where u.client_id = c.id and u.user_id = uid and u.active));
  end if;
  if not allowed then
    raise exception using errcode = '42501', message = 'forbidden', detail = 'You don''t have access to this business.';
  end if;
  if c.bos_business_id is null then
    perform acq.fail('not_provisioned', 'This business''s booking system isn''t set up yet.');
  end if;
  return c.bos_business_id;
end $$;

create or replace function acq.portal_clients()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'clients', coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'business_name', c.business_name, 'industry', c.industry, 'status', c.status, 'timezone', b.timezone,
           'role', case when coalesce(c.org_id = acq.current_org_id(), false) then 'organisation' else u.role end)
           order by c.business_name), '[]'::jsonb))
  from acq.clients c
  join bos.businesses b on b.id = c.bos_business_id
  left join acq.client_users u on u.client_id = c.id and u.user_id = auth.uid() and u.active
  where auth.uid() is not null
    and (coalesce(c.org_id = acq.current_org_id(), false)
         or (u.user_id is not null and c.status in ('onboarding', 'active')
             and exists (select 1 from acq.organizations o where o.id = c.org_id and o.status = 'active')))
$$;

create or replace function acq.portal_day(p_client uuid, p_date date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  bid uuid := acq.portal_business(p_client);
  b bos.businesses; d date; t0 timestamptz; t1 timestamptz; opens time; closes time;
begin
  select * into b from bos.businesses where id = bid;
  d := coalesce(p_date, (now() at time zone b.timezone)::date);
  t0 := (d::timestamp) at time zone b.timezone;
  t1 := ((d + 1)::timestamp) at time zone b.timezone;
  select min(h.opens), max(h.closes) into opens, closes from bos.business_hours h
  where h.business_id = bid and h.weekday = extract(dow from d);
  return jsonb_build_object('ok', true, 'date', to_char(d, 'YYYY-MM-DD'), 'timezone', b.timezone,
    'closed', opens is null,
    'opens', to_char(coalesce(opens, '09:00'::time), 'HH24:MI'), 'closes', to_char(coalesce(closes, '17:00'::time), 'HH24:MI'),
    -- active staff, plus anyone (even if since deactivated) who has a booking that day
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'kind', r.kind) order by r.sort_order, r.name), '[]'::jsonb)
              from bos.resources r where r.business_id = bid
                and (r.active or exists (select 1 from bos.bookings k where k.resource_id = r.id and k.starts_at >= t0 and k.starts_at < t1 and k.status <> 'cancelled'))),
    'bookings', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', k.id, 'ref', k.ref, 'staff_id', k.resource_id, 'starts_at', k.starts_at, 'ends_at', k.ends_at,
                   'service', s.name, 'customer', acq.portal_customer(c.name, c.phone), 'status', k.status,
                   'channel', acq.portal_channel(k.source), 'price', acq.price_value(s.price_text)) order by k.starts_at), '[]'::jsonb)
                 from bos.bookings k join bos.services s on s.id = k.service_id join bos.customers c on c.id = k.customer_id
                 where k.business_id = bid and k.starts_at >= t0 and k.starts_at < t1 and k.status <> 'cancelled'));
end $$;

create or replace function acq.portal_upcoming(p_client uuid, p_from date default null, p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  bid uuid := acq.portal_business(p_client);
  b bos.businesses; d date; t0 timestamptz; t1 timestamptz; n int; cap int := 2000;
begin
  select * into b from bos.businesses where id = bid;
  d := coalesce(p_from, (now() at time zone b.timezone)::date);
  t0 := greatest((d::timestamp) at time zone b.timezone, now() - interval '30 minutes');
  t1 := ((d + least(greatest(coalesce(p_days, 7), 1), 31))::timestamp) at time zone b.timezone;
  select count(*) into n from bos.bookings k
  where k.business_id = bid and k.starts_at >= t0 and k.starts_at < t1 and k.status in ('booked', 'confirmed');
  return jsonb_build_object('ok', true, 'from', to_char(d, 'YYYY-MM-DD'), 'timezone', b.timezone, 'truncated', n > cap,
    'bookings', (select coalesce(jsonb_agg(x.j order by x.starts_at), '[]'::jsonb) from (
       select k.starts_at, jsonb_build_object('id', k.id, 'ref', k.ref, 'starts_at', k.starts_at, 'ends_at', k.ends_at,
                'service', s.name, 'staff', r.name, 'customer', acq.portal_customer(c.name, c.phone), 'status', k.status,
                'channel', acq.portal_channel(k.source), 'price', acq.price_value(s.price_text)) j
       from bos.bookings k join bos.services s on s.id = k.service_id join bos.customers c on c.id = k.customer_id
       join bos.resources r on r.id = k.resource_id
       where k.business_id = bid and k.starts_at >= t0 and k.starts_at < t1 and k.status in ('booked', 'confirmed')
       order by k.starts_at limit cap) x));
end $$;

create or replace function acq.portal_activity(p_client uuid, p_limit int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare bid uuid := acq.portal_business(p_client); lim int := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  return jsonb_build_object('ok', true,
    'calls', (select coalesce(jsonb_agg(x.j order by x.t desc), '[]'::jsonb) from (
       select coalesce(c.started_at, c.created_at) t, jsonb_build_object('id', c.id, 'started_at', coalesce(c.started_at, c.created_at),
                'duration_s', c.duration_s, 'channel', case when c.call_type ilike '%web%' then 'web' else 'phone' end,
                'customer', acq.portal_customer(cu.name, coalesce(cu.phone, c.customer_phone)),
                'summary', nullif(acq.portal_redact(left(c.summary, 600)), ''),
                'ended_reason', c.ended_reason) j
       from bos.calls c left join bos.customers cu on cu.id = c.customer_id
       where c.business_id = bid order by coalesce(c.started_at, c.created_at) desc limit lim) x),
    'texts', (select coalesce(jsonb_agg(x.j order by x.t desc), '[]'::jsonb) from (
       select m.created_at t, jsonb_build_object('id', m.id, 'at', m.created_at, 'direction', m.direction, 'purpose', m.purpose,
                'customer', acq.portal_customer(cu.name, coalesce(cu.phone, case when m.direction = 'in' then m.from_addr else m.to_addr end)),
                'body', acq.portal_redact(left(m.body, 400))) j
       from bos.messages m left join bos.customers cu on cu.id = m.customer_id
       where m.business_id = bid order by m.created_at desc limit lim) x));
end $$;

revoke execute on function acq.portal_redact(text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function acq.portal_redact(text), acq.portal_business(uuid), acq.portal_clients(), acq.portal_day(uuid, date),
      acq.portal_upcoming(uuid, date, int), acq.portal_activity(uuid, int) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke execute on function acq.portal_redact(text), acq.portal_business(uuid) from authenticated;
    grant execute on function acq.portal_clients(), acq.portal_day(uuid, date), acq.portal_upcoming(uuid, date, int),
      acq.portal_activity(uuid, int) to authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function acq.portal_redact(text) to service_role;
  end if;
end $$;
