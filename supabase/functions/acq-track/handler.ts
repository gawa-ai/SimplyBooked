// acq-track — PUBLIC (verify_jwt = false) unsubscribe endpoint linked from every outreach email.
//   GET  /unsubscribe?t=<token>  -> confirmation page only (never mutates: mail scanners prefetch links)
//   POST /unsubscribe?t=<token>  -> performs the unsubscribe (button on the page, and RFC 8058 one-click from mail clients)
// Responses are identical for valid / unknown / malformed tokens, so the endpoint cannot be used to probe addresses.
// Per-IP rate limit. Pure handler (testable under Node); index.ts wires Supabase.

export interface Deps {
  rateLimit(key: string, limit: number, windowS: number): Promise<{ allowed: boolean; retry_after_s: number }>;
  unsubscribe(token: string): Promise<void>;       // calls acq.unsubscribe_by_token with the service role
}

const TOKEN = /^[0-9a-f]{32}$/;
const HEADERS: Record<string, string> = {
  'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
};
const page = (title: string, body: string, status = 200, extra: Record<string, string> = {}) =>
  new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>${title}</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#222}button{font:inherit;padding:.6rem 1.2rem;border:0;border-radius:6px;background:#111;color:#fff;cursor:pointer}</style></head>
<body><h1>${title}</h1>${body}</body></html>`, { status, headers: { ...HEADERS, ...extra } });

export function clientIp(req: Request): string {
  const xf = req.headers.get('x-forwarded-for') ?? '';
  const first = xf.split(',')[0]?.trim();
  return (first || req.headers.get('cf-connecting-ip') || 'unknown').slice(0, 64);
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const url = new URL(req.url);
  if (!url.pathname.endsWith('/unsubscribe')) return page('Not found', '<p>This page does not exist.</p>', 404);
  if (req.method !== 'GET' && req.method !== 'POST') return page('Method not allowed', '<p>Not allowed.</p>', 405, { Allow: 'GET, POST' });

  const rl = await deps.rateLimit(`acq-track:${clientIp(req)}`, 30, 60).catch(() => ({ allowed: false, retry_after_s: 30 }));
  if (!rl.allowed) return page('Too many requests', '<p>Please try again in a minute.</p>', 429, { 'Retry-After': String(rl.retry_after_s) });

  const t = (url.searchParams.get('t') ?? '').toLowerCase();
  if (req.method === 'GET') {
    // identical page for every token; the token is only echoed back if it has the right shape (hex), so nothing can be injected
    const hidden = TOKEN.test(t) ? t : '';
    return page('Unsubscribe', `<p>Click the button to stop receiving emails from us.</p>
<form method="post" action="unsubscribe?t=${hidden}"><button type="submit">Unsubscribe</button></form>`);
  }
  if (TOKEN.test(t)) {
    try { await deps.unsubscribe(t); }
    catch { return page('Something went wrong', '<p>We could not process this just now. Please try again in a few minutes.</p>', 500); }
  }
  return page('You are unsubscribed', '<p>You will not receive any more emails from us. Sorry to have bothered you.</p>');
}
