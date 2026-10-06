// acq-demo — PUBLIC JSON API (verify_jwt = false) behind the personalised demo page.
//   POST { action: 'view' | 'click' | 'slots' | 'book', token, ... }
// The 64-hex demo token is the only credential. Unknown / expired / revoked tokens all answer { ok:true, found:false }.
// Exposes nothing about the lead (the database returns only the demo content + offered slots). Exact-origin CORS allow-list,
// small body limit, per-IP and per-token rate limits (booking is much stricter). Pure handler; index.ts wires Supabase.

export interface Deps {
  allowedOrigins: string[];
  rateLimit(key: string, limit: number, windowS: number): Promise<{ allowed: boolean; retry_after_s: number }>;
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: { code?: string; message?: string; details?: string } | null }>;  // service role, service-only RPCs
}

const TOKEN = /^[0-9a-f]{64}$/;
const EMAIL = /^[^\s@<>"',;:]{1,64}@[^\s@<>"',;:]{1,200}\.[a-z]{2,24}$/i;
const MAX_BODY = 4_000;
class Bad extends Error { constructor(public field: string, msg: string) { super(msg); } }

const text = (v: unknown, f: string, min: number, max: number, opt = false): string | null => {
  if (v === undefined || v === null || v === '') { if (opt) return null; throw new Bad(f, f + ' is required'); }
  if (typeof v !== 'string') throw new Bad(f, f + ' must be text');
  const t = v.trim();
  if (t.length < min || t.length > max) throw new Bad(f, `${f} must be ${min}-${max} characters`);
  if (/[<>\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(t)) throw new Bad(f, f + ' contains characters that are not allowed');
  return t;
};

export function clientIp(req: Request): string {
  const first = (req.headers.get('x-forwarded-for') ?? '').split(',')[0]?.trim();
  return (first || req.headers.get('cf-connecting-ip') || 'unknown').slice(0, 64);
}
const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers } });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const origin = req.headers.get('origin');
  const cors: Record<string, string> = {};
  if (origin) {
    if (!deps.allowedOrigins.includes(origin)) return json(403, { error: 'origin_not_allowed' });
    Object.assign(cors, { 'Access-Control-Allow-Origin': origin, 'Vary': 'Origin', 'Access-Control-Allow-Headers': 'content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' });
  }
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' }, cors);

  if (Number(req.headers.get('content-length') ?? '0') > MAX_BODY) return json(413, { error: 'body_too_large' }, cors);
  const raw = await req.text();
  if (raw.length > MAX_BODY) return json(413, { error: 'body_too_large' }, cors);
  let b: Record<string, unknown>;
  try { const p = JSON.parse(raw); if (!p || typeof p !== 'object' || Array.isArray(p)) throw 0; b = p; } catch { return json(400, { error: 'invalid_json' }, cors); }

  const action = typeof b.action === 'string' ? b.action : '';
  if (!['view', 'click', 'slots', 'book'].includes(action)) return json(400, { error: 'unknown_action' }, cors);
  const token = typeof b.token === 'string' ? b.token.toLowerCase() : '';
  // a malformed token gets the same answer as an unknown one, without touching the database
  if (!TOKEN.test(token)) return json(200, { ok: true, found: false }, cors);

  const ip = clientIp(req);
  const caps: Record<string, [number, number]> = { view: [60, 60], click: [30, 60], slots: [40, 60], book: [5, 300] };   // per IP
  const [lim, win] = caps[action];
  const tokKey = token.slice(0, 16);
  for (const [k, l, w] of [[`acq-demo:ip:${ip}:${action}`, lim, win], [`acq-demo:tok:${tokKey}:${action}`, lim * 2, win]] as [string, number, number][]) {
    const rl = await deps.rateLimit(k, l, w).catch(() => ({ allowed: false, retry_after_s: 30 }));
    if (!rl.allowed) return json(429, { error: 'rate_limited', retry_after_s: rl.retry_after_s }, { ...cors, 'Retry-After': String(rl.retry_after_s) });
  }

  let name: string; let args: Record<string, unknown>;
  try {
    if (action === 'view') { name = 'demo_view'; args = { p_token: token }; }
    else if (action === 'click') { name = 'demo_click'; args = { p_token: token, p_what: 'cta' }; }
    else if (action === 'slots') {
      let from: string | null = null;
      if (b.from !== undefined && b.from !== null && b.from !== '') {
        if (typeof b.from !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(b.from) || Number.isNaN(Date.parse(b.from))) throw new Bad('from', 'from must be YYYY-MM-DD');
        from = b.from;
      }
      const days = b.days === undefined ? 14 : Number(b.days);
      if (!Number.isInteger(days) || days < 1 || days > 31) throw new Bad('days', 'days must be 1-31');
      name = 'meeting_slots'; args = { p_token: token, p_from: from, p_days: days };
    } else {
      const start = text(b.start, 'start', 20, 40)!;
      if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(start) || Number.isNaN(Date.parse(start))) throw new Bad('start', 'start must be an ISO time with a timezone, as returned by slots');
      const email = text(b.email, 'email', 6, 254)!;
      if (!EMAIL.test(email)) throw new Bad('email', 'email does not look valid');
      const phone = text(b.phone, 'phone', 6, 30, true);
      if (phone && !/^[0-9+()\-.\s]{6,30}$/.test(phone)) throw new Bad('phone', 'phone does not look valid');
      name = 'book_meeting';
      args = { p_token: token, p_start: start, p_name: text(b.name, 'name', 2, 100), p_email: email, p_phone: phone, p_notes: text(b.notes, 'notes', 1, 500, true) };
    }
  } catch (e) { if (e instanceof Bad) return json(400, { error: 'invalid_input', field: e.field, message: e.message }, cors); throw e; }

  const { data, error } = await deps.rpc(name, args);
  if (error) return json(error.code === 'P0001' ? 400 : 500, error.code === 'P0001' ? { error: error.message ?? 'rejected', message: error.details ?? error.message } : { error: 'internal_error' }, cors);
  return json(200, data, cors);
}
