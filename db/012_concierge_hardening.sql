-- =====================================================================
-- BOOKING OS — Web Concierge hardening + sample-SMS preview + demo cleanup
-- Safe to re-run. Apply after 011_concierge.sql.
-- =====================================================================

-- Per-turn cap added to the gate (30 messages per conversation).
create or replace function bos.concierge_gate(p_business text, p_ip text, p_message text, p_first_turn boolean, p_turn int default 1)
returns jsonb language plpgsql as $$
declare
  b bos.businesses; d date := current_date; ipk text := 'ip:' || md5(coalesce(p_ip, 'unknown'));
  cap int; ipcap int; n_all int; n_ip int; cached text; q text := bos.norm_q(p_message);
begin
  select * into b from bos.businesses where slug = lower(btrim(coalesce(p_business, ''))) and active and slug like '%-demo';
  if b.id is null then return jsonb_build_object('allowed', false, 'reason', 'unknown_business',
    'reply', 'Sorry, I could not find that business.'); end if;
  if btrim(coalesce(p_message, '')) = '' then return jsonb_build_object('allowed', false, 'reason', 'empty', 'reply', 'Could you say that again?'); end if;
  if length(p_message) > 600 then return jsonb_build_object('allowed', false, 'reason', 'too_long',
    'reply', 'That message is a bit long for me. Could you shorten it?'); end if;
  if coalesce(p_turn, 1) > 30 then return jsonb_build_object('allowed', false, 'reason', 'turn_cap',
    'reply', 'This demo chat has reached its length limit. Please start a new chat, or call ' || coalesce(b.phone, 'us') || '.'); end if;

  select coalesce(value::int, 400) into cap from bos.settings where key = 'concierge_daily_cap';
  select coalesce(value::int, 40) into ipcap from bos.settings where key = 'concierge_ip_daily_cap';

  insert into bos.concierge_usage (day, scope, messages) values (d, 'all', 1)
  on conflict (day, scope) do update set messages = bos.concierge_usage.messages + 1 returning messages into n_all;
  insert into bos.concierge_usage (day, scope, messages) values (d, ipk, 1)
  on conflict (day, scope) do update set messages = bos.concierge_usage.messages + 1 returning messages into n_ip;

  if n_ip > coalesce(ipcap, 40) then return jsonb_build_object('allowed', false, 'reason', 'ip_cap',
    'reply', 'You have reached the demo limit for today. Please come back tomorrow, or call ' || coalesce(b.phone, 'us') || '.'); end if;
  if n_all > coalesce(cap, 400) then return jsonb_build_object('allowed', false, 'reason', 'daily_cap',
    'reply', 'The demo is very busy today. Please try again tomorrow, or call ' || coalesce(b.phone, 'us') || '.'); end if;

  if p_first_turn and q <> '' then
    update bos.concierge_cache set hits = hits + 1
     where business_id = b.id and q_norm = q returning answer into cached;
    if cached is not null then
      return jsonb_build_object('allowed', true, 'cached', true, 'reply', cached, 'business_id', b.id);
    end if;
  end if;

  return jsonb_build_object('allowed', true, 'cached', false, 'business_id', b.id, 'slug', b.slug,
    'system_prompt', bos.concierge_prompt(b), 'q_norm', q);
end $$;

-- Website tool calls: the visitor's IP is limited to 3 new bookings a day, and a demo business
-- never holds more than 60 open future bookings (stops bots from filling the diary).
create or replace function bos.dispatch_web(p_business text, p_tool text, p_args jsonb, p_idem text, p_ctx jsonb default '{}'::jsonb)
returns jsonb language plpgsql as $$
declare
  b bos.businesses; tool text := lower(btrim(coalesce(p_tool, ''))); n int; ipk text;
begin
  if tool in ('book', 'book_appointment') then
    select * into b from bos.businesses where (slug = lower(btrim(coalesce(p_business, ''))) or id::text = p_business) and slug like '%-demo';
    if b.id is null then return jsonb_build_object('ok', false, 'error', 'business_not_found', 'message', 'This business is not configured.'); end if;
    if (select count(*) from bos.bookings where business_id = b.id and status in ('booked','confirmed') and starts_at > now()) >= 60 then
      return jsonb_build_object('ok', false, 'error', 'demo_full', 'message', 'The demo diary is full right now. Please try again later.');
    end if;
    ipk := 'book:' || md5(coalesce(p_ctx->>'ip', 'unknown'));
    insert into bos.concierge_usage (day, scope, messages) values (current_date, ipk, 1)
    on conflict (day, scope) do update set messages = bos.concierge_usage.messages + 1 returning messages into n;
    if n > 3 then
      return jsonb_build_object('ok', false, 'error', 'demo_limit', 'message', 'The demo booking limit for today has been reached. Please call us to book.');
    end if;
  end if;
  return bos.dispatch(p_business, p_tool, p_args, p_idem, 'website', '{}'::jsonb);
end $$;

-- What the customer's confirmation text and calendar entry would look like (sample only; nothing is sent).
create or replace function bos.sms_preview(p_business uuid, p_ref text)
returns jsonb language plpgsql stable as $$
declare b bos.businesses; k bos.bookings; c bos.customers; s bos.services;
begin
  if p_business is null or coalesce(p_ref, '') = '' then return null; end if;
  select * into b from bos.businesses where id = p_business and slug like '%-demo';
  select * into k from bos.bookings where business_id = p_business and ref = upper(p_ref)
     and source = 'website' and status in ('booked','confirmed') and updated_at > now() - interval '15 minutes';
  if b.id is null or k.id is null then return null; end if;
  select * into c from bos.customers where id = k.customer_id;
  select * into s from bos.services where id = k.service_id;
  return jsonb_build_object(
    'sms', bos.render(bos.template(b, 'confirmation'), b, k, c, s),
    'calendar', jsonb_build_object('title', s.name || ' - ' || coalesce(c.name, ''), 'when', bos.fmt_when(k.starts_at, b.timezone)),
    'from', b.name);
end $$;

-- Nightly housekeeping for the demo (called by cron). Never touches non-demo businesses.
create or replace function bos.cleanup_demo()
returns jsonb language plpgsql as $$
declare nb int; nu int; nc int; ne int;
begin
  delete from bos.bookings k using bos.businesses b
   where b.id = k.business_id and b.slug like '%-demo' and (k.starts_at < now() - interval '1 day' or k.created_at < now() - interval '3 days');
  get diagnostics nb = row_count;
  delete from bos.concierge_usage where day < current_date - 14;
  get diagnostics nu = row_count;
  delete from bos.customers c using bos.businesses b
   where b.id = c.business_id and b.slug like '%-demo' and c.created_at < now() - interval '3 days'
     and not exists (select 1 from bos.bookings x where x.customer_id = c.id);
  get diagnostics nc = row_count;
  delete from bos.errors where created_at < now() - interval '30 days';
  get diagnostics ne = row_count;
  delete from bos.concierge_cache where created_at < now() - interval '30 days';
  return jsonb_build_object('bookings', nb, 'usage', nu, 'customers', nc, 'errors', ne);
end $$;

revoke all on all tables in schema bos from public;
revoke execute on all functions in schema bos from public;
