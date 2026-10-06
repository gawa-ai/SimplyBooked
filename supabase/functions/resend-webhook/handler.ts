// resend-webhook — receives Resend delivery events (PUBLIC endpoint, authenticated by Svix signature, verify_jwt = false).
// Svix scheme (docs.svix.com/receiving/verifying-payloads/how-manual): signed content = `${svix-id}.${svix-timestamp}.${rawBody}`,
// key = base64-decode(secret after "whsec_"), HMAC-SHA256, base64; header holds space-separated "v1,<sig>" entries; compare in constant time.
// Only events we act on are forwarded to acq.record_delivery_event (service-only). Duplicates are absorbed by svix-id.

export interface Deps {
  secret: string;                                    // whsec_... from Resend (function secret RESEND_WEBHOOK_SECRET)
  now(): number;                                     // ms
  record(args: { p_provider: string; p_event_id: string; p_type: string; p_provider_message_id: string; p_at: string | null; p_meta: Record<string, unknown> }): Promise<void>;
}

const MAX_BODY = 256_000;
const TOLERANCE_S = 300;
const HANDLED = new Set(['email.delivered', 'email.delivery_delayed', 'email.opened', 'email.clicked', 'email.bounced', 'email.complained', 'email.suppressed', 'email.failed']);
const res = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out;
}
function bytesToB64(bytes: Uint8Array): string { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); }
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0;
}
export async function sign(secret: string, id: string, ts: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', b64ToBytes(secret.replace(/^whsec_/, '')) as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return bytesToB64(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.${ts}.${body}`))));
}
export async function verify(deps: Deps, headers: Headers, body: string): Promise<boolean> {
  const id = headers.get('svix-id') ?? '', ts = headers.get('svix-timestamp') ?? '', sigs = headers.get('svix-signature') ?? '';
  if (!id || !/^\d{9,12}$/.test(ts) || !sigs) return false;
  if (Math.abs(deps.now() / 1000 - Number(ts)) > TOLERANCE_S) return false;      // replay window
  let expected: string;
  try { expected = await sign(deps.secret, id, ts, body); } catch { return false; }
  return sigs.split(' ').some(s => { const [v, sig] = s.split(','); return v === 'v1' && !!sig && safeEqual(sig, expected); });
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return res(405, { error: 'method_not_allowed' });
  if (!deps.secret) return res(500, { error: 'not_configured' });
  if (Number(req.headers.get('content-length') ?? '0') > MAX_BODY) return res(413, { error: 'body_too_large' });
  const raw = await req.text();                                   // RAW body: re-serialising JSON would break the signature
  if (raw.length > MAX_BODY) return res(413, { error: 'body_too_large' });
  if (!(await verify(deps, req.headers, raw))) return res(400, { error: 'invalid_signature' });

  let ev: { type?: unknown; created_at?: unknown; data?: Record<string, unknown> };
  try { ev = JSON.parse(raw); } catch { return res(400, { error: 'invalid_json' }); }
  const type = typeof ev.type === 'string' ? ev.type : '';
  const data = ev.data && typeof ev.data === 'object' ? ev.data : {};
  const emailId = typeof data.email_id === 'string' ? data.email_id.slice(0, 100) : '';
  if (!HANDLED.has(type) || !emailId) return res(200, { ok: true, ignored: true });

  const bounce = (data.bounce && typeof data.bounce === 'object' ? data.bounce : {}) as Record<string, unknown>;
  const at = typeof ev.created_at === 'string' && !Number.isNaN(Date.parse(ev.created_at)) ? new Date(ev.created_at).toISOString() : null;
  const meta: Record<string, unknown> = {};
  if (type === 'email.bounced') { meta.bounce_type = String(bounce.type ?? '').slice(0, 30); meta.bounce_message = String(bounce.message ?? '').slice(0, 300); }
  if (type === 'email.failed') meta.reason = String((data.failed as Record<string, unknown> | undefined)?.reason ?? data.reason ?? '').slice(0, 300);

  try {
    await deps.record({ p_provider: 'resend', p_event_id: req.headers.get('svix-id')!, p_type: type, p_provider_message_id: emailId, p_at: at, p_meta: meta });
  } catch { return res(500, { error: 'record_failed' }); }       // non-2xx => Resend retries; svix-id de-dupes if it half-applied
  return res(200, { ok: true });
}
