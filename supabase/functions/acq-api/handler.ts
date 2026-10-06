// acq-api — the ONLY door the browser uses for privileged ACQ actions.
// Pure handler (no Deno globals) so it is unit-testable under Node. index.ts wires the real clients.
// Security model: every action is an allow-listed RPC executed with the CALLER's JWT, so Postgres re-checks
// org + role (acq.require_role) and RLS. This function adds origin allow-listing, strict input validation,
// body-size limits and per-user rate limiting. It never uses the service-role key for business actions.

export interface UserDb { rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: { code?: string; message?: string; details?: string } | null }> }
export interface Deps {
  allowedOrigins: string[];
  getUserId(jwt: string): Promise<string | null>;
  userDb(jwt: string): UserDb;
  rateLimit(key: string, limit: number, windowS: number): Promise<{ allowed: boolean; retry_after_s: number }>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATUSES = ['new_lead', 'qualified', 'approved', 'contacted', 'replied', 'demo_sent', 'meeting_booked', 'won', 'lost'];
const MAX_BODY = 1_000_000;

class Bad extends Error { constructor(public field: string, msg: string) { super(msg); } }
const obj = (v: unknown, f: string) => { if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Bad(f, f + ' must be an object'); return v as Record<string, unknown>; };
const str = (v: unknown, f: string, min: number, max: number, opt = false): string | null => {
  if (v === undefined || v === null || v === '') { if (opt) return null; throw new Bad(f, f + ' is required'); }
  if (typeof v !== 'string') throw new Bad(f, f + ' must be text');
  const t = v.trim(); if (t.length < min || t.length > max) throw new Bad(f, `${f} must be ${min}-${max} characters`); return t;
};
const uuid = (v: unknown, f: string) => { const s = str(v, f, 36, 36)!; if (!UUID.test(s)) throw new Bad(f, f + ' must be a UUID'); return s; };

const ISO_TZ = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;
const CLIENT_SECTIONS = ['business_details', 'receptionist_config', 'booking_requirements', 'faqs', 'integrations'];
const days = (v: unknown) => { if (v === undefined || v === null) return 90; const n = Number(v); if (!Number.isInteger(n) || n < 1 || n > 730) throw new Bad('days', 'days must be 1-730'); return n; };

interface Action { rpc: string; limit: number; args(b: Record<string, unknown>): Record<string, unknown> }
export const ACTIONS: Record<string, Action> = {
  import_leads: { rpc: 'import_leads', limit: 10, args: b => {
    if (!Array.isArray(b.items) || b.items.length < 1 || b.items.length > 200) throw new Bad('items', 'items must be an array of 1-200 leads');
    for (const it of b.items) obj(it, 'items[]');
    return { p_items: b.items, p_source_key: str(b.source_key, 'source_key', 2, 40, true) ?? 'csv' };
  } },
  move_lead: { rpc: 'move_lead', limit: 120, args: b => {
    const to = str(b.to, 'to', 3, 20)!; if (!STATUSES.includes(to)) throw new Bad('to', 'unknown status');
    return { p_lead: uuid(b.lead_id, 'lead_id'), p_to: to, p_reason: str(b.reason, 'reason', 1, 200, true) };
  } },
  queue_search_run: { rpc: 'queue_search_run', limit: 10, args: b => {
    const mr = b.max_results === undefined ? 20 : Number(b.max_results);
    if (!Number.isInteger(mr) || mr < 1 || mr > 60) throw new Bad('max_results', 'max_results must be 1-60');
    const cc = str(b.country, 'country', 2, 2)!.toUpperCase(); if (!/^[A-Z]{2}$/.test(cc)) throw new Bad('country', 'country must be a 2-letter code');
    return { p_source_key: str(b.source_key, 'source_key', 2, 40), p_niche: str(b.niche, 'niche', 2, 80), p_city: str(b.city, 'city', 1, 80, true),
             p_region: str(b.region, 'region', 1, 80, true), p_country: cc, p_max: mr };
  } },
  mark_do_not_contact: { rpc: 'mark_do_not_contact', limit: 60, args: b => ({ p_lead: uuid(b.lead_id, 'lead_id'), p_note: str(b.note, 'note', 1, 200, true) }) },
  requalify_lead: { rpc: 'requalify_lead', limit: 30, args: b => ({ p_lead: uuid(b.lead_id, 'lead_id') }) },
  erase_lead: { rpc: 'erase_lead', limit: 10, args: b => ({ p_lead: uuid(b.lead_id, 'lead_id') }) },
  reinstate_lead: { rpc: 'reinstate_lead', limit: 10, args: b => ({ p_lead: uuid(b.lead_id, 'lead_id') }) },
  // ---- Phase 3: outreach approval (the database enforces role + the approval gate; this layer validates shape only)
  edit_draft: { rpc: 'edit_draft', limit: 60, args: b => ({ p_message: uuid(b.message_id, 'message_id'), p_subject: str(b.subject, 'subject', 3, 150, true), p_body: str(b.body, 'body', 10, 2000) }) },
  approve_message: { rpc: 'approve_message', limit: 60, args: b => ({ p_message: uuid(b.message_id, 'message_id'), p_subject: str(b.subject, 'subject', 3, 150, true), p_body: str(b.body, 'body', 10, 2000, true) }) },
  reject_message: { rpc: 'reject_message', limit: 60, args: b => ({ p_message: uuid(b.message_id, 'message_id'), p_reason: str(b.reason, 'reason', 1, 200, true) }) },
  approve_messages: { rpc: 'approve_messages', limit: 10, args: b => {
    if (!Array.isArray(b.message_ids) || b.message_ids.length < 1 || b.message_ids.length > 50) throw new Bad('message_ids', 'message_ids must be 1-50 ids');
    return { p_ids: b.message_ids.map((x, i) => uuid(x, `message_ids[${i}]`)) };
  } },
  redraft_lead: { rpc: 'redraft_lead', limit: 30, args: b => ({ p_lead: uuid(b.lead_id, 'lead_id') }) },
  update_setting: { rpc: 'update_setting', limit: 30, args: b => {
    const key = str(b.key, 'key', 2, 40)!; if (!/^[a-z_]+$/.test(key)) throw new Bad('key', 'invalid setting key');
    if (b.value === undefined) throw new Bad('value', 'value is required');
    if (JSON.stringify(b.value).length > 5000) throw new Bad('value', 'value too large');
    return { p_key: key, p_value: b.value };
  } },
  set_outreach_enabled: { rpc: 'set_outreach_enabled', limit: 10, args: b => {
    if (typeof b.enabled !== 'boolean') throw new Bad('enabled', 'enabled must be true or false');
    return { p_enabled: b.enabled };
  } },
  // ---- Phase 4: replies, demos, meetings (database re-checks org + role; shapes validated here)
  edit_reply_response: { rpc: 'edit_reply_response', limit: 60, args: b => ({ p_reply: uuid(b.reply_id, 'reply_id'), p_body: str(b.body, 'body', 10, 2000)! }) },
  approve_reply_response: { rpc: 'approve_reply_response', limit: 60, args: b => ({ p_reply: uuid(b.reply_id, 'reply_id'), p_body: str(b.body, 'body', 10, 2000, true) }) },
  reject_reply_response: { rpc: 'reject_reply_response', limit: 60, args: b => ({ p_reply: uuid(b.reply_id, 'reply_id') }) },
  mark_reply_handled: { rpc: 'mark_reply_handled', limit: 120, args: b => ({ p_reply: uuid(b.reply_id, 'reply_id') }) },
  match_reply_manually: { rpc: 'match_reply_manually', limit: 60, args: b => ({ p_reply: uuid(b.reply_id, 'reply_id'), p_lead: uuid(b.lead_id, 'lead_id') }) },
  create_demo: { rpc: 'create_demo', limit: 30, args: b => {
    const cfg = b.config === undefined ? {} : obj(b.config, 'config');
    if (JSON.stringify(cfg).length > 4000) throw new Bad('config', 'config too large');
    return { p_lead: uuid(b.lead_id, 'lead_id'), p_title: str(b.title, 'title', 1, 120, true), p_config: cfg };   // allow-listed keys + plain-text rule enforced in the database
  } },
  revoke_demo: { rpc: 'revoke_demo', limit: 30, args: b => ({ p_demo: uuid(b.demo_id, 'demo_id') }) },
  send_demo: { rpc: 'send_demo', limit: 30, args: b => ({ p_demo: uuid(b.demo_id, 'demo_id'), p_subject: str(b.subject, 'subject', 3, 150)!, p_body: str(b.body, 'body', 20, 2000)! }) },
  schedule_meeting: { rpc: 'schedule_meeting', limit: 30, args: b => {
    const start = str(b.start, 'start', 20, 40)!;
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(start) || Number.isNaN(Date.parse(start))) throw new Bad('start', 'start must be an ISO time with a timezone');
    const dur = b.duration_min === undefined ? 30 : Number(b.duration_min);
    if (!Number.isInteger(dur) || dur < 10 || dur > 240) throw new Bad('duration_min', 'duration_min must be 10-240');
    const ch = str(b.channel, 'channel', 4, 12, true) ?? 'google_meet';
    if (!['google_meet', 'phone', 'in_person', 'zoom'].includes(ch)) throw new Bad('channel', 'unknown channel');
    const email = str(b.attendee_email, 'attendee_email', 6, 254, true);
    if (email && !/^[^\s@<>"',;:]{1,64}@[^\s@<>"',;:]{1,200}\.[a-z]{2,24}$/i.test(email)) throw new Bad('attendee_email', 'attendee_email does not look valid');
    return { p_lead: uuid(b.lead_id, 'lead_id'), p_start: start, p_duration_min: dur, p_title: str(b.title, 'title', 1, 200, true) ?? 'Intro call',
             p_channel: ch, p_attendee_name: str(b.attendee_name, 'attendee_name', 1, 100, true), p_attendee_email: email, p_notes: str(b.notes, 'notes', 1, 1000, true) };
  } },
  cancel_meeting: { rpc: 'cancel_meeting', limit: 30, args: b => ({ p_meeting: uuid(b.meeting_id, 'meeting_id'), p_reason: str(b.reason, 'reason', 1, 200, true) }) },
  set_meeting_outcome: { rpc: 'set_meeting_outcome', limit: 60, args: b => {
    const st = str(b.status, 'status', 4, 12)!; if (!['completed', 'no_show'].includes(st)) throw new Bad('status', 'status must be completed or no_show');
    const oc = str(b.outcome, 'outcome', 3, 20, true); if (oc && !['won', 'lost', 'follow_up', 'no_decision'].includes(oc)) throw new Bad('outcome', 'unknown outcome');
    return { p_meeting: uuid(b.meeting_id, 'meeting_id'), p_status: st, p_outcome: oc, p_notes: str(b.notes, 'notes', 1, 2000, true) };
  } },
  // ---- Phase 5: follow-ups, onboarding, metrics (the database re-checks org, role and every rule)
  cancel_lead_followups: { rpc: 'cancel_lead_followups', limit: 60, args: b => ({ p_lead: uuid(b.lead_id, 'lead_id') }) },
  skip_followup: { rpc: 'skip_followup', limit: 60, args: b => ({ p_followup: uuid(b.followup_id, 'followup_id') }) },
  set_followup_due: { rpc: 'set_followup_due', limit: 60, args: b => {
    const due = str(b.due_at, 'due_at', 20, 40)!;
    if (!ISO_TZ.test(due) || Number.isNaN(Date.parse(due))) throw new Bad('due_at', 'due_at must be an ISO time with a timezone');
    return { p_followup: uuid(b.followup_id, 'followup_id'), p_due: due };
  } },
  convert_lead_to_client: { rpc: 'convert_lead_to_client', limit: 20, args: b => ({ p_lead: uuid(b.lead_id, 'lead_id') }) },
  update_client_config: { rpc: 'update_client_config', limit: 60, args: b => {
    const section = str(b.section, 'section', 4, 30)!;
    if (!CLIENT_SECTIONS.includes(section)) throw new Bad('section', 'unknown section');
    const v = b.value;
    if (v === null || typeof v !== 'object') throw new Bad('value', 'value must be an object or a list');
    if (JSON.stringify(v).length > 20000) throw new Bad('value', 'value is too large');
    return { p_client: uuid(b.client_id, 'client_id'), p_section: section, p_value: v };   // shape + plain-text + no-credential rules enforced in the database
  } },
  set_client_status: { rpc: 'set_client_status', limit: 30, args: b => {
    const st = str(b.status, 'status', 5, 12)!; if (!['onboarding', 'active', 'paused', 'churned'].includes(st)) throw new Bad('status', 'unknown status');
    return { p_client: uuid(b.client_id, 'client_id'), p_status: st };
  } },
  provision_bos_business: { rpc: 'provision_bos_business', limit: 10, args: b => ({ p_client: uuid(b.client_id, 'client_id') }) },
  dashboard_metrics: { rpc: 'dashboard_metrics', limit: 60, args: b => ({ p_days: days(b.days) }) },
  performance_breakdown: { rpc: 'performance_breakdown', limit: 60, args: b => {
    const dim = str(b.dimension, 'dimension', 4, 10)!; if (!['niche', 'source', 'campaign', 'city'].includes(dim)) throw new Bad('dimension', 'dimension must be niche, source, campaign or city');
    return { p_dim: dim, p_days: days(b.days) };
  } },
};

export function registerActions(extra: Record<string, Action>) { Object.assign(ACTIONS, extra); }

const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers } });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const origin = req.headers.get('origin');
  const cors: Record<string, string> = {};
  if (origin) {
    if (!deps.allowedOrigins.includes(origin)) return json(403, { error: 'origin_not_allowed' });
    Object.assign(cors, { 'Access-Control-Allow-Origin': origin, 'Vary': 'Origin',
      'Access-Control-Allow-Headers': 'authorization, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' });
  }
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' }, cors);

  const auth = req.headers.get('authorization') ?? '';
  const jwt = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!jwt) return json(401, { error: 'unauthenticated' }, cors);
  const userId = await deps.getUserId(jwt).catch(() => null);
  if (!userId) return json(401, { error: 'unauthenticated' }, cors);

  const len = Number(req.headers.get('content-length') ?? '0');
  if (len > MAX_BODY) return json(413, { error: 'body_too_large' }, cors);
  const raw = await req.text();
  if (raw.length > MAX_BODY) return json(413, { error: 'body_too_large' }, cors);
  let body: Record<string, unknown>;
  try { body = obj(JSON.parse(raw), 'body'); } catch { return json(400, { error: 'invalid_json' }, cors); }

  const name = typeof body.action === 'string' ? body.action : '';
  const action = Object.prototype.hasOwnProperty.call(ACTIONS, name) ? ACTIONS[name] : undefined;
  if (!action) return json(400, { error: 'unknown_action' }, cors);

  let args: Record<string, unknown>;
  try { args = action.args(obj(body.params ?? {}, 'params')); }
  catch (e) { if (e instanceof Bad) return json(400, { error: 'invalid_input', field: e.field, message: e.message }, cors); throw e; }

  const rl = await deps.rateLimit(`acq-api:${userId}:${name}`, action.limit, 60).catch(() => ({ allowed: false, retry_after_s: 30 }));
  if (!rl.allowed) return json(429, { error: 'rate_limited', retry_after_s: rl.retry_after_s }, { ...cors, 'Retry-After': String(rl.retry_after_s) });

  const { data, error } = await deps.userDb(jwt).rpc(action.rpc, args);
  if (error) {
    if (error.code === 'P0001') return json(400, { error: error.message ?? 'rejected', message: error.details ?? error.message }, cors);
    if (error.code === '42501') return json(403, { error: 'forbidden', message: error.details ?? 'Not allowed.' }, cors);
    return json(500, { error: 'internal_error' }, cors);          // never leak SQL errors to the browser
  }
  return json(200, { ok: true, data }, cors);
}
