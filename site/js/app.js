// SimplyBooked dashboard. Live mode reads the signed-in organisation's data; ?demo=1 renders the same screens
// with fictional sample data and never contacts the server.
import { getSession, signOut } from './auth.js';
import * as api from './api.js';
import * as demo from './demo-data.js';

const DEMO = new URLSearchParams(location.search).has('demo');

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

let TZ = Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/London';
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
};

const demoStore = { leads: clone(demo.leads), outreach: clone(demo.outreach), replies: clone(demo.replies), meetings: clone(demo.meetings), clients: clone(demo.clients) };
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
    return { ok: true, demo: true };
  },
};

const src = DEMO ? sample : live;
const state = { profile: null, org: null, metrics: null, days: 90, leadFilter: '' };

/* ------------------------------------------------------------------ chrome */

const VIEWS = {
  today: { title: 'Today', sub: () => (state.org?.name ? `${state.org.name} at a glance` : 'Your business at a glance'), render: renderToday },
  pipeline: { title: 'Pipeline', sub: () => 'Every business you\'re talking to, by stage', render: renderPipeline },
  approvals: { title: 'Approvals', sub: () => 'Nothing is sent until you approve it', render: renderApprovals },
  replies: { title: 'Replies', sub: () => 'Answers from businesses you\'ve contacted', render: renderReplies },
  meetings: { title: 'Meetings', sub: () => 'Calls and demos, past fortnight and ahead', render: renderMeetings },
  clients: { title: 'Clients', sub: () => 'Onboarding progress and monthly revenue', render: renderClients },
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
async function route() {
  const name = (location.hash.replace('#', '') || 'today');
  const v = VIEWS[name] || VIEWS.today;
  const key = VIEWS[name] ? name : 'today';
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
    view.replaceChildren(empty('No leads yet', 'Import a list of businesses or run a search, and they\'ll appear here sorted by how well they fit.'));
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

/* ------------------------------------------------------------------ boot */

function notLinked(email) {
  document.body.classList.remove('is-loading');
  $('.side-nav').hidden = true;
  $('.js-view-title').textContent = 'Almost there';
  $('.js-view-sub').textContent = '';
  view.setAttribute('aria-busy', 'false');
  view.replaceChildren(empty('Your account isn\'t linked to a business yet',
    `You're signed in as ${email || 'this account'}, but it hasn't been added to a SimplyBooked organisation. Ask the account owner to add you, then sign in again.`,
    h('button', { class: 'btn btn-quiet', type: 'button', text: 'Sign out', onClick: async () => { await signOut(); location.replace('/login.html'); } })));
}

async function boot() {
  $('.js-nav-open').addEventListener('click', openNav);
  document.querySelectorAll('.js-nav-close').forEach((el) => el.addEventListener('click', closeNav));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && $('#side').classList.contains('is-open')) closeNav(); });

  const signout = $('.js-signout');
  if (DEMO) {
    $('.js-demo-bar').hidden = false;
    signout.textContent = 'Leave demo';
    signout.addEventListener('click', () => location.assign('/'));
    // keep demo mode across navigation
    for (const a of document.querySelectorAll('.side-nav a')) a.href = `?demo=1${a.getAttribute('href')}`;
  } else {
    signout.addEventListener('click', async () => { await signOut(); location.replace('/login.html'); });
  }

  let session = null;
  if (!DEMO) {
    session = await getSession();
    if (!session) { location.replace('/login.html'); return; }
  }

  try {
    const me = await src.me(session?.user?.id);
    state.profile = me.profile;
    state.org = me.org;
    if (!DEMO && (!me.profile || !me.org)) { notLinked(session?.user?.email); return; }
  } catch (e) {
    if (e?.code === 'unauthenticated') { location.replace('/login.html'); return; }
    document.body.classList.remove('is-loading');
    failed(e, () => location.reload());
    return;
  }
  if (state.org?.timezone) TZ = state.org.timezone;
  $('.js-org').textContent = state.org?.name || '';
  $('.js-user').textContent = state.profile?.email || session?.user?.email || '';
  document.body.classList.remove('is-loading');

  window.addEventListener('hashchange', route);
  loadMetrics().catch(() => {}); // sidebar counts
  route();
}

boot();
