-- =====================================================================
-- BOOKING OS — onboard a new client business (copy, fill in, run once)
-- Works for any appointment business: clinic, salon, spa, gym, garage, tutor, consultant...
-- =====================================================================
begin;

with biz as (
  insert into bos.businesses (slug, name, industry, timezone, country_code, phone, sms_from, address, website,
                              review_url, calendar_id, receptionist_name, ai_notes,
                              slot_interval_min, min_notice_min, max_days_ahead, reminder_offsets_min,
                              followup_delay_min, review_delay_min, test_mode, test_numbers)
  values ('client-slug',                       -- lowercase-with-dashes; used in the Vapi tool URL
          'Client Business Name', 'industry, e.g. physiotherapy clinic',
          'Europe/London', '44',
          '+44XXXXXXXXXX',                     -- public phone number
          '+44XXXXXXXXXX',                     -- Twilio number this business texts from (E.164)
          'Full address', 'https://client-site.com',
          'https://g.page/r/XXXX/review',      -- Google review link (NULL = no review requests)
          'xxxx@group.calendar.google.com',    -- Google Calendar ID shared with the n8n Google account (NULL = no sync)
          'Sophie',
          'Parking, payment methods, cancellation policy, anything the AI may tell customers.',
          15, 60, 60, '{1440,120}',             -- slot grid (min), minimum notice (min), days ahead, reminders (min before)
          120, 1440,                            -- follow-up / review delay after the appointment (min). NULL disables.
          true, '{+44YOUR_TEST_MOBILE}')        -- keep test_mode ON until the end-to-end test passes
  returning id
),
hrs as (
  insert into bos.business_hours (business_id, weekday, opens, closes)
  select biz.id, h.weekday, h.opens, h.closes from biz,
  (values (1,'09:00'::time,'17:00'::time), (2,'09:00','17:00'), (3,'09:00','17:00'),
          (4,'09:00','17:00'), (5,'09:00','17:00')) as h(weekday, opens, closes)   -- 0=Sun ... 6=Sat
  returning 1
),
res as (
  insert into bos.resources (business_id, name, kind, sort_order)
  select biz.id, r.name, r.kind, r.ord from biz,
  (values ('Staff member 1', 'staff', 1), ('Staff member 2', 'staff', 2)) as r(name, kind, ord)
  returning id
)
insert into bos.services (business_id, name, description, duration_min, buffer_min, price_text)
select biz.id, s.name, s.descr, s.dur, s.buf, s.price from biz,
(values ('Service A', 'Short description', 30, 0, 'from £50'),
        ('Service B', 'Short description', 60, 10, '£90')) as s(name, descr, dur, buf, price);

-- Optional: limit a service to specific staff (otherwise any active resource can take it)
-- insert into bos.service_resources (service_id, resource_id)
-- select s.id, r.id from bos.services s, bos.resources r
-- where s.name = 'Service B' and r.name = 'Staff member 1' and s.business_id = r.business_id;

commit;

-- After the Vapi assistant exists:
-- update bos.businesses set vapi_assistant_id = 'asst_xxx' where slug = 'client-slug';
-- Go live (only after the end-to-end test):
-- update bos.businesses set test_mode = false where slug = 'client-slug';
