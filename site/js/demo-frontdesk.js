// Sample business for the Front desk demo. Fictional people; the shapes match acq.portal_* exactly.
// Everything is generated from the date, so the diary looks the same every time you open a given day.

const TZ = 'Europe/London';
const DAY = 864e5;

export const business = { name: 'Leo\'s Barbers', industry: 'barbers', timezone: TZ, receptionist_name: 'Sophie', test_mode: false };

const STAFF = [
  { id: 'staff-leo', name: 'Leo', kind: 'staff' },
  { id: 'staff-marcus', name: 'Marcus', kind: 'staff' },
  { id: 'staff-priya', name: 'Priya', kind: 'staff' },
  { id: 'staff-sam', name: 'Sam', kind: 'staff' },
];
const SERVICES = [
  { name: 'Skin fade', min: 45, price: 28, w: 5 },
  { name: 'Haircut', min: 30, price: 24, w: 6 },
  { name: 'Cut and beard', min: 60, price: 36, w: 3 },
  { name: 'Beard trim', min: 20, price: 15, w: 3 },
  { name: 'Kids cut', min: 30, price: 16, w: 2 },
  { name: 'Hot towel shave', min: 45, price: 30, w: 1 },
];
const FIRST = ['Emma', 'James', 'Oliver', 'Amelia', 'Harry', 'Isla', 'Jack', 'Ava', 'George', 'Mia', 'Noah', 'Sophia', 'Leo', 'Grace', 'Arthur',
  'Lily', 'Oscar', 'Freya', 'Charlie', 'Ella', 'Theo', 'Zara', 'Alfie', 'Ruby', 'Henry', 'Evie', 'Kai', 'Maya', 'Ethan', 'Priya', 'Tom', 'Aisha'];
const LAST = 'ABCDEFGHJKLMNPRSTW';
// Mon–Sat; Thursday late opening. 0 = Sunday (closed).
const HOURS = { 1: ['09:00', '18:00'], 2: ['09:00', '18:00'], 3: ['09:00', '18:00'], 4: ['09:00', '20:00'], 5: ['09:00', '18:00'], 6: ['08:30', '17:00'] };

/* ---------- dates in UK time ---------- */
const parts = (date) => Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: TZ, year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', hourCycle: 'h23' })
  .formatToParts(date).filter((p) => p.type !== 'literal').map((p) => [p.type, Number(p.value)]));
const pad = (n) => String(n).padStart(2, '0');
export const ukDate = (date = new Date()) => { const p = parts(date); return `${p.year}-${pad(p.month)}-${pad(p.day)}`; };
const addDays = (ds, n) => { const [y, m, d] = ds.split('-').map(Number); const t = new Date(Date.UTC(y, m - 1, d + n)); return `${t.getUTCFullYear()}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`; };
const dow = (ds) => { const [y, m, d] = ds.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d)).getUTCDay(); };
/** UK wall-clock time on a date -> ISO instant (handles GMT/BST). */
function ukISO(ds, minutes) {
  const [y, m, d] = ds.split('-').map(Number);
  const hh = Math.floor(minutes / 60), mm = minutes % 60;
  let guess = Date.UTC(y, m - 1, d, hh, mm);
  for (let i = 0; i < 2; i++) {
    const p = parts(new Date(guess));
    guess -= Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute) - Date.UTC(y, m - 1, d, hh, mm);
  }
  return new Date(guess).toISOString();
}
const toMin = (hm) => { const [h, m] = hm.split(':').map(Number); return h * 60 + m; };

/* ---------- deterministic randomness ---------- */
function rng(seed) {
  let h = 2166136261;
  for (const ch of seed) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); }
  return () => { h += 0x6d2b79f5; let t = h; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];
const weighted = (r) => { const total = SERVICES.reduce((s, x) => s + x.w, 0); let v = r() * total; for (const s of SERVICES) { v -= s.w; if (v < 0) return s; } return SERVICES[0]; };
const channelOf = (r) => { const v = r(); return v < 0.46 ? 'phone' : v < 0.7 ? 'web' : v < 0.86 ? 'text' : 'team'; };

const cache = new Map();
/** Every booking on one UK date, for every member of staff. */
function bookingsOn(ds) {
  if (cache.has(ds)) return cache.get(ds);
  const hours = HOURS[dow(ds)];
  const out = [];
  if (hours) {
    const now = Date.now();
    STAFF.forEach((st, si) => {
      const r = rng(`${ds}:${st.id}`);
      let t = toMin(hours[0]) + (r() < 0.3 ? 15 : 0);
      const close = toMin(hours[1]);
      const lunch = 12 * 60 + 30 + si * 30;
      let lunched = false;
      while (t < close) {
        if (!lunched && t >= lunch) { t += 30; lunched = true; continue; }
        const gap = r();
        if (gap < 0.22) { t += 15; continue; }
        if (gap < 0.3) { t += 30; continue; }
        const s = weighted(r);
        if (t + s.min > close) break;
        const start = ukISO(ds, t), end = ukISO(ds, t + s.min);
        const past = Date.parse(end) < now;
        const ch = channelOf(r);
        const status = past ? (r() < 0.025 ? 'no_show' : 'completed') : (r() < 0.62 ? 'confirmed' : 'booked');
        out.push({
          id: `bk-${ds}-${si}-${t}`, ref: `${'ABCDEFGHJKMNPQRSTUVWXYZ'[Math.floor(r() * 23)]}${Math.floor(r() * 9000 + 1000)}${'QRSTUVWXYZ'[si]}`,
          staff_id: st.id, staff: st.name, starts_at: start, ends_at: end, service: s.name,
          customer: `${pick(r, FIRST)} ${LAST[Math.floor(r() * LAST.length)]}.`, status, channel: ch, price: s.price,
          // made 0–9 days before the visit
          created_at: new Date(Date.parse(start) - Math.floor(r() * 9 + 0.2) * DAY - Math.floor(r() * 10) * 3600e3).toISOString(),
        });
        t += s.min + (r() < 0.25 ? 15 : 0);
      }
    });
  }
  out.sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
  cache.set(ds, out);
  return out;
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const clone = (v) => JSON.parse(JSON.stringify(v));

export const client = { id: 'demo-client-leos', business_name: business.name, industry: business.industry, status: 'active', role: 'owner', timezone: TZ };

export async function day(ds) {
  await wait(140);
  const d = ds || ukDate();
  const hours = HOURS[dow(d)];
  return { ok: true, date: d, timezone: TZ, closed: !hours, opens: hours ? hours[0] : '09:00', closes: hours ? hours[1] : '17:00',
    staff: clone(STAFF), bookings: clone(bookingsOn(d)).map(({ staff, created_at, ...b }) => b) };
}

export async function upcoming(fromDs, days = 7) {
  await wait(140);
  const from = fromDs || ukDate();
  const list = [];
  for (let i = 0; i < days; i++) list.push(...bookingsOn(addDays(from, i)));
  const cut = Date.now() - 30 * 60e3;
  return { ok: true, from, timezone: TZ, bookings: clone(list.filter((b) => Date.parse(b.starts_at) >= cut && (b.status === 'booked' || b.status === 'confirmed')))
    .map(({ created_at, ...b }) => b) };
}

function windowStats(endDs, days) {
  let bookings = 0, byAi = 0, revenue = 0, noShows = 0;
  const daily = [];
  for (let i = days - 1; i >= 0; i--) {
    const ds = addDays(endDs, -i);
    const list = bookingsOn(ds);
    const live = list.filter((b) => b.status !== 'cancelled');
    bookings += live.length;
    byAi += live.filter((b) => b.channel !== 'team').length;
    const rev = live.filter((b) => Date.parse(b.starts_at) < Date.now() && b.status !== 'no_show').reduce((s, b) => s + b.price, 0);
    revenue += rev;
    noShows += list.filter((b) => b.status === 'no_show').length;
  }
  // bookings *made* each day (they arrive every day, including Sundays when the shop is shut)
  const made = new Map();
  for (let i = -1; i < days + 10; i++) {
    for (const b of bookingsOn(addDays(endDs, -days + 1 + i))) {
      if (Date.parse(b.created_at) > Date.now()) continue; // not made yet
      const k = ukDate(new Date(b.created_at));
      if (!made.has(k)) made.set(k, { n: 0, v: 0 });
      made.get(k).n++; made.get(k).v += b.price;
    }
  }
  for (let i = days - 1; i >= 0; i--) {
    const ds = addDays(endDs, -i);
    daily.push({ date: ds, bookings: made.get(ds)?.n || 0, revenue: made.get(ds)?.v || 0 });
  }
  return { bookings, byAi, revenue, noShows, daily };
}

export async function overview(days = 30) {
  await wait(200);
  const today = ukDate();
  const cur = windowStats(today, days);
  const prev = windowStats(addDays(today, -days), days);
  const calls = Math.round(cur.byAi * 0.74 + days * 1.6);
  const callsPrev = Math.round(prev.byAi * 0.74 + days * 1.6);
  const up = (await upcoming(today, 14)).bookings;
  const monthly = [];
  const [y, m] = today.split('-').map(Number);
  for (let i = 5; i >= 0; i--) {
    const dt = new Date(Date.UTC(y, m - 1 - i, 1));
    const key = `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}`;
    const row = { month: key, phone: 0, web: 0, text: 0, team: 0 };
    const last = new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth() + 1, 0)).getUTCDate();
    for (let d = 1; d <= last; d++) {
      const ds = `${key}-${pad(d)}`;
      if (ds > today) break;
      for (const b of bookingsOn(ds)) if (Date.parse(b.starts_at) < Date.now() && b.status === 'completed') row[b.channel] += b.price;
    }
    monthly.push(row);
  }
  return {
    ok: true, days, today, business: clone(business),
    kpis: {
      bookings: cur.bookings, bookings_prev: prev.bookings, by_ai: cur.byAi, revenue: cur.revenue, revenue_prev: prev.revenue,
      upcoming: up.length, confirmed_rate: up.length ? Math.round((up.filter((b) => b.status === 'confirmed').length / up.length) * 1000) / 10 : null,
      no_shows: cur.noShows, calls, calls_prev: callsPrev,
    },
    daily: cur.daily, monthly,
  };
}

const CALLS = [
  ['Booked a skin fade with Leo for Thursday at 2:30pm and asked for a text confirmation.', 'phone', 132],
  ['Asked whether there is parking nearby. Sophie explained the free car park behind the shop.', 'phone', 48],
  ['Moved Saturday\'s haircut to next Tuesday at 11am because of a family event.', 'phone', 97],
  ['Wanted a kids cut for two brothers back to back. Booked both with Priya on Friday.', 'web', 164],
  ['Asked about prices for a hot towel shave and booked one for Saturday morning.', 'phone', 110],
  ['Called after closing to cancel tomorrow\'s appointment. The slot was released for others.', 'phone', 41],
  ['Asked if Marcus does beard designs. Took a message for Marcus to call back.', 'phone', 76],
  ['Booked a cut and beard with Sam for Thursday evening during late opening.', 'web', 121],
];
const TEXTS = [ // newest first: each customer's message sits just below Sophie's answer
  ['out', 'Thanks Emma, you are confirmed for Skin fade on Thu at 2:30pm. See you then!', 'confirmed'], ['in', 'C', null],
  ['out', 'No problem. You are now booked for Fri at 4:15pm with Leo. Ref K4821R.', 'reply'], ['in', 'Can I move my cut to Friday after 4?', null],
  ['in', 'Yes', null], ['out', 'Reminder: your Haircut at Leo\'s Barbers is on Sat at 10:00am. Reply C to confirm.', 'reminder'],
];

export async function activity() {
  await wait(160);
  const r = rng(`calls:${ukDate()}`);
  let t = Date.now() - 22 * 60e3;
  const calls = CALLS.map(([summary, channel, dur], i) => {
    t -= Math.floor((1.5 + r() * 7) * 3600e3);
    return { id: `call-${i}`, started_at: new Date(t).toISOString(), duration_s: dur, channel,
      customer: `${pick(r, FIRST)} ${LAST[Math.floor(r() * LAST.length)]}.`, summary, ended_reason: 'customer-ended-call' };
  });
  let u = Date.now() - 8 * 60e3;
  const names = ['Emma T.', 'Emma T.', 'Jack R.', 'Jack R.', 'Ava M.', 'Ava M.'];
  const texts = TEXTS.map(([direction, body, purpose], i) => {
    u -= Math.floor((0.2 + r() * 3) * 3600e3);
    return { id: `msg-${i}`, at: new Date(u).toISOString(), direction, purpose, customer: names[i], body };
  });
  return { ok: true, calls, texts };
}
