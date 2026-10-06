// Sample data for the demo dashboard (?demo=1). Every business and person here is fictional.
// Shapes match the live acq views and dashboard_metrics() exactly, so the same screens render both.

const H = 3600e3, D = 24 * H;
const at = (ms) => new Date(Date.now() + ms).toISOString();
// Demo appointments are set in UK time, whatever the viewer's own time zone is.
const TZ = 'Europe/London';
const partsIn = (date) => Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: TZ, year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', hourCycle: 'h23' })
  .formatToParts(date).filter((p) => p.type !== 'literal').map((p) => [p.type, Number(p.value)]));
function dayAt(days, hh, mm = 0) {
  const today = partsIn(new Date(Date.now() + days * D));
  let guess = Date.UTC(today.year, today.month - 1, today.day, hh, mm);
  for (let i = 0; i < 2; i++) { // correct for the UK offset (GMT or BST) at that moment
    const p = partsIn(new Date(guess));
    guess -= (Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute) - Date.UTC(today.year, today.month - 1, today.day, hh, mm));
  }
  return new Date(guess).toISOString();
}
let n = 0;
const id = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;

const lead = (business_name, niche, city, status, score, extra = {}) => ({
  id: id(), business_name, niche, city, status, score, country_code: 'GB',
  website: `https://${business_name.toLowerCase().replace(/[^a-z0-9]+/g, '')}.co.uk`,
  email: `hello@${business_name.toLowerCase().replace(/[^a-z0-9]+/g, '')}.co.uk`,
  phone: '+44 20 7946 0' + String(100 + n).slice(-3), rating: 4.3 + ((n * 7) % 7) / 10, review_count: 40 + ((n * 37) % 260),
  do_not_contact: false, created_at: at(-((n % 20) + 2) * D), updated_at: at(-((n % 5) + 1) * H),
  fit: score >= 75 ? 'strong' : score >= 55 ? 'possible' : 'weak', is_fit: score >= 55,
  reasons: ['Books by phone only', 'Busy weekday trade', 'Strong local reviews'].slice(0, 2 + (n % 2)),
  pain_points: ['Calls go to voicemail during appointments', 'No online booking'].slice(0, 1 + (n % 2)),
  website_quality: n % 3 ? 'basic' : 'good', has_online_booking: n % 4 ? 'no' : 'partial',
  recommended_offer: 'AI receptionist with text confirmations and reminders',
  qualification_summary: `${business_name} takes bookings by phone and misses calls while the team is with customers. A good fit for an AI receptionist that books straight into their diary.`,
  ...extra,
});

export const leads = [
  lead('Fade Theory Barbers', 'barbers', 'Manchester', 'new_lead', 82),
  lead('The Copper Comb', 'barbers', 'Leeds', 'new_lead', 64),
  lead('Willow Lane Physio', 'physiotherapy', 'Bristol', 'new_lead', 71),
  lead('Northgate Motors', 'garages', 'Sheffield', 'qualified', 77),
  lead('Bloom & Blush Studio', 'beauty salons', 'Brighton', 'qualified', 88),
  lead('Harbour Dental Care', 'dental clinics', 'Plymouth', 'qualified', 91),
  lead('Lumen Opticians', 'opticians', 'York', 'approved', 79),
  lead('Kingsway Auto Care', 'garages', 'Birmingham', 'approved', 73),
  lead('Silk Thread Tailoring', 'tailors', 'Edinburgh', 'contacted', 68),
  lead('Studio Nine Hair', 'hair salons', 'London', 'contacted', 86),
  lead('Parkside Podiatry', 'podiatry', 'Nottingham', 'contacted', 74),
  lead('The Groom Room', 'barbers', 'Cardiff', 'replied', 84, { last_reply_at: at(-3 * H) }),
  lead('Maple Tree Dental', 'dental clinics', 'Reading', 'replied', 92, { last_reply_at: at(-26 * H) }),
  lead('Glow Aesthetics', 'aesthetics clinics', 'Liverpool', 'demo_sent', 87),
  lead('Crown Street Barbers', 'barbers', 'Glasgow', 'demo_sent', 80),
  lead('Oak & Iron Tattoo', 'tattoo studios', 'Bristol', 'meeting_booked', 76),
  lead('Riverside Vets', 'veterinary practices', 'Norwich', 'meeting_booked', 90),
  lead('Bramble Bakery', 'bakeries', 'Bath', 'won', 83),
  lead('Clearview Eyecare', 'opticians', 'Oxford', 'won', 89),
  lead('Atlas Fitness Studio', 'personal trainers', 'Leicester', 'won', 78),
  lead('Velvet Nail Lounge', 'nail salons', 'Coventry', 'lost', 58, { lost_reason: 'Already signed with another provider' }),
];

const L = (name) => leads.find((l) => l.business_name === name);

export const outreach = [
  { lead: 'Lumen Opticians', step: 1, subject: 'Missed calls at Lumen Opticians', body: 'Hi Priya,\n\nI noticed Lumen Opticians takes eye-test bookings by phone, and your reviews mention how hard it can be to get through on a Saturday.\n\nSimplyBooked answers every call in your practice\'s name, books straight into your diary and texts the customer a confirmation, so nobody waits on hold while you\'re mid-fitting.\n\nWould a 15-minute look be useful next week?\n\nBest,\nJay' },
  { lead: 'Kingsway Auto Care', step: 1, subject: 'An idea for Kingsway\'s MOT bookings', body: 'Hi Dan,\n\nMOT season is busy and every missed call is a booking that goes to the garage down the road.\n\nSimplyBooked picks up when you\'re under a bonnet, checks your real availability and books the slot, with a reminder text the day before.\n\nHappy to show you how it would sound for Kingsway.\n\nThanks,\nJay' },
  { lead: 'Northgate Motors', step: 1, subject: 'Answering Northgate\'s phones while you work', body: 'Hi there,\n\nYour Google reviews are excellent, and a few mention it being hard to get through by phone.\n\nSimplyBooked answers every call, books the work into your calendar and confirms by text. Could I send you a two-minute demo?\n\nBest,\nJay' },
  { lead: 'Silk Thread Tailoring', step: 2, subject: 'Re: fittings at Silk Thread', body: 'Hi Morag,\n\nJust following up on my note last week. Fittings by appointment are exactly where an always-on receptionist helps most: no more voicemail tag.\n\nIf it would help, I can set up a demo that answers as Silk Thread.\n\nBest,\nJay' },
].map((m) => {
  const l = L(m.lead);
  return { id: id(), lead_id: l.id, business_name: l.business_name, niche: l.niche, city: l.city, score: l.score, lead_status: l.status,
    kind: m.step > 1 ? 'followup' : 'outreach', channel: 'email', step: m.step, to_address: l.email, subject: m.subject, body: m.body,
    status: 'pending_approval', approval_status: 'pending', generated_by: 'ai', created_at: at(-(2 + m.step) * H) };
});

export const replies = [
  { id: id(), lead: 'The Groom Room', classification: 'positive', confidence: 0.94, received_at: at(-3 * H), from: 'owner@thegroomroom.co.uk',
    subject: 'Re: Missed calls at The Groom Room',
    body: 'Hi Jay, funny timing — we lost three bookings on Saturday because nobody could get to the phone. How quickly could this be set up? And does it work with the calendar we already use?',
    summary: 'Interested. Lost bookings last Saturday, asks about setup time and calendar compatibility.',
    suggested: 'Hi Rhys,\n\nSorry to hear about Saturday — that\'s exactly what SimplyBooked is for. It writes every booking straight into Google Calendar, and most shops are answering calls within a few days.\n\nI\'ve set up a short demo that answers as The Groom Room. Would Thursday at 11am or Friday at 2pm suit for a quick call?\n\nBest,\nJay', response_status: 'pending_approval' },
  { id: id(), lead: 'Maple Tree Dental', classification: 'question', confidence: 0.88, received_at: at(-26 * H), from: 'practice@mapletreedental.co.uk',
    subject: 'Re: An idea for Maple Tree Dental',
    body: 'Thanks for getting in touch. Can it handle emergency appointments differently from check-ups? We keep a few same-day slots free.',
    summary: 'Asks whether emergency appointments can be handled separately from routine check-ups.',
    suggested: 'Hi Helen,\n\nYes — emergency appointments can be their own service with their own slots, so check-ups never take them. Sophie offers same-day emergency times first when a caller is in pain.\n\nHappy to show you on a short call. Does next Tuesday work?\n\nBest,\nJay', response_status: 'pending_approval' },
  { id: id(), lead: 'Velvet Nail Lounge', classification: 'not_interested', confidence: 0.97, received_at: at(-3 * D), from: 'hello@velvetnails.co.uk',
    subject: 'Re: Bookings at Velvet', body: 'We\'ve just signed up with another system, thanks anyway.',
    summary: 'Not interested — already using another provider.', suggested: null, response_status: 'none' },
].map((r) => {
  const l = L(r.lead);
  return { id: r.id, lead_id: l.id, business_name: l.business_name, lead_status: l.status, channel: 'email', from_address: r.from, subject: r.subject,
    body_preview: r.body, classification: r.classification, classification_confidence: r.confidence, summary: r.summary,
    suggested_response: r.suggested, response_status: r.response_status, received_at: r.received_at, handled_at: null, match_status: 'matched' };
});

export const meetings = [
  { lead: 'Riverside Vets', title: 'Intro call', starts_at: dayAt(0, 15, 30), mins: 30, channel: 'google_meet', attendee_name: 'Dr Sarah Lowe', source: 'demo_booking' },
  { lead: 'Oak & Iron Tattoo', title: 'Demo walkthrough', starts_at: dayAt(1, 10, 0), mins: 30, channel: 'phone', attendee_name: 'Marcus Reid', source: 'manual' },
  { lead: 'Glow Aesthetics', title: 'Intro call', starts_at: dayAt(1, 14, 0), mins: 20, channel: 'google_meet', attendee_name: 'Amira Khan', source: 'demo_booking' },
  { lead: 'Crown Street Barbers', title: 'Setup call', starts_at: dayAt(3, 9, 30), mins: 45, channel: 'zoom', attendee_name: 'Callum Fraser', source: 'manual' },
  { lead: 'Bramble Bakery', title: 'Go-live check', starts_at: dayAt(-1, 16, 0), mins: 30, channel: 'phone', attendee_name: 'Ellie Marsh', source: 'manual' },
].map((m) => {
  const l = L(m.lead);
  return { id: id(), lead_id: l.id, business_name: l.business_name, title: m.title, starts_at: m.starts_at,
    ends_at: new Date(Date.parse(m.starts_at) + m.mins * 60e3).toISOString(), timezone: 'Europe/London', status: 'scheduled',
    channel: m.channel, meeting_url: null, attendee_name: m.attendee_name,
    attendee_email: null, source: m.source, outcome: null, calendar_sync: 'synced', calendar_error: null };
});

export const clients = [
  { name: 'Bramble Bakery', contact: 'Ellie Marsh', industry: 'bakery', plan: 'Growth', fee: 149, status: 'onboarding', total: 12, done: 9, overdue: 0, won: -9 },
  { name: 'Clearview Eyecare', contact: 'Tom Ashby', industry: 'opticians', plan: 'Growth', fee: 149, status: 'active', total: 12, done: 12, overdue: 0, won: -34 },
  { name: 'Atlas Fitness Studio', contact: 'Jordan Pike', industry: 'personal training', plan: 'Starter', fee: 79, status: 'onboarding', total: 12, done: 4, overdue: 1, won: -4 },
  { name: 'Hartley Physio', contact: 'Grace Hartley', industry: 'physiotherapy', plan: 'Growth', fee: 149, status: 'active', total: 12, done: 12, overdue: 0, won: -61 },
  { name: 'Mason & Co Barbers', contact: 'Leo Mason', industry: 'barbers', plan: 'Starter', fee: 79, status: 'active', total: 12, done: 12, overdue: 0, won: -88 },
].map((c) => ({ id: id(), lead_id: null, business_name: c.name, contact_name: c.contact, email: null, phone: null, website: null, industry: c.industry,
  plan: c.plan, monthly_fee: c.fee, status: c.status, bos_business_id: null, won_at: at(c.won * D), go_live_at: c.status === 'active' ? at((c.won + 6) * D) : null,
  tasks_total: c.total, tasks_done: c.done, tasks_overdue: c.overdue, next_due_at: c.status === 'onboarding' ? at(2 * D) : null }));

export function metrics(days = 90) {
  const scale = days <= 30 ? 0.42 : days <= 90 ? 1 : 3.1;
  const s = (v) => Math.round(v * scale);
  const funnel = { leads: s(214), qualified: s(131), approved: s(96), contacted: s(88), replied: s(23), demo_sent: s(14), meeting_booked: s(11), won: s(5), lost: s(19) };
  const pct = (a, b) => (b ? Math.round((a / b) * 1000) / 10 : null);
  return {
    ok: true, days, generated_at: new Date().toISOString(),
    leads_by_status: leads.reduce((acc, l) => ({ ...acc, [l.status]: (acc[l.status] || 0) + 1 }), {}),
    funnel,
    conversion: {
      lead_to_qualified: pct(funnel.qualified, funnel.leads), qualified_to_contacted: pct(funnel.contacted, funnel.qualified),
      contacted_to_replied: pct(funnel.replied, funnel.contacted), contacted_to_meeting: pct(funnel.meeting_booked, funnel.contacted),
      meeting_to_won: pct(funnel.won, funnel.meeting_booked), lead_to_won: pct(funnel.won, funnel.leads),
      open_rate: 61.4, click_rate: 12.8, bounce_rate: 1.1,
    },
    outreach: { sent: s(141), delivered: s(139), opened: s(86), clicked: s(18), bounced: s(2), complained: 0, rejected: s(3), first_touch_sent: s(88), followups_sent: s(47), replies_sent: s(6) },
    replies: { positive: s(11), question: s(6), not_interested: s(4), out_of_office: s(2) },
    demos: { created: s(19), sent: s(14), opened: s(12), clicked: s(9), booked: s(6) },
    meetings: { created: s(11), scheduled: 4, completed: s(6), cancelled: s(1), no_show: 0, won: s(5), from_demo_page: s(6) },
    followups: { scheduled: 9, drafted: 2, cancelled: s(12), skipped: s(1) },
    clients: { total: 5, onboarding: 2, active: 3, paused: 0, churned: 0, mrr: 377 },
    pending_work: {
      drafts_awaiting_approval: outreach.length,
      replies_to_handle: replies.filter((r) => !r.handled_at && ['positive', 'question', 'follow_up_needed', 'unclassified'].includes(r.classification)).length,
      reply_responses_pending: replies.filter((r) => r.response_status === 'pending_approval').length,
      meetings_next_36h: meetings.filter((m) => { const t = Date.parse(m.starts_at); return t > Date.now() && t < Date.now() + 36 * H; }).length,
      overdue_onboarding_tasks: 1, followups_due_today: 3,
    },
    by_niche: [
      { key: 'barbers', leads: s(52), qualified: s(36), contacted: s(27), replied: s(9), meetings: s(4), won: s(2) },
      { key: 'dental clinics', leads: s(38), qualified: s(27), contacted: s(18), replied: s(5), meetings: s(3), won: s(1) },
      { key: 'garages', leads: s(41), qualified: s(22), contacted: s(16), replied: s(3), meetings: s(1), won: s(1) },
      { key: 'beauty salons', leads: s(47), qualified: s(29), contacted: s(19), replied: s(4), meetings: s(2), won: s(1) },
      { key: 'opticians', leads: s(36), qualified: s(17), contacted: s(8), replied: s(2), meetings: s(1), won: 0 },
    ],
  };
}

export const profile = { email: 'demo@simplybooked.co.uk', full_name: 'Jay', role: 'owner' };
export const organization = { name: 'SimplyBooked', timezone: 'Europe/London', outreach_enabled: false };

// Find leads: recent map searches, and the made-up businesses a demo search "finds".
export const searchRuns = [
  { id: id(), niche: 'Dentists', city: 'Bristol', region: null, country_code: 'GB', max_results: 40, status: 'completed',
    found_count: 31, new_count: 24, dup_count: 7, error: null, created_at: at(-2 * D - 3 * H), finished_at: at(-2 * D - 3 * H + 140e3) },
  { id: id(), niche: 'Hair salons', city: 'Leeds', region: null, country_code: 'GB', max_results: 20, status: 'completed',
    found_count: 20, new_count: 18, dup_count: 2, error: null, created_at: at(-4 * D - 6 * H), finished_at: at(-4 * D - 6 * H + 95e3) },
  { id: id(), niche: 'Tattoo studios', city: 'Bath', region: null, country_code: 'GB', max_results: 20, status: 'failed',
    found_count: 0, new_count: 0, dup_count: 0, error: 'overpass_http_429', created_at: at(-5 * D - 2 * H), finished_at: at(-5 * D - 2 * H + 60e3) },
  { id: id(), niche: 'Garages', city: 'Sheffield', region: 'South Yorkshire', country_code: 'GB', max_results: 60, status: 'completed',
    found_count: 47, new_count: 41, dup_count: 6, error: null, created_at: at(-9 * D - 4 * H), finished_at: at(-9 * D - 4 * H + 210e3) },
];

const PLACES = ['Hillside', 'Market Street', 'Riverside', 'Parkview', 'Old Town', 'Kingsway', 'Station Road', 'Westgate', 'Abbey', 'Elm Tree',
  'Highfield', 'Northgate', 'Victoria', 'Mill Lane', 'Castle', 'Orchard', 'Bridge Street', 'Southside', 'Church Lane', 'Meadow'];
const NOUN = { Dentists: 'Dental', Doctors: 'Medical Centre', Clinics: 'Clinic', Physiotherapists: 'Physio', Podiatrists: 'Podiatry',
  Opticians: 'Opticians', 'Hair salons': 'Hair', Barbers: 'Barbers', 'Beauty salons': 'Beauty', 'Nail salons': 'Nails', Spas: 'Spa',
  'Massage therapists': 'Massage', Gyms: 'Fitness', 'Tattoo studios': 'Tattoo', Garages: 'Motors', Vets: 'Vets', 'Pet groomers': 'Pet Grooming',
  'Driving schools': 'Driving School' };
/** Fictional businesses for a demo search; same input, same names. */
export function foundLeads(niche, city, count) {
  const out = [];
  const offset = [...`${niche}${city}`].reduce((s, c) => s + c.charCodeAt(0), 0);
  for (let i = 0; i < count; i++) {
    const name = `${PLACES[(offset + i * 7) % PLACES.length]} ${NOUN[niche] || niche}${i >= PLACES.length ? ` ${Math.floor(i / PLACES.length) + 1}` : ''}`;
    out.push(lead(name, niche.toLowerCase(), city, 'new_lead', null, {
      fit: null, is_fit: null, reasons: [], pain_points: [], recommended_offer: null, website_quality: null, has_online_booking: null,
      rating: null, review_count: null, created_at: new Date().toISOString(), updated_at: new Date().toISOString(),
      qualification_summary: null, email: i % 3 ? null : `hello@${name.toLowerCase().replace(/[^a-z0-9]+/g, '')}.co.uk` }));
  }
  return out;
}
