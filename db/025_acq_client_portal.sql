-- =====================================================================
-- Requires: 001_booking_os_schema.sql (schema bos) and 020-024. Production already has both.
-- ACQ 025 — Client portal ("Front desk" dashboard)
-- Read-only views of a client's booking business (schema bos) for:
--   (a) members of the SimplyBooked organisation that owns the client (acq.profiles), and
--   (b) the client's own people (acq.client_users), who see only their business.
-- bos stays unexposed: every read goes through these SECURITY DEFINER functions, which resolve
-- the caller from auth.uid() and refuse anything they are not entitled to see.
-- Safe to re-run. No destructive statements.
-- =====================================================================

create table if not exists acq.client_users (
  client_id  uuid not null references acq.clients(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  org_id     uuid not null references acq.organizations(id) on delete cascade,
  email      text,
  role       text not null default 'owner' check (role in ('owner', 'staff')),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  primary key (client_id, user_id)
);
create index if not exists client_users_user on acq.client_users (user_id) where active;
alter table acq.client_users enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'acq' and tablename = 'client_users' and policyname = 'client_users_select') then
    create policy client_users_select on acq.client_users for select to authenticated
      using (user_id = (select auth.uid()) or org_id = (select acq.current_org_id()));
  end if;
end $$;

-- "from £55", "£40", "45.50", "free" -> number (0 when there is no price)
create or replace function acq.price_value(p text)
returns numeric language sql immutable set search_path = '' as $$
  select coalesce((regexp_match(replace(coalesce(p, ''), ',', ''), '([0-9]+(\.[0-9]{1,2})?)'))[1]::numeric, 0)
$$;

-- booking source -> the channel shown to owners
create or replace function acq.portal_channel(p_source text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_source = 'voice' then 'phone'
    when p_source in ('web_voice', 'website') then 'web'
    when p_source = 'sms' then 'text'
    else 'team' end
$$;

-- customer label without exposing more than needed: "Emma T." or "•••• 0111"
create or replace function acq.portal_customer(p_name text, p_phone text)
returns text language sql immutable set search_path = '' as $$
  select case
    when nullif(btrim(coalesce(p_name, '')), '') is null then '•••• ' || right(coalesce(p_phone, ''), 4)
    when position(' ' in btrim(p_name)) = 0 then btrim(p_name)
    else split_part(btrim(p_name), ' ', 1) || ' ' || left(split_part(btrim(p_name), ' ', array_length(regexp_split_to_array(btrim(p_name), '\s+'), 1)), 1) || '.'
  end
$$;

-- Which bos business may the caller open for this client? Raises 42501 when not allowed.
create or replace function acq.portal_business(p_client uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare c acq.clients; uid uuid := auth.uid(); allowed boolean := false;
begin
  if uid is null then raise exception using errcode = '42501', message = 'forbidden', detail = 'Sign in first.'; end if;
  select * into c from acq.clients where id = p_client;
  if c.id is not null then
    -- coalesce: a NULL organisation (client users have none) must mean "no", never "unknown"
    allowed := coalesce(c.org_id = acq.current_org_id(), false)
               or exists (select 1 from acq.client_users u where u.client_id = c.id and u.user_id = uid and u.active);
  end if;
  if not allowed then
    raise exception using errcode = '42501', message = 'forbidden', detail = 'You don''t have access to this business.';
  end if;
  if c.bos_business_id is null then
    perform acq.fail('not_provisioned', 'This business''s booking system isn''t set up yet.');
  end if;
  return c.bos_business_id;
end $$;

-- Businesses the caller can open (organisation members: every provisioned client; client users: their own).
create or replace function acq.portal_clients()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'clients', coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'business_name', c.business_name, 'industry', c.industry, 'status', c.status,
           'role', case when c.org_id = acq.current_org_id() then 'organisation' else u.role end)
           order by c.business_name), '[]'::jsonb))
  from acq.clients c
  left join acq.client_users u on u.client_id = c.id and u.user_id = auth.uid() and u.active
  where c.bos_business_id is not null
    and auth.uid() is not null
    and (c.org_id = acq.current_org_id() or u.user_id is not null)
$$;

create or replace function acq.portal_overview(p_client uuid, p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  bid uuid := acq.portal_business(p_client);
  b bos.businesses; days int := least(greatest(coalesce(p_days, 30), 7), 365);
  tz text; today date; since timestamptz; prev timestamptz;
  kp jsonb; daily jsonb; monthly jsonb;
begin
  select * into b from bos.businesses where id = bid;
  tz := b.timezone; today := (now() at time zone tz)::date;
  since := ((today - days + 1)::timestamp) at time zone tz;
  prev := ((today - 2 * days + 1)::timestamp) at time zone tz;

  select jsonb_build_object(
      'bookings',      count(*) filter (where k.created_at >= since and k.status <> 'cancelled'),
      'bookings_prev', count(*) filter (where k.created_at >= prev and k.created_at < since and k.status <> 'cancelled'),
      'by_ai',         count(*) filter (where k.created_at >= since and k.status <> 'cancelled' and k.source in ('voice', 'web_voice', 'sms')),
      'revenue',       coalesce(sum(acq.price_value(s.price_text)) filter (where k.starts_at >= since and k.starts_at < now() and k.status in ('booked', 'confirmed', 'completed')), 0),
      'revenue_prev',  coalesce(sum(acq.price_value(s.price_text)) filter (where k.starts_at >= prev and k.starts_at < since and k.status in ('booked', 'confirmed', 'completed')), 0),
      'upcoming',      count(*) filter (where k.starts_at >= now() and k.status in ('booked', 'confirmed')),
      'confirmed_rate', case when count(*) filter (where k.starts_at >= now() and k.status in ('booked', 'confirmed')) = 0 then null
                         else round(100.0 * count(*) filter (where k.starts_at >= now() and k.status = 'confirmed')
                                    / count(*) filter (where k.starts_at >= now() and k.status in ('booked', 'confirmed')), 1) end,
      'no_shows',      count(*) filter (where k.starts_at >= since and k.status = 'no_show'))
    into kp
  from bos.bookings k join bos.services s on s.id = k.service_id
  where k.business_id = bid and (k.created_at >= prev or k.starts_at >= prev);

  kp := kp || jsonb_build_object(
    'calls', (select count(*) from bos.calls c where c.business_id = bid and coalesce(c.started_at, c.created_at) >= since),
    'calls_prev', (select count(*) from bos.calls c where c.business_id = bid and coalesce(c.started_at, c.created_at) >= prev and coalesce(c.started_at, c.created_at) < since));

  select coalesce(jsonb_agg(jsonb_build_object('date', to_char(d, 'YYYY-MM-DD'), 'bookings', coalesce(x.n, 0), 'revenue', coalesce(x.rev, 0)) order by d), '[]'::jsonb)
    into daily
  from generate_series(today - days + 1, today, interval '1 day') d
  left join (
    select (k.created_at at time zone tz)::date as day, count(*) n, sum(acq.price_value(s.price_text)) rev
    from bos.bookings k join bos.services s on s.id = k.service_id
    where k.business_id = bid and k.created_at >= since and k.status <> 'cancelled'
    group by 1) x on x.day = d::date;

  select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'),
           'phone', coalesce(x.phone, 0), 'web', coalesce(x.web, 0), 'text', coalesce(x.text, 0), 'team', coalesce(x.team, 0)) order by m), '[]'::jsonb)
    into monthly
  from generate_series(date_trunc('month', today::timestamp) - interval '5 months', date_trunc('month', today::timestamp), interval '1 month') m
  left join (
    select date_trunc('month', k.starts_at at time zone tz) as mon,
           sum(acq.price_value(s.price_text)) filter (where acq.portal_channel(k.source) = 'phone') phone,
           sum(acq.price_value(s.price_text)) filter (where acq.portal_channel(k.source) = 'web') web,
           sum(acq.price_value(s.price_text)) filter (where acq.portal_channel(k.source) = 'text') text,
           sum(acq.price_value(s.price_text)) filter (where acq.portal_channel(k.source) = 'team') team
    from bos.bookings k join bos.services s on s.id = k.service_id
    where k.business_id = bid and k.status in ('booked', 'confirmed', 'completed')
      and k.starts_at >= ((date_trunc('month', today::timestamp) - interval '5 months') at time zone tz)
      and k.starts_at < now()
    group by 1) x on x.mon = m;

  return jsonb_build_object('ok', true, 'days', days, 'today', to_char(today, 'YYYY-MM-DD'),
    'business', jsonb_build_object('name', b.name, 'industry', b.industry, 'timezone', tz, 'receptionist_name', b.receptionist_name, 'test_mode', b.test_mode),
    'kpis', kp, 'daily', daily, 'monthly', monthly);
end $$;

-- One day's diary: staff columns, opening hours and every booking on that day.
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
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'kind', r.kind) order by r.sort_order, r.name), '[]'::jsonb)
              from bos.resources r where r.business_id = bid and r.active),
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
  b bos.businesses; d date; t0 timestamptz; t1 timestamptz;
begin
  select * into b from bos.businesses where id = bid;
  d := coalesce(p_from, (now() at time zone b.timezone)::date);
  t0 := greatest((d::timestamp) at time zone b.timezone, now() - interval '30 minutes');
  t1 := ((d + least(greatest(coalesce(p_days, 7), 1), 31))::timestamp) at time zone b.timezone;
  return jsonb_build_object('ok', true, 'from', to_char(d, 'YYYY-MM-DD'), 'timezone', b.timezone,
    'bookings', (select coalesce(jsonb_agg(x.j order by x.starts_at), '[]'::jsonb) from (
       select k.starts_at, jsonb_build_object('id', k.id, 'ref', k.ref, 'starts_at', k.starts_at, 'ends_at', k.ends_at,
                'service', s.name, 'staff', r.name, 'customer', acq.portal_customer(c.name, c.phone), 'status', k.status,
                'channel', acq.portal_channel(k.source), 'price', acq.price_value(s.price_text)) j
       from bos.bookings k join bos.services s on s.id = k.service_id join bos.customers c on c.id = k.customer_id
       join bos.resources r on r.id = k.resource_id
       where k.business_id = bid and k.starts_at >= t0 and k.starts_at < t1 and k.status in ('booked', 'confirmed')
       order by k.starts_at limit 200) x));
end $$;

-- What the AI receptionist handled: recent calls and inbound texts.
create or replace function acq.portal_activity(p_client uuid, p_limit int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare bid uuid := acq.portal_business(p_client); lim int := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  return jsonb_build_object('ok', true,
    'calls', (select coalesce(jsonb_agg(x.j order by x.t desc), '[]'::jsonb) from (
       select coalesce(c.started_at, c.created_at) t, jsonb_build_object('id', c.id, 'started_at', coalesce(c.started_at, c.created_at),
                'duration_s', c.duration_s, 'channel', case when c.call_type ilike '%web%' then 'web' else 'phone' end,
                'customer', acq.portal_customer(cu.name, coalesce(cu.phone, c.customer_phone)), 'summary', left(c.summary, 600),
                'ended_reason', c.ended_reason) j
       from bos.calls c left join bos.customers cu on cu.id = c.customer_id
       where c.business_id = bid order by coalesce(c.started_at, c.created_at) desc limit lim) x),
    'texts', (select coalesce(jsonb_agg(x.j order by x.t desc), '[]'::jsonb) from (
       select m.created_at t, jsonb_build_object('id', m.id, 'at', m.created_at, 'direction', m.direction, 'purpose', m.purpose,
                'customer', acq.portal_customer(cu.name, coalesce(cu.phone, case when m.direction = 'in' then m.from_addr else m.to_addr end)),
                'body', left(m.body, 400)) j
       from bos.messages m left join bos.customers cu on cu.id = m.customer_id
       where m.business_id = bid order by m.created_at desc limit lim) x));
end $$;

-- Give a client's owner or staff their own sign-in to the Front desk (organisation admins only).
create or replace function acq.add_client_user(p_client uuid, p_email text, p_role text default 'owner')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('admin'); c acq.clients; u record;
begin
  if p_role not in ('owner', 'staff') then perform acq.fail('invalid_role', 'Role must be owner or staff.'); end if;
  select * into c from acq.clients where id = p_client and org_id = o;
  if c.id is null then perform acq.fail('client_not_found', 'Client not found.'); end if;
  select id, email into u from auth.users where lower(email) = lower(btrim(coalesce(p_email, '')));
  if u.id is null then perform acq.fail('user_not_found', 'Create the user in Supabase Authentication first, then add them here.'); end if;
  insert into acq.client_users (client_id, user_id, org_id, email, role, active, created_by)
  values (c.id, u.id, o, u.email, p_role, true, auth.uid())
  on conflict (client_id, user_id) do update set active = true, role = excluded.role, email = excluded.email;
  perform acq.activity(o, 'client.user_added', 'clients', c.id::text, c.lead_id, jsonb_build_object('email', u.email, 'role', p_role));
  return jsonb_build_object('ok', true, 'client_id', c.id, 'email', u.email, 'role', p_role);
end $$;

create or replace function acq.set_client_user_active(p_client uuid, p_email text, p_active boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o uuid := acq.require_role('admin'); n int;
begin
  update acq.client_users set active = coalesce(p_active, false)
  where client_id = p_client and org_id = o and lower(email) = lower(btrim(coalesce(p_email, '')));
  get diagnostics n = row_count;
  if n = 0 then perform acq.fail('not_found', 'No such person on this client.'); end if;
  return jsonb_build_object('ok', true, 'active', coalesce(p_active, false));
end $$;

-- ---------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------
revoke execute on function acq.price_value(text), acq.portal_channel(text), acq.portal_customer(text, text),
  acq.portal_business(uuid), acq.portal_clients(), acq.portal_overview(uuid, int), acq.portal_day(uuid, date),
  acq.portal_upcoming(uuid, date, int), acq.portal_activity(uuid, int), acq.add_client_user(uuid, text, text),
  acq.set_client_user_active(uuid, text, boolean) from public;
do $$
begin
  -- undo any default privileges Supabase applies to new objects in exposed schemas
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on acq.client_users from anon;
    revoke execute on function acq.price_value(text), acq.portal_channel(text), acq.portal_customer(text, text),
      acq.portal_business(uuid), acq.portal_clients(), acq.portal_overview(uuid, int), acq.portal_day(uuid, date),
      acq.portal_upcoming(uuid, date, int), acq.portal_activity(uuid, int), acq.add_client_user(uuid, text, text),
      acq.set_client_user_active(uuid, text, boolean) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke insert, update, delete, truncate, references, trigger on acq.client_users from authenticated;
    revoke execute on function acq.price_value(text), acq.portal_channel(text), acq.portal_customer(text, text),
      acq.portal_business(uuid) from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select on acq.client_users to authenticated;
    grant execute on function acq.portal_clients(), acq.portal_overview(uuid, int), acq.portal_day(uuid, date),
      acq.portal_upcoming(uuid, date, int), acq.portal_activity(uuid, int), acq.add_client_user(uuid, text, text),
      acq.set_client_user_active(uuid, text, boolean) to authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant all on acq.client_users to service_role;
    grant execute on all functions in schema acq to service_role;
  end if;
end $$;
