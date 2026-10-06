// SimplyBooked dashboard.
//   Front desk: a business's own diary, bookings, calls and revenue (acq.portal_* functions over the booking engine).
//   Growth: the SimplyBooked team's lead pipeline, approvals and clients.
// Live mode shows what the signed-in person is allowed to see. ?demo=1 shows the Front desk of a fictional barbershop,
// ?demo=sales adds the Growth screens; demo mode never contacts the server.
import { getSession, signOut } from './auth.js';
import * as api from './api.js';
import * as demo from './demo-data.js';
import * as desk from './demo-frontdesk.js';
import { TRADES, COUNTRIES } from './trades.js';

const PARAMS = new URLSearchParams(location.search);
const DEMO = PARAMS.has('demo');
const DEMO_SALES = DEMO && PARAMS.get('demo') === 'sales';

/* ------------------------------------------------------------------ helpers */

/** Builds DOM safely: strings always become text nodes, never HTML. */
function h(tag, props = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on')) { if (typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v); }
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (k in el && typeof v !== 'string') el[k] = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid === null || kid === undefined || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
const $ = (s, root = document) => root.querySelector(s);
const svg = (d, size = 18) => {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('width', size); s.setAttribute('height', size); s.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', d); s.append(p);
  return s;
};
const ICON_CLOSE = 'M6 6l12 12M18 6L6 18';
const ICON_CHECK = 'M5 12.5l4.5 4.5L19 7.5';

/** Only http(s) links from data are ever rendered as links. */
function safeUrl(u) {
  if (!u) return null;
  try {
    const url = new URL(/^https?:\/\//i.test(u) ? u : `https://${u}`);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null;
  } catch { return null; }
}

const BROWSER_TZ = Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/London';
let TZ = BROWSER_TZ;
const fmt = (opts) => new Intl.DateTimeFormat('en-GB', { timeZone: TZ, ...opts });
const time = (iso) => fmt({ hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso)).replace(' ', '').toLowerCase();
const dayKey = (d) => fmt({ year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
function dayLabel(iso) {
  const d = new Date(iso), today = new Date(), tomorrow = new Date(Date.now() + 864e5), yesterday = new Date(Date.now() - 864e5);
  if (dayKey(d) === dayKey(today)) return 'Today';
  if (dayKey(d) === dayKey(tomorrow)) return 'Tomorrow';
  if (dayKey(d) === dayKey(yesterday)) return 'Yesterday';
  return fmt({ weekday: 'long', day: 'numeric', month: 'long' }).format(d);
}
function ago(iso) {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) { const n = Math.floor(s / 3600); return `${n} hour${n === 1 ? '' : 's'} ago`; }
  if (s < 7 * 86400) { const n = Math.floor(s / 86400); return `${n} day${n === 1 ? '' : 's'} ago`; }
  return fmt({ day: 'numeric', month: 'short' }).format(new Date(iso));
}
const int = (n) => new Intl.NumberFormat('en-GB').format(Number(n) || 0);
const money = (n) => new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP', maximumFractionDigits: 0 }).format(Number(n) || 0);
const pctText = (v) => (v === null || v === undefined ? '—' : `${Math.round(Number(v))}%`);
const titleCase = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : '');

function toast(message, isError = false) {
  const t = h('div', { class: `toast${isError ? ' is-error' : ''}`, text: message });
  $('.toasts').append(t);
  setTimeout(() => t.remove(), isError ? 7000 : 4200);
}

async function withBusy(btn, fn) {
  if (btn) { btn.disabled = true; btn.setAttribute('aria-busy', 'true'); }
  try { return await fn(); }
  catch (e) {
    if (e?.code === 'unauthenticated') { location.replace('/login.html'); return undefined; }
    toast(e?.message || 'That didn\'t work. Try again.', true);
    return undefined;
  } finally {
    if (btn && btn.isConnected) { btn.disabled = false; btn.removeAttribute('aria-busy'); }
  }
}

/* ------------------------------------------------------------------ vocabulary */

const STATUSES = [
  ['new_lead', 'New lead'], ['qualified', 'Qualified'], ['approved', 'Approved'], ['contacted', 'Contacted'], ['replied', 'Replied'],
  ['demo_sent', 'Demo sent'], ['meeting_booked', 'Meeting booked'], ['won', 'Won'], ['lost', 'Lost'],
];
const STATUS_LABEL = Object.fromEntries(STATUSES);
// Mirrors acq.status_allowed() — the database enforces it either way.
const MOVES = {
  new_lead: ['qualified', 'lost'], qualified: ['new_lead', 'approved', 'lost'], approved: ['qualified', 'contacted', 'lost'],
  contacted: ['replied', 'demo_sent', 'meeting_booked', 'lost'], replied: ['demo_sent', 'meeting_booked', 'won', 'lost'],
  demo_sent: ['replied', 'meeting_booked', 'won', 'lost'], meeting_booked: ['demo_sent', 'replied', 'won', 'lost'],
  lost: ['new_lead', 'qualified'], won: [],
};
const STATUS_TONE = { won: 'pill-mint', lost: 'pill-red', meeting_booked: 'pill-blue', replied: 'pill-blue', demo_sent: 'pill-blue' };
const REPLY_LABEL = { positive: ['Interested', 'pill-mint'], question: ['Question', 'pill-blue'], follow_up_needed: ['Needs follow-up', 'pill-amber'],
  negative: ['Negative', 'pill-red'], not_interested: ['Not interested', 'pill-red'], unsubscribe: ['Unsubscribed', 'pill-red'],
  out_of_office: ['Out of office', ''], unclassified: ['Not sorted yet', 'pill-amber'] };
const CHANNEL = { google_meet: 'Google Meet', phone: 'Phone call', in_person: 'In person', zoom: 'Zoom' };
const CLIENT_TONE = { active: 'pill-mint', onboarding: 'pill-blue', paused: 'pill-amber', churned: 'pill-red' };

const scoreEl = (s) => (s === null || s === undefined ? null
  : h('span', { class: `score ${s >= 80 ? 'score-hi' : s >= 60 ? 'score-mid' : 'score-lo'}`, title: 'Fit score out of 100', text: String(s) }));
const statusPill = (s) => h('span', { class: `pill ${STATUS_TONE[s] || ''}`, text: STATUS_LABEL[s] || s });

/* ------------------------------------------------------------------ data sources */

const clone = (v) => JSON.parse(JSON.stringify(v));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const live = {
  async me(uid) {
    const [profiles, orgs] = await Promise.all([
      api.select('profiles', `select=email,full_name,role,org_id&id=eq.${encodeURIComponent(uid)}&limit=1`),
      api.select('organizations', 'select=name,timezone,outreach_enabled&limit=1'),
    ]);
    return { profile: profiles?.[0] || null, org: orgs?.[0] || null };
  },
  metrics: (days) => api.rpc('dashboard_metrics', { p_days: days }),
  leads: () => api.select('v_leads', 'select=id,business_name,website,phone,email,niche,category,city,status,score,rating,review_count,do_not_contact,source_key,updated_at,lost_reason,fit,reasons,pain_points,recommended_offer,qualification_summary&order=score.desc.nullslast,updated_at.desc&limit=600'),
  outreach: () => api.select('v_outreach', 'select=*&status=eq.pending_approval&order=created_at.asc&limit=100'),
  replies: () => api.select('v_replies', 'select=*&handled_at=is.null&order=received_at.desc&limit=100'),
  meetings: () => api.select('v_meetings', `select=*&starts_at=gte.${encodeURIComponent(new Date(Date.now() - 14 * 864e5).toISOString())}&status=in.(scheduled,completed,no_show)&order=starts_at.asc&limit=200`),
  clients: () => api.select('v_clients', 'select=*&order=won_at.desc.nullslast&limit=200'),
  act: (name, params) => api.action(name, params),
  // Find leads
  searchSources: () => api.select('lead_sources', 'select=key,name,provider&active=is.true&provider=not.in.(manual,csv)&order=key.asc'),
  searchCap: async () => Number((await api.select('system_settings', 'select=value&key=eq.max_search_runs_per_day&limit=1'))?.[0]?.value) || 20,
  searchRuns: () => api.select('lead_search_runs', 'select=id,niche,city,region,country_code,max_results,status,found_count,new_count,dup_count,error,created_at,finished_at&order=created_at.desc&limit=40'),
  // Front desk
  portalClients: async () => (await api.rpc('portal_clients'))?.clients || [],
  overview: (client, days) => api.rpc('portal_overview', { p_client: client, p_days: days }),
  day: (client, date) => api.rpc('portal_day', { p_client: client, p_date: date || null }),
  upcoming: (client, from, days) => api.rpc('portal_upcoming', { p_client: client, p_from: from || null, p_days: days }),
  activity: (client) => api.rpc('portal_activity', { p_client: client, p_limit: 40 }),
};

const demoStore = { leads: clone(demo.leads), outreach: clone(demo.outreach), replies: clone(demo.replies), meetings: clone(demo.meetings), clients: clone(demo.clients),
  runs: clone(demo.searchRuns) };
const demoId = () => (crypto.randomUUID ? crypto.randomUUID() : `demo-${Date.now()}-${Math.random().toString(16).slice(2)}`);
/** Demo searches move from waiting to searching to done over a few seconds, then "find" fictional businesses. */
function advanceDemoRuns() {
  for (const r of demoStore.runs) {
    if (!r._t || r.status === 'completed') continue;
    const age = Date.now() - r._t;
    if (age < 3000) r.status = 'queued';
    else if (age < 8000) r.status = 'running';
    else {
      const seed = [...`${r.niche}${r.city}`].reduce((a, c) => a + c.charCodeAt(0), 0);
      r.found_count = Math.min(r.max_results, 9 + (seed % 23));
      r.dup_count = Math.round(r.found_count * 0.18);
      r.new_count = r.found_count - r.dup_count;
      r.status = 'completed'; r.finished_at = new Date().toISOString();
      demoStore.leads.push(...demo.foundLeads(r.niche, r.city, r.new_count));
    }
  }
}
const sample = {
  async me() { await wait(120); return { profile: demo.profile, org: { ...demo.organization, outreach_enabled: true } }; },
  async metrics(days) {
    await wait(200);
    const m = demo.metrics(days);
    m.pending_work.drafts_awaiting_approval = demoStore.outreach.length;
    m.pending_work.replies_to_handle = demoStore.replies.filter((r) => !r.handled_at && ['positive', 'question', 'follow_up_needed', 'unclassified'].includes(r.classification)).length;
    return m;
  },
  async leads() { await wait(180); return clone(demoStore.leads); },
  async outreach() { await wait(160); return clone(demoStore.outreach); },
  async replies() { await wait(160); return clone(demoStore.replies.filter((r) => !r.handled_at)); },
  async meetings() { await wait(160); return clone(demoStore.meetings); },
  async clients() { await wait(160); return clone(demoStore.clients); },
  async act(name, p) {
    await wait(350);
    const drop = (list, idv) => { const i = list.findIndex((x) => x.id === idv); if (i >= 0) list.splice(i, 1); };
    if (name === 'move_lead') { const l = demoStore.leads.find((x) => x.id === p.lead_id); if (l) { l.status = p.to; if (p.to === 'lost') l.lost_reason = p.reason; } }
    if (name === 'mark_do_not_contact') { const l = demoStore.leads.find((x) => x.id === p.lead_id); if (l) l.do_not_contact = true; }
    if (name === 'approve_message' || name === 'reject_message') drop(demoStore.outreach, p.message_id);
    if (name === 'approve_messages') p.message_ids.forEach((m) => drop(demoStore.outreach, m));
    if (name === 'approve_reply_response' || name === 'reject_reply_response') {
      const r = demoStore.replies.find((x) => x.id === p.reply_id);
      if (r) r.response_status = name === 'approve_reply_response' ? 'approved' : 'rejected';
    }
    if (name === 'mark_reply_handled') { const r = demoStore.replies.find((x) => x.id === p.reply_id); if (r) r.handled_at = new Date().toISOString(); }
    if (name === 'set_meeting_outcome') { const m = demoStore.meetings.find((x) => x.id === p.meeting_id); if (m) m.status = p.status; }
    if (name === 'queue_search_run') {
      advanceDemoRuns();
      const same = demoStore.runs.find((r) => ['queued', 'running'].includes(r.status) && r.niche.toLowerCase() === p.niche.toLowerCase()
        && (r.city || '').toLowerCase() === (p.city || '').toLowerCase() && r.country_code === p.country);
      if (same) return { ok: true, run_id: same.id, duplicate: true, demo: true };
      const run = { id: demoId(), niche: p.niche, city: p.city || null, region: p.region || null, country_code: p.country, max_results: p.max_results,
        status: 'queued', found_count: 0, new_count: 0, dup_count: 0, error: null, created_at: new Date().toISOString(), finished_at: null, _t: Date.now() };
      demoStore.runs.unshift(run);
      return { ok: true, run_id: run.id, demo: true };
    }
    if (name === 'import_leads') {
      const res = { ok: true, received: p.items.length, created: 0, merged: 0, duplicate: 0, suppressed: 0, invalid: 0, limited: 0, demo: true };
      const key = (x) => `${String(x.business_name || '').trim().toLowerCase()}|${String(x.city || '').trim().toLowerCase()}`;
      const known = new Set(demoStore.leads.map(key));
      for (const it of p.items) {
        if (!String(it.business_name || '').trim()) { res.invalid++; continue; }
        if (known.has(key(it))) { res.duplicate++; continue; }
        known.add(key(it));
        demoStore.leads.push({ id: demoId(), business_name: it.business_name.trim(), niche: it.niche || null, city: it.city || null, status: 'new_lead', score: null,
          website: it.website || null, phone: it.phone || null, email: it.email || null, do_not_contact: false, updated_at: new Date().toISOString() });
        res.created++;
      }
      return res;
    }
    return { ok: true, demo: true };
  },
  // Find leads
  async searchSources() { await wait(100); return [{ key: 'osm', name: 'OpenStreetMap', provider: 'osm_overpass' }]; },
  async searchCap() { return 20; },
  async searchRuns() { await wait(140); advanceDemoRuns(); return clone(demoStore.runs).map(({ _t, ...r }) => r); },
  // Front desk
  portalClients: async () => [clone(desk.client)],
  overview: (_c, days) => desk.overview(days),
  day: (_c, date) => desk.day(date),
  upcoming: (_c, from, days) => desk.upcoming(from, days),
  activity: () => desk.activity(),
};

const src = DEMO ? sample : live;
const state = { profile: null, org: null, metrics: null, days: 90, leadFilter: '',
  canGrowth: false, canDesk: false, clients: [], client: null, deskDays: 30, calDate: null, railDay: null };

/* ------------------------------------------------------------------ chrome */

const VIEWS = {
  overview: { group: 'desk', title: 'Overview', sub: () => state.client?.business_name || '', render: renderOverview },
  calendar: { group: 'desk', title: 'Calendar', sub: () => state.client?.business_name || '', render: renderCalendar },
  activity: { group: 'desk', title: 'Calls and texts', sub: () => `What ${state.receptionist || 'your receptionist'} handled for ${state.client?.business_name || 'you'}`, render: renderActivity },
  sales: { group: 'growth', title: 'Sales', sub: () => (state.org?.name ? `${state.org.name} at a glance` : 'Your pipeline at a glance'), render: renderToday },
  leads: { group: 'growth', title: 'Find leads', sub: () => 'Search a town for businesses that fit, or bring your own list', render: renderFind },
  pipeline: { group: 'growth', title: 'Pipeline', sub: () => 'Every business you\'re talking to, by stage', render: renderPipeline },
  approvals: { group: 'growth', title: 'Approvals', sub: () => 'Nothing is sent until you approve it', render: renderApprovals },
  replies: { group: 'growth', title: 'Replies', sub: () => 'Answers from businesses you\'ve contacted', render: renderReplies },
  meetings: { group: 'growth', title: 'Meetings', sub: () => 'Calls and demos, past fortnight and ahead', render: renderMeetings },
  clients: { group: 'growth', title: 'Clients', sub: () => 'Onboarding progress and monthly revenue', render: renderClients },
};

const view = $('#view');
const tools = $('.js-tools');

function setCounts() {
  const pw = state.metrics?.pending_work || {};
  const set = (sel, n) => { const el = $(sel); el.textContent = n > 99 ? '99+' : String(n); el.hidden = !n; el.setAttribute('aria-label', `${n} waiting`); };
  set('.js-count-approvals', Number(pw.drafts_awaiting_approval) || 0);
  set('.js-count-replies', Number(pw.replies_to_handle) || 0);
}

function loading(rows = 3) {
  view.replaceChildren(...Array.from({ length: rows }, (_, i) => h('div', { class: 'skeleton', 'aria-hidden': 'true', dataset: { h: String(i) } })));
  view.querySelectorAll('.skeleton').forEach((s, i) => { s.style.height = `${i === 0 ? 120 : 220}px`; s.style.marginBottom = '16px'; });
}

function failed(err, retry) {
  if (err?.code === 'unauthenticated') { location.replace('/login.html'); return; }
  view.replaceChildren(h('div', { class: 'error-box', role: 'alert' },
    h('span', { text: err?.message || 'We couldn\'t load this page.' }),
    h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text: 'Try again', onClick: retry })));
}

function empty(title, body, action) {
  return h('div', { class: 'panel empty' }, h('h2', { text: title }), h('p', { text: body }), action || null);
}

let renderSeq = 0;
const allowed = (key) => VIEWS[key] && (VIEWS[key].group === 'desk' ? state.canDesk : state.canGrowth);
const homeView = () => (state.canGrowth && !DEMO ? 'sales' : 'overview');
async function route() {
  const name = location.hash.replace('#', '');
  const key = allowed(name) ? name : homeView();
  if (name !== key) history.replaceState(null, '', `${location.pathname}${location.search}#${key}`);
  const v = VIEWS[key];
  // Front desk speaks the business's time; Growth speaks the organisation's
  TZ = v.group === 'desk' ? (state.clientTz || 'Europe/London') : (state.orgTz || BROWSER_TZ);
  for (const a of document.querySelectorAll('.side-nav a')) {
    if (a.dataset.view === key) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
  $('.js-view-title').textContent = v.title;
  $('.js-view-sub').textContent = v.sub();
  document.title = `${v.title} — SimplyBooked`;
  tools.replaceChildren();
  closeNav();
  const seq = ++renderSeq;
  view.setAttribute('aria-busy', 'true');
  try {
    await v.render(() => seq === renderSeq);
  } catch (e) {
    if (seq === renderSeq) failed(e, route);
  } finally {
    if (seq === renderSeq) view.setAttribute('aria-busy', 'false');
  }
}

function openNav() { $('#side').classList.add('is-open'); $('.side-scrim').hidden = false; $('.js-nav-open').setAttribute('aria-expanded', 'true'); }
function closeNav() { $('#side').classList.remove('is-open'); $('.side-scrim').hidden = true; $('.js-nav-open').setAttribute('aria-expanded', 'false'); }

/* ------------------------------------------------------------------ dialogs */

const drawer = $('.js-drawer');
const confirmDlg = $('.js-confirm');
drawer.addEventListener('click', (e) => { if (e.target === drawer) drawer.close(); });

/** Asks before something that can't be undone. Resolves to false, or to the text typed (or true when no input). */
function ask({ title, body, confirm, danger = false, input = null }) {
  return new Promise((resolve) => {
    const field = input ? h('input', { class: 'input', id: 'confirm-input', maxlength: '200', required: input.required ? true : null, placeholder: input.placeholder || '' }) : null;
    const form = h('form', { method: 'dialog' },
      h('h2', { id: 'confirm-title', text: title }),
      body ? h('p', { text: body }) : null,
      field ? h('div', {}, h('label', { class: 'label', for: 'confirm-input', text: input.label }), field) : null,
      h('div', { class: 'confirm-actions' },
        h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text: 'Cancel', onClick: () => confirmDlg.close('cancel') }),
        h('button', { class: `btn btn-sm ${danger ? 'btn-danger-quiet' : 'btn-primary'}`, type: 'submit', value: 'ok', text: confirm })));
    form.addEventListener('submit', (e) => {
      if (field && input.required && !field.value.trim()) { e.preventDefault(); field.setAttribute('aria-invalid', 'true'); field.focus(); }
    });
    confirmDlg.replaceChildren(form);
    confirmDlg.returnValue = '';
    confirmDlg.addEventListener('close', () => {
      resolve(confirmDlg.returnValue === 'ok' ? (field ? field.value.trim() : true) : false);
    }, { once: true });
    confirmDlg.showModal();
    (field || form.querySelector('button[type="submit"]')).focus();
  });
}

/* ------------------------------------------------------------------ Today */

const metricsLoads = new Map(); // in-flight requests, one per period
async function loadMetrics(force = false) {
  const days = state.days;
  if (!force && state.metrics && state.metrics.days === days) { setCounts(); return state.metrics; }
  let p = metricsLoads.get(days);
  if (!p || force) {
    p = src.metrics(days).then((m) => { if (days === state.days) state.metrics = m; return m; });
    metricsLoads.set(days, p);
    p.finally(() => { if (metricsLoads.get(days) === p) metricsLoads.delete(days); }).catch(() => {});
  }
  const m = await p;
  setCounts();
  return m;
}
/** After a change: the sidebar counts and Today's numbers are refreshed in the background. */
function invalidate() { state.metrics = null; loadMetrics(true).catch(() => {}); }

async function renderToday(current) {
  const range = h('select', { class: 'select', 'aria-label': 'Period' },
    [[30, 'Last 30 days'], [90, 'Last 90 days'], [365, 'Last 12 months']].map(([d, t]) => h('option', { value: String(d), text: t, selected: d === state.days })));
  range.addEventListener('change', () => { state.days = Number(range.value); route(); });
  tools.append(range);
  loading(3);

  const [m, meetings] = await Promise.all([loadMetrics(), src.meetings().catch(() => [])]);
  if (!current()) return;
  const f = m.funnel || {}, c = m.conversion || {}, pw = m.pending_work || {};

  const hour = Number(fmt({ hour: 'numeric', hour12: false }).format(new Date()));
  const part = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  const who = state.profile?.full_name || (state.profile?.email || '').split('@')[0] || '';
  const greeting = h('div', { class: 'today-greeting' },
    h('div', {}, h('h2', { text: who ? `${part}, ${who}.` : `${part}.` }), h('p', { text: fmt({ weekday: 'long', day: 'numeric', month: 'long' }).format(new Date()) })));

  const one = (n, single, many) => (Number(n) === 1 ? single : many);
  const needItems = [
    [pw.drafts_awaiting_approval, one(pw.drafts_awaiting_approval, 'email waiting for your approval', 'emails waiting for your approval'), '#approvals', true],
    [pw.replies_to_handle, one(pw.replies_to_handle, 'reply to answer', 'replies to answer'), '#replies', true],
    [pw.meetings_next_36h, one(pw.meetings_next_36h, 'meeting in the next 36 hours', 'meetings in the next 36 hours'), '#meetings', false],
    [pw.followups_due_today, one(pw.followups_due_today, 'follow-up due in the next day', 'follow-ups due in the next day'), null, false],
    [pw.overdue_onboarding_tasks, one(pw.overdue_onboarding_tasks, 'overdue onboarding task', 'overdue onboarding tasks'), '#clients', true],
  ].filter(([n]) => Number(n) > 0);
  const needs = h('section', { class: 'needs', 'aria-label': 'Needs your attention' },
    needItems.length
      ? needItems.map(([n, label, href, hot]) => h(href ? 'a' : 'div', { class: `need${hot ? ' is-hot' : ''}`, href }, h('b', { text: int(n) }), h('span', { text: label })))
      : h('p', { class: 'need-done' }, svg(ICON_CHECK, 20), 'You\'re all caught up. Nothing needs you right now.'));

  const note = (v, words) => (v === null || v === undefined ? null : `${pctText(v)} ${words}`);
  const kpi = (label, value, note, extra = '') => h('div', { class: `kpi ${extra}` }, h('dt', { text: label }), h('dd', { text: value }), note ? h('small', { text: note }) : null);
  const kpis = h('dl', { class: 'kpis', 'aria-label': `Results for the last ${m.days} days` },
    kpi('New leads', int(f.leads), note(c.lead_to_qualified, 'qualified')),
    kpi('Contacted', int(f.contacted), note(c.open_rate, 'opened')),
    kpi('Replied', int(f.replied), note(c.contacted_to_replied, 'reply rate')),
    kpi('Meetings booked', int(f.meeting_booked), note(c.contacted_to_meeting, 'of contacted')),
    kpi('Won', int(f.won), note(c.meeting_to_won, 'of meetings')),
    kpi('Monthly revenue', money(m.clients?.mrr), `${int(m.clients?.active)} active ${one(m.clients?.active, 'client', 'clients')}`, 'kpi-money'));

  const stages = [['leads', 'Leads'], ['qualified', 'Qualified'], ['contacted', 'Contacted'], ['replied', 'Replied'], ['demo_sent', 'Demo sent'], ['meeting_booked', 'Meeting booked'], ['won', 'Won']];
  const top = Math.max(1, Number(f.leads) || 0);
  const funnel = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('h2', { text: 'How leads become clients' }), h('span', { class: 'muted', text: `Last ${m.days} days` })),
    h('div', { class: 'panel-body' },
      h('div', { class: 'funnel', role: 'list' }, stages.map(([k, label]) => {
        const v = Number(f[k]) || 0;
        const fill = h('div', { class: 'funnel-fill' });
        fill.style.width = `${Math.max(0.6, (v / top) * 100)}%`;
        return h('div', { class: `funnel-row${k === 'won' ? ' is-won' : ''}`, role: 'listitem', 'aria-label': `${label}: ${v}` },
          h('span', { text: label }), h('div', { class: 'funnel-track', 'aria-hidden': 'true' }, fill), h('span', { class: 'num', text: int(v) }));
      })),
      h('p', { class: 'funnel-note' },
        h('span', {}, 'Emails opened ', h('b', { text: pctText(c.open_rate) })),
        h('span', {}, 'Bounced ', h('b', { text: pctText(c.bounce_rate) })),
        h('span', {}, 'Lead to client ', h('b', { text: pctText(c.lead_to_won) })))));

  const upcoming = (meetings || []).filter((x) => x.status === 'scheduled' && Date.parse(x.ends_at || x.starts_at) > Date.now()).slice(0, 5);
  const coming = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('h2', { text: 'Coming up' }), h('a', { href: '#meetings', class: 'text-link', text: 'All meetings' })),
    h('div', { class: 'panel-body' }, upcoming.length
      ? h('ul', { class: 'list' }, upcoming.map((x) => h('li', {},
        h('span', { class: 'when', text: time(x.starts_at) }),
        h('span', { class: 'what' }, h('b', { text: x.business_name || x.title }), h('span', { text: `${dayLabel(x.starts_at)}, ${x.title}${x.attendee_name ? ` with ${x.attendee_name}` : ''}` })),
        h('span', { class: 'pill pill-plain', text: CHANNEL[x.channel] || x.channel || '' }))))
      : h('p', { class: 'muted', text: 'No meetings booked yet. When a business books a call from a demo page, it appears here.' })));

  const rows = (m.by_niche || []).slice(0, 6);
  const niches = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('h2', { text: 'Best-responding trades' }), h('span', { class: 'muted', text: 'By business type' })),
    h('div', { class: 'panel-body table-wrap' }, rows.length
      ? h('table', { class: 'table' },
        h('thead', {}, h('tr', {}, h('th', { scope: 'col', text: 'Trade' }), h('th', { scope: 'col', class: 'r', text: 'Leads' }), h('th', { scope: 'col', class: 'r', text: 'Contacted' }), h('th', { scope: 'col', class: 'r', text: 'Replied' }), h('th', { scope: 'col', class: 'r', text: 'Won' }))),
        h('tbody', {}, rows.map((r) => h('tr', {}, h('td', { text: titleCase(r.key) }), h('td', { class: 'r', text: int(r.leads) }), h('td', { class: 'r', text: int(r.contacted) }), h('td', { class: 'r', text: int(r.replied) }), h('td', { class: 'r', text: int(r.won) })))))
      : h('p', { class: 'muted', text: 'Once you\'ve contacted a few businesses, you\'ll see which trades reply most.' })));

  view.replaceChildren(h('div', { class: 'today-grid' }, greeting, needs, kpis, funnel, coming, niches));
}

/* ------------------------------------------------------------------ Pipeline */

async function renderPipeline(current) {
  loading(2);
  const leads = await src.leads();
  if (!current()) return;
  if (!leads.length) {
    view.replaceChildren(empty('No leads yet', 'Search a town or import a list of businesses, and they\'ll appear here sorted by how well they fit.',
      h('a', { class: 'btn btn-primary', href: '#leads', text: 'Find leads' })));
    return;
  }
  const search = h('input', { class: 'input', type: 'search', placeholder: 'Find a business, trade or town', 'aria-label': 'Find a lead', value: state.leadFilter });
  const count = h('span', { class: 'muted' });
  const board = h('div', { class: 'board' });
  const draw = () => {
    const q = state.leadFilter.toLowerCase();
    const shown = q ? leads.filter((l) => [l.business_name, l.niche, l.city].some((x) => (x || '').toLowerCase().includes(q))) : leads;
    count.textContent = `${int(shown.length)} of ${int(leads.length)} businesses`;
    board.replaceChildren(...STATUSES.map(([key, label]) => {
      const items = shown.filter((l) => l.status === key);
      return h('section', { class: 'col', 'aria-label': `${label}, ${items.length}` },
        h('div', { class: 'col-head' }, h('h2', { text: label }), h('span', { text: int(items.length) })),
        items.length ? items.map((l) => h('button', { class: 'card', type: 'button', onClick: () => openLead(l, leads, draw) },
          h('div', { class: 'card-top' }, h('b', { text: l.business_name }), scoreEl(l.score)),
          h('span', { text: [titleCase(l.niche || l.category), l.city].filter(Boolean).join(', ') }),
          l.do_not_contact ? h('span', { class: 'pill pill-red', text: 'Do not contact' }) : null))
          : h('p', { class: 'col-empty', text: 'None' }));
    }));
  };
  search.addEventListener('input', () => { state.leadFilter = search.value.trim(); draw(); });
  draw();
  view.replaceChildren(h('div', { class: 'board-tools' }, search, count), board);
}

function openLead(lead, all, redraw) {
  const close = h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Close', onClick: () => drawer.close() }, svg(ICON_CLOSE));
  const web = safeUrl(lead.website);
  const tel = lead.phone ? `tel:${lead.phone.replace(/[^\d+]/g, '')}` : null;
  const fact = (label, node) => (node ? [h('dt', { text: label }), h('dd', {}, node)] : null);

  const moves = h('div', { class: 'moves' }, (MOVES[lead.status] || []).map((to) => {
    const b = h('button', { class: `btn btn-sm ${to === 'lost' ? 'btn-danger-quiet' : 'btn-quiet'}`, type: 'button', text: STATUS_LABEL[to] });
    b.addEventListener('click', async () => {
      let reason = null;
      if (to === 'lost') {
        reason = await ask({ title: `Mark ${lead.business_name} as lost?`, body: 'Follow-ups to this business stop straight away.', confirm: 'Mark as lost', danger: true, input: { label: 'Reason', placeholder: 'For example, already has a booking system', required: true } });
        if (!reason) return;
      }
      await withBusy(b, async () => {
        await src.act('move_lead', { lead_id: lead.id, to, ...(reason ? { reason } : {}) });
        lead.status = to;
        if (reason) lead.lost_reason = reason;
        toast(`${lead.business_name} moved to ${STATUS_LABEL[to]}.`);
        invalidate();
        drawer.close(); redraw();
      });
    });
    return b;
  }));

  const dnc = lead.do_not_contact ? null : h('button', { class: 'btn btn-sm btn-danger-quiet', type: 'button', text: 'Never contact again' });
  dnc?.addEventListener('click', async () => {
    const ok = await ask({ title: `Stop all contact with ${lead.business_name}?`, body: 'They\'re added to your do-not-contact list and won\'t be messaged again, even if found in a future search.', confirm: 'Stop contact', danger: true });
    if (!ok) return;
    await withBusy(dnc, async () => {
      await src.act('mark_do_not_contact', { lead_id: lead.id });
      lead.do_not_contact = true;
      toast(`${lead.business_name} won't be contacted again.`);
      drawer.close(); redraw();
    });
  });

  const list = (items) => (Array.isArray(items) && items.length ? h('ul', {}, items.map((x) => h('li', { text: x }))) : null);
  const section = (title, node) => (node ? h('section', {}, h('h3', { text: title }), node) : null);

  drawer.replaceChildren(h('div', { class: 'drawer-inner' },
    h('header', { class: 'drawer-head' },
      h('div', {}, h('h2', { id: 'drawer-title', text: lead.business_name }),
        h('p', { text: [titleCase(lead.niche || lead.category), lead.city].filter(Boolean).join(', ') })),
      close),
    h('div', { class: 'drawer-body' },
      h('div', { class: 'moves' }, statusPill(lead.status), scoreEl(lead.score), lead.do_not_contact ? h('span', { class: 'pill pill-red', text: 'Do not contact' }) : null),
      h('dl', { class: 'facts' },
        fact('Website', web ? h('a', { href: web, target: '_blank', rel: 'noopener noreferrer', text: new URL(web).hostname.replace(/^www\./, '') }) : null),
        fact('Phone', tel ? h('a', { href: tel, text: lead.phone }) : null),
        fact('Email', lead.email ? document.createTextNode(lead.email) : null),
        fact('Google rating', lead.rating ? document.createTextNode(`${Number(lead.rating).toFixed(1)} from ${int(lead.review_count)} reviews`) : null),
        fact('Lost because', lead.status === 'lost' && lead.lost_reason ? document.createTextNode(lead.lost_reason) : null)),
      section('Why they fit', lead.qualification_summary ? h('p', { text: lead.qualification_summary }) : null),
      section('Signals', list(lead.reasons)),
      section('What\'s costing them bookings', list(lead.pain_points)),
      section('What to offer', lead.recommended_offer ? h('p', { text: lead.recommended_offer }) : null),
      (MOVES[lead.status] || []).length ? section('Move to', moves) : null),
    dnc ? h('footer', { class: 'drawer-foot' }, dnc) : null));
  drawer.showModal();
  close.focus();
}

/* ------------------------------------------------------------------ Approvals */

async function renderApprovals(current) {
  loading(3);
  const drafts = await src.outreach();
  if (!current()) return;
  const paused = !DEMO && state.org && state.org.outreach_enabled === false;

  if (!drafts.length) {
    view.replaceChildren(empty('Nothing to approve', 'New first emails and follow-ups appear here for you to check before anything is sent.', h('a', { class: 'btn btn-quiet', href: '#pipeline', text: 'Go to the pipeline' })));
    return;
  }

  const selected = new Set();
  const bulk = h('button', { class: 'btn btn-sm btn-primary', type: 'button', text: 'Approve selected', disabled: true });
  const updateBulk = () => { bulk.disabled = !selected.size; bulk.textContent = selected.size ? `Approve ${selected.size} selected` : 'Approve selected'; };
  const cards = new Map();

  const removeCard = (idv, { quiet = false } = {}) => {
    cards.get(idv)?.remove(); cards.delete(idv); selected.delete(idv); updateBulk();
    if (!quiet) { invalidate(); if (!cards.size) route(); }
  };

  const stack = h('div', { class: 'stack' }, drafts.map((d) => {
    const subject = h('input', { class: 'input', id: `s-${d.id}`, value: d.subject || '', maxlength: '150' });
    const body = h('textarea', { class: 'textarea', id: `b-${d.id}`, maxlength: '2000', rows: '9' });
    body.value = d.body || '';
    const edited = () => subject.value !== (d.subject || '') || body.value !== (d.body || '');
    const check = h('input', { class: 'check', type: 'checkbox', 'aria-label': `Select the message to ${d.business_name}` });
    check.addEventListener('change', () => { if (check.checked) selected.add(d.id); else selected.delete(d.id); updateBulk(); });

    const approve = h('button', { class: 'btn btn-sm btn-primary', type: 'button', text: 'Approve' });
    const reject = h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text: 'Don\'t send' });
    approve.addEventListener('click', () => withBusy(approve, async () => {
      const s = subject.value.trim(), b = body.value.trim();
      if (s.length < 3) throw new Error('Give the email a subject of at least 3 characters.');
      if (b.length < 10) throw new Error('The message is too short to send.');
      await src.act('approve_message', edited() ? { message_id: d.id, subject: s, body: b } : { message_id: d.id });
      toast(`Approved. The email to ${d.business_name} will go out in your next sending window.`);
      removeCard(d.id);
    }));
    reject.addEventListener('click', async () => {
      const reason = await ask({ title: `Don't send this email to ${d.business_name}?`, body: 'The draft is discarded. You can write a new one from the pipeline later.', confirm: 'Discard draft', danger: true, input: { label: 'Reason (optional)', placeholder: 'For example, wrong contact' } });
      if (reason === false) return;
      await withBusy(reject, async () => {
        await src.act('reject_message', { message_id: d.id, ...(reason ? { reason } : {}) });
        toast(`Draft to ${d.business_name} discarded.`);
        removeCard(d.id);
      });
    });

    const card = h('article', { class: 'panel msg', 'aria-labelledby': `t-${d.id}` },
      h('div', { class: 'msg-head' }, check,
        h('div', {}, h('b', { id: `t-${d.id}`, text: d.business_name }), h('p', { text: `To ${d.to_address || 'no address yet'}, ${d.step > 1 ? `follow-up ${d.step - 1}` : 'first email'}` })),
        scoreEl(d.score)),
      h('div', {}, h('label', { class: 'label', for: `s-${d.id}`, text: 'Subject' }), subject),
      h('div', {}, h('label', { class: 'label', for: `b-${d.id}`, text: 'Message' }), body),
      h('div', { class: 'msg-actions' }, approve, reject, h('span', { class: 'faint', text: `Drafted ${ago(d.created_at)}` })));
    cards.set(d.id, card);
    return card;
  }));

  bulk.addEventListener('click', async () => {
    const ids = [...selected];
    if (!ids.length) return;
    let done = 0;
    await withBusy(bulk, async () => {
      try {
        const plain = [];
        for (const idv of ids) {
          const card = cards.get(idv);
          const d = drafts.find((x) => x.id === idv);
          const s = $(`#s-${CSS.escape(idv)}`, card).value.trim(), b = $(`#b-${CSS.escape(idv)}`, card).value.trim();
          if (s !== (d.subject || '') || b !== (d.body || '')) {
            if (s.length < 3 || b.length < 10) throw new Error(`The email to ${d.business_name} needs a subject and a longer message.`);
            await src.act('approve_message', { message_id: idv, subject: s, body: b });
            removeCard(idv, { quiet: true }); done++;
          } else plain.push(idv);
        }
        if (plain.length) { await src.act('approve_messages', { message_ids: plain }); plain.forEach((x) => removeCard(x, { quiet: true })); done += plain.length; }
      } finally {
        if (done) toast(`${done} email${done === 1 ? '' : 's'} approved.`);
      }
    });
    updateBulk();
    if (done) { invalidate(); if (!cards.size) route(); }
  });

  tools.append(bulk);
  view.replaceChildren(
    h('div', { class: 'intro' }, h('p', { text: paused
      ? 'Sending is switched off for your organisation, so approved emails wait until it\'s turned on. Edit anything before you approve it.'
      : 'Read each email, edit anything you like, then approve it. Only approved emails are ever sent.' })),
    stack);
}

/* ------------------------------------------------------------------ Replies */

async function renderReplies(current) {
  loading(3);
  const items = await src.replies();
  if (!current()) return;
  if (!items.length) {
    view.replaceChildren(empty('No replies waiting', 'When a business answers one of your emails, it lands here with a suggested response for you to check.'));
    return;
  }
  const stack = h('div', { class: 'stack' }, items.map((r) => {
    const [label, tone] = REPLY_LABEL[r.classification] || [titleCase(r.classification || ''), ''];
    const card = h('article', { class: 'panel msg', 'aria-labelledby': `r-${r.id}` });
    const done = (msg) => { toast(msg); card.remove(); invalidate(); if (!stack.children.length) route(); };

    const handled = h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text: 'Mark as handled' });
    handled.addEventListener('click', () => withBusy(handled, async () => { await src.act('mark_reply_handled', { reply_id: r.id }); done(`Reply from ${r.business_name || r.from_address} marked as handled.`); }));

    let responseBlock = null;
    if (r.response_status === 'pending_approval' && r.suggested_response) {
      const text = h('textarea', { class: 'textarea', id: `rr-${r.id}`, maxlength: '2000', rows: '8' });
      text.value = r.suggested_response;
      const send = h('button', { class: 'btn btn-sm btn-primary', type: 'button', text: 'Approve reply' });
      const discard = h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text: 'Discard suggestion' });
      send.addEventListener('click', () => withBusy(send, async () => {
        const b = text.value.trim();
        if (b.length < 10) throw new Error('The reply is too short to send.');
        await src.act('approve_reply_response', b !== r.suggested_response ? { reply_id: r.id, body: b } : { reply_id: r.id });
        toast(`Reply to ${r.business_name} approved.`);
        responseBlock.replaceChildren(h('span', { class: 'pill pill-mint', text: 'Reply approved' }));
      }));
      discard.addEventListener('click', () => withBusy(discard, async () => {
        await src.act('reject_reply_response', { reply_id: r.id });
        responseBlock.replaceChildren(h('span', { class: 'pill', text: 'Suggestion discarded' }));
      }));
      responseBlock = h('div', {}, h('label', { class: 'label', for: `rr-${r.id}`, text: 'Suggested reply' }), text, h('div', { class: 'msg-actions' }, send, discard));
      responseBlock.lastChild.style.marginTop = '10px';
    } else if (r.response_status === 'approved' || r.response_status === 'sent') {
      responseBlock = h('div', {}, h('span', { class: 'pill pill-mint', text: r.response_status === 'sent' ? 'Reply sent' : 'Reply approved' }));
    }

    card.append(...[
      h('div', { class: 'msg-head' },
        h('div', {}, h('b', { id: `r-${r.id}`, text: r.business_name || r.from_address || 'Unknown sender' }),
          h('p', { text: `${r.from_address || ''}${r.from_address ? ', ' : ''}${ago(r.received_at)}` })),
        h('span', { class: `pill ${tone}`, text: label })),
      r.summary ? h('p', { class: 'summary', text: r.summary }) : null,
      r.body_preview ? h('blockquote', { class: 'quote', text: r.body_preview }) : null,
      responseBlock,
      h('div', { class: 'msg-actions' }, handled)].filter(Boolean));
    return card;
  }));
  view.replaceChildren(h('div', { class: 'intro' }, h('p', { text: 'Each reply is sorted for you. Check the suggested response, change anything, then approve it.' })), stack);
}

/* ------------------------------------------------------------------ Meetings */

async function renderMeetings(current) {
  loading(2);
  const items = await src.meetings();
  if (!current()) return;
  if (!items.length) {
    view.replaceChildren(empty('No meetings yet', 'Meetings booked from your demo pages, or added by your team, show up here and in your calendar.'));
    return;
  }
  const now = Date.now();
  const end = (m) => Date.parse(m.ends_at || m.starts_at);
  const upcoming = items.filter((m) => end(m) >= now).sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
  const earlier = items.filter((m) => end(m) < now).sort((a, b) => Date.parse(b.starts_at) - Date.parse(a.starts_at));
  const groups = new Map();
  for (const m of [...upcoming, ...earlier]) {
    const k = dayKey(new Date(m.starts_at));
    if (!groups.has(k)) groups.set(k, { label: dayLabel(m.starts_at), items: [] });
    groups.get(k).items.push(m);
  }
  const blocks = [...groups.values()].map((g) => h('section', { class: 'day', 'aria-label': g.label },
    h('h2', { text: g.label }),
    h('div', { class: 'panel' }, g.items.map((m) => {
      const ended = Date.parse(m.ends_at || m.starts_at) < Date.now();
      const actions = h('div', { class: 'meeting-actions' });
      if (m.status === 'scheduled' && ended) {
        for (const [st, text] of [['completed', 'It happened'], ['no_show', 'No-show']]) {
          const b = h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text });
          b.addEventListener('click', () => withBusy(b, async () => {
            await src.act('set_meeting_outcome', { meeting_id: m.id, status: st });
            m.status = st;
            actions.replaceChildren(h('span', { class: `pill ${st === 'completed' ? 'pill-mint' : 'pill-amber'}`, text: st === 'completed' ? 'Completed' : 'No-show' }));
            toast('Meeting updated.');
          }));
          actions.append(b);
        }
      } else if (m.status === 'completed') actions.append(h('span', { class: 'pill pill-mint', text: 'Completed' }));
      else if (m.status === 'no_show') actions.append(h('span', { class: 'pill pill-amber', text: 'No-show' }));
      else {
        const join = safeUrl(m.meeting_url);
        actions.append(h('span', { class: 'pill pill-plain', text: CHANNEL[m.channel] || m.channel || '' }));
        if (join) actions.append(h('a', { class: 'btn btn-sm btn-quiet', href: join, target: '_blank', rel: 'noopener noreferrer', text: 'Join' }));
      }
      return h('div', { class: 'meeting' },
        h('div', { class: 'when' }, h('b', { text: time(m.starts_at) }), h('span', { text: m.ends_at ? `until ${time(m.ends_at)}` : '' })),
        h('div', { class: 'what' }, h('b', { text: m.business_name || m.title }), h('p', { text: [m.title, m.attendee_name ? `with ${m.attendee_name}` : null].filter(Boolean).join(' ') })),
        actions);
    }))));
  view.replaceChildren(...blocks);
}

/* ------------------------------------------------------------------ Clients */

async function renderClients(current) {
  loading(2);
  const items = await src.clients();
  if (!current()) return;
  if (!items.length) {
    view.replaceChildren(empty('No clients yet', 'When you mark a lead as won and convert it, the new client and their setup checklist appear here.', h('a', { class: 'btn btn-quiet', href: '#pipeline', text: 'Go to the pipeline' })));
    return;
  }
  const mrr = items.filter((c) => c.status === 'active').reduce((s, c) => s + (Number(c.monthly_fee) || 0), 0);
  tools.append(h('span', { class: 'pill pill-mint pill-plain', text: `${money(mrr)} a month from active clients` }));
  const table = h('table', { class: 'table' },
    h('thead', {}, h('tr', {},
      h('th', { scope: 'col', text: 'Client' }), h('th', { scope: 'col', text: 'Status' }), h('th', { scope: 'col', text: 'Setup' }),
      h('th', { scope: 'col', text: 'Plan' }), h('th', { scope: 'col', class: 'r', text: 'Monthly' }), h('th', { scope: 'col', class: 'r', text: 'Won' }))),
    h('tbody', {}, items.map((c) => {
      const total = Number(c.tasks_total) || 0, doneN = Number(c.tasks_done) || 0;
      const pct = total ? Math.round((doneN / total) * 100) : 0;
      const fill = h('div', { class: 'progress-fill' }); fill.style.width = `${pct}%`;
      return h('tr', {},
        h('td', { class: 'client-name' }, h('b', { text: c.business_name }), h('span', { text: [c.contact_name, titleCase(c.industry)].filter(Boolean).join(', ') })),
        h('td', {}, h('span', { class: `pill ${CLIENT_TONE[c.status] || ''}`, text: titleCase(c.status) }),
          Number(c.tasks_overdue) > 0 ? h('div', { class: 'faint', text: `${c.tasks_overdue} overdue` }) : null),
        h('td', {}, total ? h('div', { class: `progress${pct === 100 ? ' is-complete' : ''}`, role: 'img', 'aria-label': `${doneN} of ${total} setup tasks done` },
          h('div', { class: 'progress-track' }, fill), h('span', { text: `${doneN}/${total}` })) : h('span', { class: 'faint', text: '—' })),
        h('td', { text: c.plan || '—' }),
        h('td', { class: 'r', text: c.monthly_fee ? money(c.monthly_fee) : '—' }),
        h('td', { class: 'r', text: c.won_at ? fmt({ day: 'numeric', month: 'short' }).format(new Date(c.won_at)) : '—' }));
    })));
  view.replaceChildren(h('div', { class: 'panel' }, h('div', { class: 'panel-body table-wrap' }, table)));
}

/* ------------------------------------------------------------------ Find leads */

const RUN_STATUS = { queued: ['Waiting', 'pill-amber'], running: ['Searching', 'pill-blue'], completed: ['Done', 'pill-mint'],
  failed: ['Didn\'t work', 'pill-red'], cancelled: ['Cancelled', ''] };
const COUNTRY_NAME = Object.fromEntries(COUNTRIES);
const PREFS_KEY = 'simplybooked.search';
const ICON_SEARCH = 'M10.5 17.5a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM15.6 15.6L20 20';
const ICON_PIN = 'M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11zM12 12.2a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4z';
const ICON_ALERT = 'M12 4l9 16H3zM12 10v4.5M12 17.2v.1';
const ICON_FILE = 'M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20zM14 3.5V8h4M9.5 13h5M9.5 16.5h5';
const ICON_INFO = 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v5.5M12 7.8v.1';
const tradeLabel = (niche) => TRADES.find((t) => t.niche.toLowerCase() === String(niche || '').toLowerCase())?.label || titleCase(niche || '');

/** Plain-English reason for a failed search (codes come from the Lead Finder workflow). */
function runProblem(code) {
  const e = String(code || '');
  if (e.startsWith('unsupported_niche')) return 'The map search doesn\'t know this trade. Pick one from the list.';
  if (e === 'city_or_region_required') return 'Add a town or region and search again.';
  if (e === 'invalid_country') return 'The country wasn\'t recognised.';
  if (/^overpass_http_(429|502|503|504|none)$/.test(e)) return 'The map service was busy. Search again in a few minutes.';
  if (e.startsWith('overpass_http_')) return 'The map service didn\'t answer properly. Search again later.';
  if (e.startsWith('provider_not_configured')) return 'This search source isn\'t connected yet.';
  if (e === 'source_inactive') return 'The search source was switched off before it ran.';
  if (e === 'max_attempts') return 'It failed three times in a row, so it was stopped.';
  if (e === 'ingest_failed') return 'Businesses were found but couldn\'t be saved. Search again.';
  return 'Something went wrong with this search. Search again.';
}

/* --- CSV import: read a spreadsheet export into lead items (nothing is sent until the person confirms) */

const CSV_COLUMNS = {
  business_name: ['business name', 'business', 'name', 'company', 'company name', 'organisation', 'organization', 'practice', 'practice name'],
  website: ['website', 'web', 'url', 'site', 'website url', 'domain', 'web address'],
  phone: ['phone', 'telephone', 'tel', 'phone number', 'telephone number', 'mobile', 'contact number'],
  email: ['email', 'e mail', 'email address'],
  city: ['town', 'city', 'town city', 'locality'],
  region: ['region', 'county', 'state', 'province'],
  address: ['address', 'street address', 'full address', 'address line 1'],
  niche: ['trade', 'niche', 'industry', 'category', 'type', 'business type', 'sector'],
  country_code: ['country', 'country code'],
};
const CSV_LIMITS = { business_name: 200, website: 500, phone: 40, email: 254, city: 80, region: 80, address: 300, niche: 80 };
const UK_NAMES = new Set(['united kingdom', 'uk', 'great britain', 'britain', 'england', 'scotland', 'wales', 'northern ireland', 'gb']);
const MAX_IMPORT_ROWS = 1000;

function parseCsv(text) {
  const src = text.replace(/^﻿/, '');
  const first = src.slice(0, src.search(/\r?\n|$/));
  const count = (ch) => { let n = 0, q = false; for (const c of first) { if (c === '"') q = !q; else if (c === ch && !q) n++; } return n; };
  const delim = [',', ';', '\t'].reduce((best, ch) => (count(ch) > count(best) ? ch : best), ',');
  const rows = []; let row = [], cur = '', q = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (q) {
      if (c === '"' && src[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') q = false; else cur += c;
    } else if (c === '"') q = true;
    else if (c === delim) { row.push(cur); cur = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && src[i + 1] === '\n') i++; row.push(cur); rows.push(row); row = []; cur = ''; }
    else cur += c;
  }
  if (cur !== '' || row.length) { row.push(cur); rows.push(row); }
  return rows.filter((r) => r.some((v) => v.trim() !== ''));
}

/** Returns { items, skipped, columns, error } from CSV text. */
function csvToLeads(text) {
  const rows = parseCsv(text);
  if (rows.length < 2) return { error: 'The file needs a header row and at least one business.' };
  const norm = (s) => s.toLowerCase().replace(/[_\-/]+/g, ' ').replace(/\s+/g, ' ').trim();
  const head = rows[0].map(norm);
  const index = {};
  for (const [field, names] of Object.entries(CSV_COLUMNS)) {
    const i = head.findIndex((x) => names.includes(x));
    if (i >= 0) index[field] = i;
  }
  if (index.business_name === undefined) return { error: 'We couldn\'t find a business name column. Name the column "Business name".' };
  const body = rows.slice(1);
  if (body.length > MAX_IMPORT_ROWS) return { error: `Up to ${int(MAX_IMPORT_ROWS)} businesses per file. This one has ${int(body.length)}. Split it and import the parts one after another.` };
  const items = []; let skipped = 0;
  for (const r of body) {
    const it = {};
    for (const [field, i] of Object.entries(index)) {
      const v = String(r[i] ?? '').trim();
      if (!v) continue;
      if (field === 'country_code') {
        const c = v.toLowerCase();
        if (/^[a-z]{2}$/.test(c)) it.country_code = c === 'uk' ? 'GB' : c.toUpperCase();
        else if (UK_NAMES.has(c)) it.country_code = 'GB';
        else { const hit = COUNTRIES.find(([, name]) => name.toLowerCase() === c); if (hit) it.country_code = hit[0]; }
        continue;
      }
      it[field] = v.slice(0, CSV_LIMITS[field]);
    }
    if (!it.business_name) { skipped++; continue; }
    items.push(it);
  }
  return { items, skipped, columns: Object.keys(index) };
}

async function renderFind(current) {
  loading(2);
  const [sources, cap, firstRuns] = await Promise.all([src.searchSources(), src.searchCap().catch(() => 20), src.searchRuns()]);
  if (!current()) return;
  let runs = firstRuns;
  const canWrite = DEMO || ['member', 'admin', 'owner'].includes(state.profile?.role);
  const source = sources.find((x) => x.key === 'osm') || sources[0] || null;
  let prefs = {};
  try { prefs = JSON.parse(localStorage.getItem(PREFS_KEY) || '{}') || {}; } catch { prefs = {}; }

  /* --- new search form */
  const opt = (value, text, sel) => h('option', { value, text, selected: sel });
  const trade = h('select', { class: 'select', id: 'f-trade', required: true },
    opt('', 'Choose a trade', !prefs.niche), TRADES.map((t) => opt(t.niche, t.label, t.niche === prefs.niche)));
  const city = h('input', { class: 'input', id: 'f-city', required: true, minlength: '2', maxlength: '80', autocomplete: 'off', placeholder: 'For example, Bristol', value: prefs.city || '' });
  const region = h('input', { class: 'input', id: 'f-region', maxlength: '80', autocomplete: 'off', placeholder: 'Optional', value: prefs.region || '' });
  const country = h('select', { class: 'select', id: 'f-country' }, COUNTRIES.map(([c, n]) => opt(c, n, c === (prefs.country || 'GB'))));
  const howMany = h('select', { class: 'select', id: 'f-max' }, [10, 20, 40, 60].map((n) => opt(String(n), `Up to ${n}`, n === (prefs.max || 20))));
  const go = h('button', { class: 'btn btn-primary', type: 'submit' }, svg(ICON_SEARCH, 18), 'Search');
  const field = (label, input, hint) => h('div', { class: 'field' }, h('label', { class: 'label', for: input.id }, label, hint ? h('span', { class: 'field-hint', text: ` ${hint}` }) : null), input);

  const todayKey = dayKey(new Date());
  const usedToday = () => runs.filter((r) => dayKey(new Date(r.created_at)) === todayKey).length;
  const meterFill = h('span', { class: 'meter-fill' });
  const meterText = h('span', { class: 'meter-text' });
  const meter = h('div', { class: 'meter', role: 'img' }, h('span', { class: 'meter-track' }, meterFill), meterText);
  const drawMeter = () => {
    const used = Math.min(usedToday(), cap);
    meterFill.style.width = `${Math.round((used / cap) * 100)}%`;
    meterText.textContent = `${used} of ${cap} searches today`;
    meter.setAttribute('aria-label', `${used} of ${cap} searches used today`);
    meter.classList.toggle('is-full', used >= cap);
  };

  const form = h('form', { class: 'panel find', 'aria-labelledby': 'find-title', novalidate: true },
    h('div', { class: 'find-head' },
      h('div', {}, h('h2', { id: 'find-title', text: 'Search a town' }),
        h('p', { text: 'We look up every business of that trade on the map and add the new ones to your pipeline.' })),
      meter),
    h('div', { class: 'find-grid' },
      field('Trade', trade), field('Town or city', city), field('County or region', region, '(optional)'),
      field('Country', country), field('How many', howMany), h('div', { class: 'field field-go' }, go)),
    h('p', { class: 'find-note' }, svg(ICON_INFO, 18),
      h('span', { text: 'Businesses come from OpenStreetMap, the open map of the world. New ones arrive as New lead and are scored for fit automatically. Nobody is contacted until you approve an email.' })));

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    for (const el of [trade, city]) el.removeAttribute('aria-invalid');
    const c = city.value.trim(), r = region.value.trim();
    const bad = !trade.value ? trade : c.length < 2 ? city : null;
    if (bad) { bad.setAttribute('aria-invalid', 'true'); bad.focus(); toast(bad === trade ? 'Choose a trade to search for.' : 'Type the town or city to search.', true); return; }
    withBusy(go, async () => {
      const params = { source_key: source.key, niche: trade.value, city: c, country: country.value, max_results: Number(howMany.value), ...(r ? { region: r } : {}) };
      let res;
      try { res = await src.act('queue_search_run', params); }
      catch (err) {
        if (err?.code === 'daily_search_cap') throw new Error(`You've used all ${cap} searches for today. More are available tomorrow.`);
        throw err;
      }
      try { localStorage.setItem(PREFS_KEY, JSON.stringify({ niche: trade.value, city: c, region: r, country: country.value, max: Number(howMany.value) })); } catch { /* ignore */ }
      toast(res?.duplicate ? `${tradeLabel(trade.value)} in ${c} is already waiting to run.` : `Searching for ${tradeLabel(trade.value).toLowerCase()} in ${c}. Results appear below in a few minutes.`);
      await refresh();
    });
  });
  if (!canWrite || !source) {
    for (const el of form.querySelectorAll('select, input, button')) el.disabled = true;
  }

  /* --- recent searches */
  const runsBody = h('div', { class: 'panel-body' });
  const runsPanel = h('section', { class: 'panel runs-panel', 'aria-labelledby': 'runs-title' },
    h('div', { class: 'panel-head' }, h('h2', { id: 'runs-title', text: 'Recent searches' }), h('span', { class: 'muted js-runs-count' })),
    runsBody);

  const runRow = (r) => {
    const [label, tone] = RUN_STATUS[r.status] || [titleCase(r.status), ''];
    const place = [r.city, r.region].filter(Boolean).join(', ');
    const where = [COUNTRY_NAME[r.country_code] || r.country_code, `up to ${r.max_results}`, ago(r.created_at)].join(' · ');
    let result;
    if (r.status === 'completed') {
      result = r.found_count ? h('div', { class: 'run-stats' },
        h('span', {}, h('b', { text: int(r.found_count) }), ' found'),
        h('span', { class: 'is-new' }, h('b', { text: int(r.new_count) }), ' new'),
        r.dup_count ? h('span', {}, h('b', { text: int(r.dup_count) }), ' already known') : null)
        : h('p', { class: 'run-text', text: 'No businesses of this trade on the map there. Try a bigger town or a nearby one.' });
    } else if (r.status === 'failed') result = h('p', { class: 'run-text is-bad', text: runProblem(r.error) });
    else if (r.status === 'running') result = h('p', { class: 'run-text', text: 'Looking on the map now.' });
    else if (r.status === 'queued') result = h('p', { class: 'run-text', text: 'Starts within five minutes.' });
    else result = h('p', { class: 'run-text', text: 'Stopped before it ran.' });

    const open = r.status === 'completed' && r.new_count > 0
      ? h('a', { class: 'btn btn-sm btn-quiet', href: '#pipeline', text: 'View', 'aria-label': `View ${tradeLabel(r.niche).toLowerCase()} in ${place} in the pipeline`,
        onClick: () => { state.leadFilter = r.city || r.region || ''; } })
      : null;
    const active = r.status === 'queued' || r.status === 'running';
    return h('li', { class: `run is-${r.status}${active ? ' is-active' : ''}` },
      h('span', { class: 'run-icon', 'aria-hidden': 'true' }, svg(r.status === 'failed' ? ICON_ALERT : ICON_PIN, 20)),
      h('div', { class: 'run-what' }, h('b', { text: `${tradeLabel(r.niche)} in ${place || 'the whole country'}` }), h('span', { text: where })),
      h('div', { class: 'run-result' }, result),
      h('div', { class: 'run-side' }, h('span', { class: `pill ${tone}`, text: label }), open));
  };

  const drawRuns = () => {
    drawMeter();
    $('.js-runs-count', runsPanel).textContent = runs.length ? `${int(runs.length)} most recent` : '';
    if (!runs.length) {
      runsBody.replaceChildren(h('div', { class: 'runs-empty' }, svg(ICON_PIN, 28), h('p', { text: 'Your searches show up here, with how many new businesses each one found.' })));
      return;
    }
    const stale = !DEMO && runs.some((r) => r.status === 'queued' && Date.now() - Date.parse(r.created_at) > 15 * 60e3);
    runsBody.replaceChildren(...[
      stale ? h('div', { class: 'notice', role: 'status' }, svg(ICON_ALERT, 18),
        h('p', { text: 'Searches are waiting to be picked up. The lead finder automation isn\'t running yet; they\'ll start on their own as soon as it is.' })) : null,
      h('ul', { class: 'runs', role: 'list' }, runs.map(runRow))].filter(Boolean));
  };

  let timer = 0;
  const refresh = async () => {
    clearTimeout(timer);
    if (!current()) return;
    try { runs = await src.searchRuns(); } catch (err) { if (err?.code === 'unauthenticated') { location.replace('/login.html'); return; } }
    if (!current()) return;
    drawRuns();
    if (runs.some((r) => r.status === 'queued' || r.status === 'running')) timer = setTimeout(refresh, DEMO ? 2000 : 20000);
  };

  /* --- bring your own list */
  const file = h('input', { class: 'sr-only', type: 'file', id: 'f-csv', accept: '.csv,text/csv' });
  const drop = h('label', { class: 'drop', for: 'f-csv' }, h('span', { class: 'drop-icon', 'aria-hidden': 'true' }, svg(ICON_FILE, 22)),
    h('span', {}, h('b', { text: 'Choose a CSV file' }), h('span', { text: 'or drop it here. Up to 1,000 businesses.' })));
  const preview = h('div', { class: 'import-preview', hidden: true });
  const importPanel = h('section', { class: 'panel import', 'aria-labelledby': 'import-title' },
    h('div', { class: 'panel-head' }, h('h2', { id: 'import-title', text: 'Bring your own list' })),
    h('div', { class: 'panel-body' },
      h('p', { class: 'muted', text: 'Export a spreadsheet as CSV. We read the business name (required), website, phone, email, town, region, address and trade. Duplicates are merged with what you already have.' }),
      h('div', { class: 'drop-wrap' }, file, drop), preview));

  const showFile = async (f) => {
    if (!f) return;
    if (!/\.csv$/i.test(f.name) && f.type !== 'text/csv') { toast('Choose a .csv file. In Excel or Google Sheets, use Download or Save as CSV.', true); return; }
    if (f.size > 2 * 1024 * 1024) { toast('That file is over 2 MB. Split it into smaller files.', true); return; }
    let parsed;
    try { parsed = csvToLeads(await f.text()); } catch { parsed = { error: 'We couldn\'t read that file.' }; }
    if (!current()) return;
    if (parsed.error) { preview.hidden = false; preview.replaceChildren(h('p', { class: 'run-text is-bad', role: 'alert', text: parsed.error })); return; }
    const n = parsed.items.length;
    const go2 = h('button', { class: 'btn btn-sm btn-primary', type: 'button', text: `Import ${int(n)} business${n === 1 ? '' : 'es'}`, disabled: !n || !canWrite });
    const cancel = h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text: 'Cancel', onClick: () => { preview.hidden = true; preview.replaceChildren(); file.value = ''; } });
    const progress = h('p', { class: 'muted', role: 'status' });
    preview.hidden = false;
    preview.replaceChildren(
      h('p', {}, h('b', { text: f.name }), `: ${int(n)} business${n === 1 ? '' : 'es'} ready to import.`,
        parsed.skipped ? ` ${int(parsed.skipped)} row${parsed.skipped === 1 ? '' : 's'} without a business name will be skipped.` : ''),
      h('p', { class: 'faint', text: `Columns found: ${parsed.columns.map((c) => c.replace('_code', '').replace('_', ' ')).join(', ')}` }),
      h('div', { class: 'msg-actions' }, go2, cancel), progress);
    go2.addEventListener('click', () => withBusy(go2, async () => {
      cancel.disabled = true;
      const total = { created: 0, merged: 0, duplicate: 0, suppressed: 0, invalid: 0, limited: 0 };
      let sent = 0;
      try {
        for (let i = 0; i < n; i += 200) {
          progress.textContent = `Importing ${int(Math.min(i + 200, n))} of ${int(n)}…`;
          const res = await src.act('import_leads', { items: parsed.items.slice(i, i + 200), source_key: 'csv' });
          for (const k of Object.keys(total)) total[k] += Number(res?.[k]) || 0;
          sent = Math.min(i + 200, n);
        }
      } catch (err) {
        if (sent) err.message = `${int(sent)} of ${int(n)} were imported before this stopped: ${err.message}`;
        progress.textContent = '';
        cancel.disabled = false;
        throw err;
      }
      const lines = [
        `${int(total.created)} new business${total.created === 1 ? '' : 'es'} added to your pipeline as New lead.`,
        total.merged + total.duplicate ? `${int(total.merged + total.duplicate)} were already there${total.merged ? ` (${int(total.merged)} updated with new details)` : ''}.` : null,
        total.suppressed ? `${int(total.suppressed)} are on your do-not-contact list and were left out.` : null,
        total.limited ? `${int(total.limited)} were over today's limit for imports and weren't added. Import them again tomorrow.` : null,
        total.invalid ? `${int(total.invalid)} couldn't be read.` : null,
      ].filter(Boolean);
      file.value = '';
      preview.replaceChildren(h('div', { class: 'import-done', role: 'status' }, svg(ICON_CHECK, 20), h('div', {}, lines.map((t) => h('p', { text: t })))),
        total.created ? h('a', { class: 'btn btn-sm btn-quiet', href: '#pipeline', text: 'Open the pipeline', onClick: () => { state.leadFilter = ''; } }) : null);
      toast(`${int(total.created)} new lead${total.created === 1 ? '' : 's'} imported.`);
      invalidate();
    }));
  };
  file.addEventListener('change', () => showFile(file.files?.[0]));
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('is-over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('is-over'));
  drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('is-over'); if (canWrite) showFile(e.dataTransfer?.files?.[0]); });
  if (!canWrite) { file.disabled = true; drop.classList.add('is-disabled'); }

  const blocked = !source
    ? h('div', { class: 'notice', role: 'status' }, svg(ICON_ALERT, 18), h('p', { text: 'Map search isn\'t switched on for your organisation yet. Ask the account owner to turn on the OpenStreetMap source.' }))
    : !canWrite ? h('div', { class: 'notice', role: 'status' }, svg(ICON_INFO, 18), h('p', { text: 'Your role can view searches but not start them or import lists. Ask the account owner if you need to.' }))
      : null;

  view.replaceChildren(h('div', { class: 'find-wrap' }, blocked, form, h('div', { class: 'find-cols' }, runsPanel, importPanel)));
  drawRuns();
  if (runs.some((r) => r.status === 'queued' || r.status === 'running')) timer = setTimeout(refresh, DEMO ? 2000 : 20000);
}

/* ================================================================== Front desk */

const STAFF_TONES = ['t1', 't2', 't3', 't4'];
const toneOf = (i) => (i >= 0 && i < 4 ? STAFF_TONES[i] : 't0'); // a fifth person onwards shares a neutral tone (never a made-up hue)
const CHANNEL_SAID = { phone: 'Booked by phone', web: 'Booked on the website', text: 'Booked by text', team: 'Added by the team' };
const SERIES = [['phone', 'Phone'], ['web', 'Website'], ['text', 'Text'], ['team', 'Team']];
const BOOKING_STATUS = { booked: ['Booked', 'pill-blue'], confirmed: ['Confirmed', 'pill-mint'], completed: ['Completed', ''], no_show: ['No-show', 'pill-amber'] };

const ICON = {
  calendar: 'M5 6.5h14a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7.5a1 1 0 0 1 1-1zM4 10.5h16M8.5 4v4M15.5 4v4',
  spark: 'M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1-5.1-1.9 5.1-1.9zM18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z',
  pound: 'M16.5 7.2C16 5.6 14.6 4.5 12.7 4.5 10.4 4.5 9 6.1 9 8.4c0 2.6 1.3 4.4 1.3 6.6 0 1.9-1 3.1-2.8 4.5h10M7 12.2h7',
  phone: 'M6.6 4.5h2.6l1.4 3.6-1.8 1.2a9.5 9.5 0 0 0 5.9 5.9l1.2-1.8 3.6 1.4v2.6a1.5 1.5 0 0 1-1.6 1.5C10.6 18.4 5.6 13.4 5.1 6.1a1.5 1.5 0 0 1 1.5-1.6z',
  web: 'M12 20.5a8.5 8.5 0 1 0 0-17 8.5 8.5 0 0 0 0 17zM3.5 12h17M12 3.5c2.3 2.4 3.4 5.2 3.4 8.5s-1.1 6.1-3.4 8.5c-2.3-2.4-3.4-5.2-3.4-8.5s1.1-6.1 3.4-8.5z',
  left: 'M14.5 6l-6 6 6 6', right: 'M9.5 6l6 6-6 6',
};

/* ---------- dates in the business's own time zone ---------- */
function tzParts(d) {
  return Object.fromEntries(fmt({ year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    .formatToParts(d).filter((x) => x.type !== 'literal').map((x) => [x.type, x.value]));
}
const isoDay = (d = new Date()) => { const p = tzParts(d); return `${p.year}-${p.month}-${p.day}`; };
const minuteOfDay = (iso) => { const p = tzParts(new Date(iso)); return Number(p.hour) * 60 + Number(p.minute); };
const shiftDay = (ds, n) => { const [y, m, d] = ds.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10); };
const plainDate = (ds, opts) => new Intl.DateTimeFormat('en-GB', { timeZone: 'UTC', ...opts }).format(new Date(`${ds}T12:00:00Z`));
const hhmm = (min) => { const h24 = Math.floor(min / 60), m = min % 60; const h12 = ((h24 + 11) % 12) + 1; return `${h12}${m ? `:${String(m).padStart(2, '0')}` : ''}${h24 < 12 ? 'am' : 'pm'}`; };
const initials = (label) => { const w = String(label || '').replace(/[^A-Za-z\s.]/g, '').trim().split(/\s+/).filter(Boolean); return w.length ? (w[0][0] + (w[1]?.[0] || '')).toUpperCase() : '•'; };

function delta(cur, prev) {
  const c = Number(cur) || 0, p = Number(prev) || 0;
  if (!p) return null;
  const pct = Math.round(((c - p) / p) * 100);
  return `${pct > 0 ? '+' : pct < 0 ? '−' : ''}${Math.abs(pct)}%`;
}

function kcard(tone, icon, label, value, change, period) {
  return h('div', { class: `kcard ${tone}` },
    h('div', { class: 'k-top' }, h('span', { class: 'k-icon', 'aria-hidden': 'true' }, svg(icon, 20)),
      change ? h('span', { class: 'k-delta', title: `Compared with the previous ${period}`, text: change }) : null),
    h('div', { class: 'k-value num', text: value }),
    h('div', { class: 'k-label', text: label }),
    change ? h('span', { class: 'sr-only', text: `, ${change} on the previous ${period}` }) : null);
}

/* ---------- the diary: one column per member of staff ---------- */
function renderDiary(day, { compact = false } = {}) {
  if (day.closed && !day.bookings.length) return h('p', { class: 'sched-closed', text: `Closed on ${plainDate(day.date, { weekday: 'long' })}s.` });
  // bookings whose member of staff isn't in the list still get a column
  const known = new Set(day.staff.map((x) => x.id));
  const d = { ...day, staff: [...day.staff] };
  if (day.bookings.some((b) => !known.has(b.staff_id))) {
    d.staff.push({ id: '__unassigned', name: 'Unassigned', kind: 'staff' });
    d.bookings = day.bookings.map((b) => (known.has(b.staff_id) ? b : { ...b, staff_id: '__unassigned' }));
  }
  if (!d.staff.length) return h('p', { class: 'sched-closed', text: 'No staff have been set up for this business yet.' });
  const toM = (hm) => Number(hm.slice(0, 2)) * 60 + Number(hm.slice(3, 5));
  // the visible hours stretch to fit any booking outside the usual opening times
  const firstB = d.bookings.length ? Math.min(...d.bookings.map((b) => minuteOfDay(b.starts_at))) : Infinity;
  const lastB = d.bookings.length ? Math.max(...d.bookings.map((b) => Math.max(minuteOfDay(b.ends_at), minuteOfDay(b.starts_at) + 10))) : -Infinity;
  const open = Math.floor(Math.min(toM(d.opens), firstB) / 60) * 60;
  const close = Math.min(24 * 60, Math.ceil(Math.max(toM(d.closes), lastB) / 60) * 60);
  const HOUR = compact ? 62 : 88;
  const height = ((close - open) / 60) * HOUR;
  const staffIndex = new Map(d.staff.map((s, i) => [s.id, i]));
  const grid = h('div', { class: 'sched', role: 'group', 'aria-label': `Diary for ${plainDate(d.date, { weekday: 'long', day: 'numeric', month: 'long' })}` });
  grid.style.setProperty('--cols', String(Math.max(1, d.staff.length)));
  grid.style.setProperty('--hour', `${HOUR}px`);
  grid.style.setProperty('--h', `${height}px`);

  grid.append(h('div', { class: 'sched-corner', 'aria-hidden': 'true' }));
  d.staff.forEach((s, i) => {
    const n = d.bookings.filter((b) => b.staff_id === s.id).length;
    grid.append(h('div', { class: 'sched-staff' }, h('i', { class: `dot ${toneOf(s.id === '__unassigned' ? -1 : i)}`, 'aria-hidden': 'true' }), s.name, h('span', { text: `${n}` })));
  });

  const times = h('div', { class: 'sched-times', 'aria-hidden': 'true' });
  for (let m = open; m <= close; m += 60) {
    const t = h('span', { text: hhmm(m) });
    t.style.top = `${((m - open) / 60) * HOUR}px`;
    if (m === open) t.style.transform = 'translateY(2px)';
    if (m === close) t.style.transform = 'translateY(-100%)';
    times.append(t);
  }
  grid.append(times);

  d.staff.forEach((s) => {
    const col = h('div', { class: 'sched-col' });
    for (const b of d.bookings.filter((x) => x.staff_id === s.id)) {
      const a = Math.max(open, minuteOfDay(b.starts_at));
      // a booking running past midnight ends at the bottom of the day
      const endM = isoDay(new Date(b.ends_at)) === d.date ? minuteOfDay(b.ends_at) : close;
      const z = Math.min(close, Math.max(a + 10, endM));
      const tall = ((z - a) / 60) * HOUR;
      const blk = h('button', { type: 'button',
        class: `blk ${toneOf(s.id === '__unassigned' ? -1 : staffIndex.get(s.id))}${b.status === 'completed' ? ' is-done' : ''}${b.status === 'no_show' ? ' is-noshow' : ''}`,
        'aria-label': `${time(b.starts_at)} to ${time(b.ends_at)}, ${b.service} for ${b.customer} with ${s.name}${b.status === 'no_show' ? ', no-show' : ''}`,
        onClick: () => openBooking(b, s.name) },
        h('b', { text: b.service }),
        tall >= 44 ? h('span', { text: b.customer }) : null,
        tall >= 59 ? h('small', { text: `${time(b.starts_at)} – ${time(b.ends_at)}` }) : null);
      blk.style.top = `${((a - open) / 60) * HOUR + 2}px`;
      blk.style.height = `${Math.max(18, tall - 4)}px`;
      if (tall < 44) { blk.style.paddingBlock = '2px'; blk.style.alignContent = 'center'; }
      col.append(blk);
    }
    grid.append(col);
  });

  const wrap = h('div', { class: `sched-wrap${compact ? ' is-compact' : ''}` }, grid);
  if (d.date === isoDay()) {
    const nowMin = minuteOfDay(new Date().toISOString());
    if (nowMin > open && nowMin < close) {
      const line = h('div', { class: 'now-line', 'aria-hidden': 'true' });
      line.style.top = `${46 + ((nowMin - open) / 60) * HOUR}px`;
      grid.style.position = 'relative';
      grid.append(line);
      // start the compact diary near "now"
      if (compact) requestAnimationFrame(() => { wrap.scrollTop = Math.max(0, ((nowMin - open) / 60) * HOUR - 120); });
    }
  }
  return wrap;
}

function openBooking(b, staffName) {
  const close = h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Close', onClick: () => drawer.close() }, svg(ICON_CLOSE));
  const [label, tone] = BOOKING_STATUS[b.status] || [titleCase(b.status), ''];
  const fact = (k, v) => (v ? [h('dt', { text: k }), h('dd', { text: v })] : null);
  drawer.replaceChildren(h('div', { class: 'drawer-inner' },
    h('header', { class: 'drawer-head' },
      h('div', {}, h('h2', { id: 'drawer-title', text: b.service }), h('p', { text: `${plainDate(isoDay(new Date(b.starts_at)), { weekday: 'long', day: 'numeric', month: 'long' })}, ${time(b.starts_at)} – ${time(b.ends_at)}` })),
      close),
    h('div', { class: 'drawer-body' },
      h('div', { class: 'moves' }, h('span', { class: `pill ${tone}`, text: label })),
      h('dl', { class: 'facts' },
        fact('Customer', b.customer), fact('With', staffName || b.staff), fact('How it was booked', CHANNEL_SAID[b.channel] || ''),
        fact('Price', b.price ? money(b.price) : null), fact('Booking reference', b.ref)))));
  drawer.showModal();
  close.focus();
}

/* ---------- charts ---------- */
const SVGNS = 'http://www.w3.org/2000/svg';
function s(tag, attrs = {}, text) {
  const el = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v !== null && v !== undefined) el.setAttribute(k, String(v));
  if (text !== undefined) el.textContent = text;
  return el;
}
/** Three to five evenly spaced gridlines with round values (whole numbers for counts), topping out just above the data. */
function niceScale(v, whole = true) {
  const raw = Math.max(v, whole ? 4 : 1) / 4;
  const e = 10 ** Math.floor(Math.log10(raw));
  let step = [1, 2, 2.5, 5, 10].map((f) => f * e).find((x) => x >= raw) || 10 * e;
  if (whole) step = Math.max(1, Math.ceil(step));
  return { step, max: Math.max(step, Math.ceil(v / step) * step) };
}
let chartSeq = 0;

// Monotone cubic path (no overshoot below zero or above the peak).
function monotonePath(pts) {
  if (pts.length < 2) return pts.length ? `M${pts[0][0]},${pts[0][1]}` : '';
  const n = pts.length, dx = [], dy = [], m = [], t = [];
  for (let i = 0; i < n - 1; i++) { dx[i] = pts[i + 1][0] - pts[i][0]; dy[i] = pts[i + 1][1] - pts[i][1]; m[i] = dy[i] / dx[i]; }
  t[0] = m[0]; t[n - 1] = m[n - 2];
  for (let i = 1; i < n - 1; i++) t[i] = m[i - 1] * m[i] <= 0 ? 0 : (3 * (dx[i - 1] + dx[i])) / ((2 * dx[i] + dx[i - 1]) / m[i - 1] + (dx[i] + 2 * dx[i - 1]) / m[i]);
  let d = `M${pts[0][0]},${pts[0][1]}`;
  for (let i = 0; i < n - 1; i++) {
    const h3 = dx[i] / 3;
    d += ` C${pts[i][0] + h3},${pts[i][1] + h3 * t[i]} ${pts[i + 1][0] - h3},${pts[i + 1][1] - h3 * t[i + 1]} ${pts[i + 1][0]},${pts[i + 1][1]}`;
  }
  return d;
}

function srTable(caption, head, rows) {
  return h('div', { class: 'sr-only' }, h('table', {}, h('caption', { text: caption }),
    h('thead', {}, h('tr', {}, head.map((x) => h('th', { scope: 'col', text: x })))),
    h('tbody', {}, rows.map((r) => h('tr', {}, r.map((x) => h('td', { text: x })))))));
}

/** Bookings per day: one series, a crosshair tooltip, the busiest day labelled. */
function bookingsChart(daily, W = 640) {
  if (!daily.length) return h('p', { class: 'muted', text: 'No bookings in this period yet.' });
  const H = 230, L = 34, R = 12, T = 30, B = 28;
  const vals = daily.map((d) => Number(d.bookings) || 0);
  const { step: yStep, max } = niceScale(Math.max(...vals, 1), true);
  const x = (i) => L + (daily.length === 1 ? (W - L - R) / 2 : (i * (W - L - R)) / (daily.length - 1));
  const y = (v) => T + (1 - v / max) * (H - T - B);
  const id = `g${++chartSeq}`;
  const root = s('svg', { viewBox: `0 0 ${W} ${H}`, class: 'chart-svg', role: 'img', 'aria-label': `Bookings per day over the last ${daily.length} days` });
  const grad = s('linearGradient', { id, x1: 0, y1: 0, x2: 0, y2: 1 });
  grad.append(s('stop', { offset: '0%', 'stop-color': '#005efc', 'stop-opacity': 0.18 }), s('stop', { offset: '100%', 'stop-color': '#005efc', 'stop-opacity': 0 }));
  const defs = s('defs');
  defs.append(grad);
  root.append(defs);
  for (let k = 0; k <= Math.round(max / yStep); k++) {
    const v = yStep * k;
    root.append(s('line', { class: 'gl', x1: L, x2: W - R, y1: y(v), y2: y(v) }), s('text', { class: 'ax', x: L - 8, y: y(v) + 4, 'text-anchor': 'end' }, int(v)));
  }
  const step = Math.max(1, Math.round(daily.length / Math.max(2, Math.floor(W / 110))));
  daily.forEach((d, i) => { if (i % step === 0 || i === daily.length - 1) root.append(s('text', { class: 'ax', x: x(i), y: H - 8, 'text-anchor': i === 0 ? 'start' : i === daily.length - 1 ? 'end' : 'middle' }, plainDate(d.date, { day: 'numeric', month: 'short' }))); });
  const pts = vals.map((v, i) => [x(i), y(v)]);
  const line = monotonePath(pts);
  root.append(s('path', { d: `${line} L${x(vals.length - 1)},${y(0)} L${x(0)},${y(0)} Z`, fill: `url(#${id})` }), s('path', { class: 'line', d: line }));
  // the busiest day, labelled directly
  const pi = vals.indexOf(Math.max(...vals));
  if (vals[pi] > 0) {
    const label = `${int(vals[pi])} bookings`;
    const tw = label.length * 6.6 + 18;
    const tx = Math.min(Math.max(x(pi), L + tw / 2), W - R - tw / 2), ty = Math.max(4, y(vals[pi]) - 34);
    root.append(s('rect', { class: 'peak-tag', x: tx - tw / 2, y: ty, width: tw, height: 22, rx: 11 }), s('text', { class: 'peak-text', x: tx, y: ty + 15, 'text-anchor': 'middle' }, label),
      s('circle', { class: 'peak', cx: x(pi), cy: y(vals[pi]), r: 5 }));
  }
  const cross = s('line', { class: 'cross', x1: 0, x2: 0, y1: T, y2: H - B });
  const pt = s('circle', { class: 'pt', r: 5, cx: 0, cy: 0 });
  const hit = s('rect', { x: L, y: 0, width: W - L - R, height: H, fill: 'transparent' });
  root.append(cross, pt, hit);

  const box = h('div', { class: 'chart', tabindex: '0', 'aria-label': 'Bookings per day chart. Use the left and right arrow keys to read each day.' }, root);
  const tip = h('div', { class: 'chart-tip', hidden: true });
  box.append(tip, srTable('Bookings per day', ['Day', 'Bookings', 'Booked value'], daily.map((d) => [plainDate(d.date, { weekday: 'short', day: 'numeric', month: 'short' }), int(d.bookings), money(d.revenue)])));
  let idx = vals.length - 1;
  const show = (i) => {
    idx = Math.max(0, Math.min(vals.length - 1, i));
    const d = daily[idx];
    cross.setAttribute('x1', x(idx)); cross.setAttribute('x2', x(idx));
    pt.setAttribute('cx', x(idx)); pt.setAttribute('cy', y(vals[idx]));
    tip.replaceChildren(h('b', { text: plainDate(d.date, { weekday: 'short', day: 'numeric', month: 'short' }) }), `${int(d.bookings)} bookings`, h('br'), `${money(d.revenue)} booked value`);
    const r = root.getBoundingClientRect(), bx = box.getBoundingClientRect();
    tip.style.left = `${(x(idx) / W) * r.width + (r.left - bx.left)}px`;
    tip.style.top = `${(y(vals[idx]) / H) * r.height + (r.top - bx.top)}px`;
    tip.hidden = false; box.classList.add('is-hover');
  };
  const hide = () => { tip.hidden = true; box.classList.remove('is-hover'); };
  hit.addEventListener('pointermove', (e) => { const r = root.getBoundingClientRect(); const px = ((e.clientX - r.left) / r.width) * W; show(Math.round(((px - L) / (W - L - R)) * (vals.length - 1))); });
  hit.addEventListener('pointerleave', hide);
  box.addEventListener('focus', () => show(idx));
  box.addEventListener('blur', hide);
  box.addEventListener('keydown', (e) => { if (e.key === 'ArrowLeft') { e.preventDefault(); show(idx - 1); } if (e.key === 'ArrowRight') { e.preventDefault(); show(idx + 1); } });
  return box;
}

/** Revenue per month, stacked by how the booking came in. */
function revenueChart(monthly, W = 640) {
  const H = 240, L = 48, R = 8, T = 12, B = 28, GAP = 2;
  const totals = monthly.map((m) => SERIES.reduce((t, [k]) => t + (Number(m[k]) || 0), 0));
  const top = Math.max(...totals, 0);
  if (!monthly.length) return h('p', { class: 'muted', text: 'No takings yet.' });
  const { step: yStep, max } = niceScale(Math.max(top, 1), top < 100);
  const y = (v) => T + (1 - v / max) * (H - T - B);
  const band = (W - L - R) / monthly.length, bw = Math.min(46, band * 0.5);
  const root = s('svg', { viewBox: `0 0 ${W} ${H}`, class: 'chart-svg', role: 'group', 'aria-label': 'Takings per month by how bookings came in' });
  for (let k = 0; k <= Math.round(max / yStep); k++) {
    const v = yStep * k;
    root.append(s('line', { class: 'gl', x1: L, x2: W - R, y1: y(v), y2: y(v) }), s('text', { class: 'ax', x: L - 8, y: y(v) + 4, 'text-anchor': 'end' }, v >= 1000 ? `£${(v / 1000).toFixed(v % 1000 ? 1 : 0)}k` : `£${int(v)}`));
  }
  const box = h('div', { class: 'chart' });
  const tip = h('div', { class: 'chart-tip', hidden: true });
  monthly.forEach((m, i) => {
    const cx = L + band * i + band / 2;
    const name = plainDate(`${m.month}-01`, { month: 'short' });
    root.append(s('text', { class: 'ax', x: cx, y: H - 8, 'text-anchor': 'middle' }, name));
    let acc = 0;
    const segs = SERIES.filter(([k]) => Number(m[k]) > 0);
    segs.forEach(([k], j) => {
      const v = Number(m[k]);
      const top = y(acc + v), bottom = y(acc);
      const hgt = Math.max(0, bottom - top - (j > 0 ? GAP : 0));
      if (hgt > 0) root.append(s('rect', { class: `s-${k}`, x: cx - bw / 2, y: top, width: bw, height: hgt, rx: j === segs.length - 1 ? 4 : 1.5 }));
      acc += v;
    });
    const hitR = s('rect', { class: 'bar-hit', x: L + band * i, y: T, width: band, height: H - T - B, tabindex: 0, role: 'img',
      'aria-label': `${plainDate(`${m.month}-01`, { month: 'long', year: 'numeric' })}: ${money(totals[i])} in total. ${SERIES.map(([k, lab]) => `${lab} ${money(m[k])}`).join(', ')}` });
    const show = () => {
      tip.replaceChildren(h('b', { text: plainDate(`${m.month}-01`, { month: 'long', year: 'numeric' }) }), `${money(totals[i])} in total`,
        ...SERIES.map(([k, lab]) => h('div', {}, h('i', { class: `s-${k}` }), `${lab} ${money(m[k])}`)));
      const r = root.getBoundingClientRect(), bx = box.getBoundingClientRect();
      tip.style.left = `${(cx / W) * r.width + (r.left - bx.left)}px`;
      tip.style.top = `${(y(totals[i]) / H) * r.height + (r.top - bx.top)}px`;
      tip.hidden = false;
    };
    hitR.addEventListener('pointerenter', show); hitR.addEventListener('focus', show);
    hitR.addEventListener('pointerleave', () => { tip.hidden = true; }); hitR.addEventListener('blur', () => { tip.hidden = true; });
    root.append(hitR);
  });
  box.append(root, tip, srTable('Revenue per month', ['Month', ...SERIES.map(([, l]) => l), 'Total'],
    monthly.map((m, i) => [plainDate(`${m.month}-01`, { month: 'long', year: 'numeric' }), ...SERIES.map(([k]) => money(m[k])), money(totals[i])])));
  return box;
}

/** Draws a chart at the panel's real width (so text stays at its true size) and redraws when the panel resizes. */
function fitChart(build) {
  const host = h('div', { class: 'chart-host' });
  let last = 0;
  const draw = (w) => { const width = Math.max(300, Math.round(w)); if (Math.abs(width - last) < 8) return; last = width; host.replaceChildren(build(width)); };
  if ('ResizeObserver' in window) new ResizeObserver((entries) => draw(entries[0].contentRect.width)).observe(host);
  requestAnimationFrame(() => draw(host.clientWidth || 640));
  return host;
}

/* ---------- upcoming rail ---------- */
function renderRail(list, staffNames) {
  const staffIdx = new Map((staffNames || []).map((n, i) => [n, i]));
  const today = isoDay();
  const days = Array.from({ length: 7 }, (_, i) => shiftDay(today, i));
  if (!state.railDay || !days.includes(state.railDay)) state.railDay = today;
  const byDay = (ds) => list.filter((b) => isoDay(new Date(b.starts_at)) === ds);
  const items = h('ul', { class: 'appts', role: 'list' });
  const month = h('span', { class: 'rail-month' });
  const week = h('div', { class: 'week', role: 'group', 'aria-label': 'Choose a day' });
  const draw = () => {
    month.textContent = plainDate(state.railDay, { month: 'long', year: 'numeric' });
    for (const b of week.children) b.setAttribute('aria-pressed', String(b.dataset.day === state.railDay));
    const rows = byDay(state.railDay);
    items.replaceChildren(...(rows.length ? rows.map((b) => {
      const i = staffIdx.has(b.staff) ? staffIdx.get(b.staff) : -1;
      return h('li', {},
        h('button', { type: 'button', class: 'appt', onClick: () => openBooking(b, b.staff) },
          h('span', { class: `avatar ${toneOf(i)}`, 'aria-hidden': 'true', text: initials(b.customer) }),
          h('span', { class: 'who' }, h('b', { text: b.customer }), h('span', { text: b.service }), h('small', { text: `${time(b.starts_at)} with ${b.staff}` })),
          h('span', { class: 'price', text: b.price ? money(b.price) : '' })));
    }) : [h('li', { class: 'rail-empty', text: state.railDay === today ? 'No more appointments today.' : 'No appointments booked yet.' })]));
  };
  days.forEach((ds) => {
    const n = byDay(ds).length;
    week.append(h('button', { type: 'button', dataset: { day: ds }, 'aria-label': `${plainDate(ds, { weekday: 'long', day: 'numeric', month: 'long' })}, ${n} appointments`,
      onClick: () => { state.railDay = ds; draw(); } },
      plainDate(ds, { weekday: 'short' }), h('b', { text: plainDate(ds, { day: 'numeric' }) })));
  });
  draw();
  return h('aside', { class: 'rail', 'aria-label': 'Upcoming appointments' },
    h('div', { class: 'rail-head' }, h('h2', { text: 'Upcoming' }), month), week, items);
}

/* ---------- views ---------- */
function deskEmpty() {
  view.replaceChildren(empty('No business to show yet', 'Once a client\'s booking system is set up, their diary, calls and takings appear here.'));
}

async function renderOverview(current) {
  if (!state.client) return deskEmpty();
  const seg = h('div', { class: 'seg', role: 'group', 'aria-label': 'Period' },
    [[7, '7 days'], [30, '30 days'], [90, '90 days']].map(([d, t]) => h('button', { type: 'button', 'aria-pressed': String(d === state.deskDays), text: t,
      onClick: () => { state.deskDays = d; route(); } })));
  tools.append(seg);
  loading(3);
  const cid = state.client.id;
  const [ov, dy, up] = await Promise.all([src.overview(cid, state.deskDays), src.day(cid, null), src.upcoming(cid, null, 7)]);
  if (!current()) return;
  state.receptionist = ov?.business?.receptionist_name || 'Sophie';
  const k = ov.kpis || {};
  const period = `${ov.days} days`;
  const kcards = h('section', { class: 'kcards', 'aria-label': `The last ${period}` },
    kcard('k-navy', ICON.calendar, 'Bookings', int(k.bookings), delta(k.bookings, k.bookings_prev), period),
    kcard('k-blue', ICON.spark, `Booked by ${state.receptionist}`, int(k.by_ai), k.bookings ? `${Math.round((k.by_ai / k.bookings) * 100)}% of all` : null, period),
    kcard('k-teal', ICON.pound, 'Takings', money(k.revenue), delta(k.revenue, k.revenue_prev), period),
    kcard('k-brass', ICON.phone, 'Calls answered', int(k.calls), delta(k.calls, k.calls_prev), period));

  const diary = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('div', { class: 'panel-head-col' }, h('h2', { text: 'Today\'s diary' }),
      h('span', { class: 'panel-sub', text: dy.closed ? 'Closed today' : `${dy.bookings.length} appointments, ${dy.opens.replace(/^0/, '')} to ${dy.closes.replace(/^0/, '')}` })),
      h('a', { class: 'text-link', href: `${DEMO ? location.search : ''}#calendar`, text: 'Open calendar' })),
    renderDiary(dy, { compact: true }));

  const statsPanel = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('div', { class: 'panel-head-col' }, h('h2', { text: 'Bookings' }), h('span', { class: 'panel-sub', text: `New bookings each day, last ${period}` }))),
    h('div', { class: 'panel-body' }, fitChart((w) => bookingsChart(ov.daily || [], w))));
  const revPanel = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('div', { class: 'panel-head-col' }, h('h2', { text: 'Takings by month' }), h('span', { class: 'panel-sub', text: 'Completed appointments, by how they were booked' }))),
    h('div', { class: 'panel-body' },
      h('div', { class: 'legend', 'aria-hidden': 'true' }, SERIES.map(([key, lab]) => h('span', {}, h('i', { class: `s-${key}` }), lab))),
      fitChart((w) => revenueChart(ov.monthly || [], w))));

  view.replaceChildren(h('div', { class: 'fd' },
    h('div', { class: 'fd-main' }, kcards, h('div', { class: 'fd-row' }, statsPanel, revPanel), diary),
    renderRail(up.bookings || [], dy.staff.map((x) => x.name))));
}

async function renderCalendar(current) {
  if (!state.client) return deskEmpty();
  const today = isoDay();
  if (!state.calDate) state.calDate = today;
  const label = h('span', { class: 'pager-label', 'aria-live': 'polite' });
  const go = (n) => { state.calDate = n === 0 ? today : shiftDay(state.calDate, n); route(); };
  tools.append(h('div', { class: 'pager' },
    h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Previous day', onClick: () => go(-1) }, svg(ICON.left)),
    label,
    h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Next day', onClick: () => go(1) }, svg(ICON.right))),
  h('button', { class: 'btn btn-sm btn-quiet', type: 'button', text: 'Today', disabled: state.calDate === today, onClick: () => go(0) }));
  label.textContent = plainDate(state.calDate, { weekday: 'long', day: 'numeric', month: 'long' });
  loading(1);
  const dy = await src.day(state.client.id, state.calDate);
  if (!current()) return;
  const value = dy.bookings.reduce((t, b) => t + (Number(b.price) || 0), 0);
  view.replaceChildren(h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('div', { class: 'panel-head-col' },
      h('h2', { text: state.calDate === today ? 'Today' : plainDate(state.calDate, { weekday: 'long' }) }),
      h('span', { class: 'panel-sub', text: dy.closed ? 'Closed' : `${dy.bookings.length} appointments, ${money(value)} booked, open ${dy.opens.replace(/^0/, '')} to ${dy.closes.replace(/^0/, '')}` }))),
    renderDiary(dy)));
}

async function renderActivity(current) {
  if (!state.client) return deskEmpty();
  loading(2);
  const a = await src.activity(state.client.id);
  if (!current()) return;
  const dur = (sec) => { const n = Number(sec) || 0; return n >= 60 ? `${Math.floor(n / 60)} min ${n % 60 ? `${n % 60} s` : ''}`.trim() : `${n} s`; };
  const calls = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('h2', { text: 'Calls' }), h('span', { class: 'muted', text: `${a.calls.length} most recent` })),
    h('div', { class: 'panel-body' }, a.calls.length ? h('ul', { class: 'calls', role: 'list' }, a.calls.map((c) => h('li', { class: 'call' },
      h('span', { class: `avatar ${c.channel === 'web' ? 't2' : 't1'}`, 'aria-hidden': 'true' }, svg(c.channel === 'web' ? ICON.web : ICON.phone)),
      h('div', {}, h('b', { text: c.customer }), h('p', { text: c.summary || 'No summary for this call.' })),
      h('small', {}, ago(c.started_at), h('br'), c.channel === 'web' ? `Website, ${dur(c.duration_s)}` : `Phone, ${dur(c.duration_s)}`))))
      : h('p', { class: 'muted', text: 'No calls yet. Calls answered by your receptionist appear here with a short summary.' })));
  const texts = h('section', { class: 'panel' },
    h('div', { class: 'panel-head' }, h('h2', { text: 'Texts' }), h('span', { class: 'muted', text: 'Newest first' })),
    h('div', { class: 'panel-body' }, a.texts.length ? h('ul', { class: 'texts', role: 'list' }, a.texts.map((m) => h('li', { class: `bubble ${m.direction === 'in' ? 'in' : 'out'}` },
      m.body, h('small', { text: `${m.direction === 'in' ? m.customer : `To ${m.customer}`}, ${ago(m.at)}` }))))
      : h('p', { class: 'muted', text: 'No texts yet. Confirmations, reminders and replies appear here.' })));
  view.replaceChildren(h('div', { class: 'act' }, calls, texts));
}

/* ------------------------------------------------------------------ boot */

function notLinked(email) {
  document.body.classList.remove('is-loading');
  $('.side-nav').hidden = true;
  $('.js-view-title').textContent = 'Almost there';
  $('.js-view-sub').textContent = '';
  view.setAttribute('aria-busy', 'false');
  view.replaceChildren(empty('Your account isn\'t linked to a business yet',
    `You're signed in as ${email || 'this account'}, but it hasn't been given access to a business or a SimplyBooked organisation yet. Ask the person who set up your account to add you, then sign in again.`,
    h('button', { class: 'btn btn-quiet', type: 'button', text: 'Sign out', onClick: async () => { await signOut(); location.replace('/login.html'); } })));
}

const CLIENT_KEY = 'simplybooked.client';
function chooseClient(id) {
  state.client = state.clients.find((c) => c.id === id) || state.clients[0] || null;
  state.clientTz = state.client?.timezone || 'Europe/London';
  try { if (state.client) localStorage.setItem(CLIENT_KEY, state.client.id); } catch { /* ignore */ }
  state.calDate = null; state.railDay = null;
}

async function boot() {
  $('.js-nav-open').addEventListener('click', openNav);
  document.querySelectorAll('.js-nav-close').forEach((el) => el.addEventListener('click', closeNav));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && $('#side').classList.contains('is-open')) closeNav(); });

  const signout = $('.js-signout');
  if (DEMO) {
    $('.js-demo-bar').hidden = false;
    if (DEMO_SALES) $('.js-demo-text').textContent = 'You\'re exploring the demo with sample businesses. Nothing you do here is saved or sent.';
    signout.textContent = 'Leave demo';
    signout.addEventListener('click', () => location.assign('/'));
    // keep demo mode across navigation
    for (const a of document.querySelectorAll('.side-nav a')) a.href = `${location.pathname}${location.search}${a.getAttribute('href')}`;
  } else {
    signout.addEventListener('click', async () => { await signOut(); location.replace('/login.html'); });
  }

  let session = null;
  if (!DEMO) {
    session = await getSession();
    if (!session) { location.replace('/login.html'); return; }
  }

  try {
    if (DEMO) {
      state.canDesk = true;
      state.canGrowth = DEMO_SALES;
      state.clients = await src.portalClients();
      if (DEMO_SALES) { const me = await src.me(); state.profile = me.profile; state.org = me.org; }
    } else {
      const [me, clients] = await Promise.all([src.me(session.user?.id), src.portalClients().catch((e) => { if (e?.code === 'unauthenticated') throw e; return []; })]);
      state.profile = me.profile; state.org = me.org;
      state.clients = clients;
      state.canGrowth = !!(me.profile && me.org);
      state.canDesk = clients.length > 0;
      if (!state.canGrowth && !state.canDesk) { notLinked(session.user?.email); return; }
    }
  } catch (e) {
    if (e?.code === 'unauthenticated') { location.replace('/login.html'); return; }
    document.body.classList.remove('is-loading');
    failed(e, () => location.reload());
    return;
  }

  let saved = null;
  try { saved = localStorage.getItem(CLIENT_KEY); } catch { saved = null; }
  chooseClient(saved);
  $('.js-group-desk').hidden = !state.canDesk;
  $('.js-group-growth').hidden = !state.canGrowth;
  if (state.clients.length > 1) {
    const picker = $('.js-business-picker');
    picker.replaceChildren(...state.clients.map((c) => h('option', { value: c.id, text: c.business_name, selected: c.id === state.client?.id })));
    picker.addEventListener('change', () => { chooseClient(picker.value); route(); });
    $('.js-business').hidden = false;
  }

  state.orgTz = state.org?.timezone || BROWSER_TZ;
  const who = state.profile?.full_name || state.profile?.email || session?.user?.email || (DEMO ? 'Leo' : '');
  $('.js-org').textContent = state.canGrowth ? (state.org?.name || '') : (state.client?.business_name || '');
  $('.js-user').textContent = DEMO && !DEMO_SALES ? 'Owner' : (state.profile?.email || session?.user?.email || '');
  $('.js-me-avatar').textContent = initials(who);
  document.body.classList.remove('is-loading');

  window.addEventListener('hashchange', route);
  if (state.canGrowth) loadMetrics().catch(() => {}); // sidebar counts
  route();
}

boot();
