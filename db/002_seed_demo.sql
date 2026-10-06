-- =====================================================================
-- BOOKING OS — demo data: one dental clinic + one hair salon
-- Proves the same engine serves different industries.
-- Replace phone numbers / calendar IDs / Twilio numbers before going live.
-- =====================================================================

-- Twilio Account SID is not a secret (the Auth Token lives only in the n8n credential).
insert into bos.settings (key, value) values ('twilio_account_sid', 'ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')
on conflict (key) do nothing;

insert into bos.businesses (id, slug, name, industry, timezone, country_code, phone, sms_from, address, website,
                            review_url, calendar_id, receptionist_name, ai_notes, slot_interval_min,
                            reminder_offsets_min, test_mode, test_numbers)
values
('11111111-1111-4111-8111-111111111111', 'brightsmile-demo', 'BrightSmile Dental', 'dental clinic',
 'Europe/London', '44', '+442079460000', '+447700900001', '12 High Street, London',
 'https://dentalzample.netlify.app', 'https://g.page/r/brightsmile-demo/review', null, 'Sophie',
 'New patients welcome. Free parking behind the building. Emergency appointments same day when available. We accept card payments only.',
 15, '{1440,120}', true, '{}'),
('22222222-2222-4222-8222-222222222222', 'luxe-hair-demo', 'Luxe Hair Studio', 'hair salon',
 'Europe/London', '44', '+442079460001', '+447700900002', '5 Market Lane, Manchester',
 null, null, null, 'Mia',
 'Please arrive 5 minutes early. Colour services need a patch test 48 hours before.',
 30, '{1440}', true, '{}')
on conflict (id) do nothing;

-- Hours: dental Mon-Fri 09-17 (lunch 13-14); salon Tue-Sat 10-18
insert into bos.business_hours (business_id, weekday, opens, closes)
select '11111111-1111-4111-8111-111111111111', d, t.o, t.c
from generate_series(1, 5) d, (values ('09:00'::time, '13:00'::time), ('14:00', '17:00')) t(o, c)
on conflict do nothing;
insert into bos.business_hours (business_id, weekday, opens, closes)
select '22222222-2222-4222-8222-222222222222', d, '10:00', '18:00' from generate_series(2, 6) d
on conflict do nothing;

insert into bos.resources (id, business_id, name, kind, sort_order) values
('a1111111-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', 'Dr Patel', 'dentist', 1),
('a2222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'Sam (Hygienist)', 'hygienist', 2),
('b1111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', 'Chair 1', 'chair', 1)
on conflict (id) do nothing;

insert into bos.services (id, business_id, name, description, duration_min, buffer_min, price_text) values
('c1111111-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', 'Dental Check-up', 'Routine exam', 30, 0, 'from £55'),
('c2222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'Hygiene Appointment', 'Scale and polish', 45, 15, 'from £75'),
('c3333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', 'Consultation', 'New patient or cosmetic consult', 30, 0, 'free'),
('c4444444-4444-4444-8444-444444444444', '11111111-1111-4111-8111-111111111111', 'Emergency Appointment', 'Pain or urgent problem', 30, 0, 'from £80'),
('d1111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', 'Haircut', 'Wash, cut and style', 45, 0, '£40'),
('d2222222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', 'Full Colour', 'Includes toner', 120, 15, 'from £95')
on conflict (id) do nothing;

-- Dentist does check-ups, consults and emergencies; hygienist does hygiene only.
insert into bos.service_resources (service_id, resource_id) values
('c1111111-1111-4111-8111-111111111111', 'a1111111-1111-4111-8111-111111111111'),
('c3333333-3333-4333-8333-333333333333', 'a1111111-1111-4111-8111-111111111111'),
('c4444444-4444-4444-8444-444444444444', 'a1111111-1111-4111-8111-111111111111'),
('c2222222-2222-4222-8222-222222222222', 'a2222222-2222-4222-8222-222222222222')
on conflict do nothing;
