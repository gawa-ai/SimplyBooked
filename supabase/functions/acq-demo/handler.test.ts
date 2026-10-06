// Run: npx tsx --test handler.test.ts
import test from 'node:test';
import assert from 'node:assert/strict';
import { handle, type Deps } from './handler.ts';

const TOK = 'ab12'.repeat(16);
function mk(over: Partial<Deps> = {}, result: { data?: unknown; error?: { code?: string; message?: string; details?: string } | null } = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = []; const rl: string[] = [];
  const deps: Deps = {
    allowedOrigins: ['https://demo.example.co'],
    rateLimit: async k => { rl.push(k); return { allowed: true, retry_after_s: 0 }; },
    rpc: async (name, args) => { calls.push({ name, args }); return { data: result.data ?? { ok: true, found: true }, error: result.error ?? null }; },
    ...over,
  };
  return { deps, calls, rl };
}
const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request('https://x/acq-demo', { method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.9, 10.0.0.1', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });

test('origin allow-list: exact origin echoed, others blocked, no wildcard; OPTIONS preflight; POST only', async () => {
  const { deps } = mk();
  assert.equal((await handle(post({ action: 'view', token: TOK }, { origin: 'https://evil.example' }), deps)).status, 403);
  const ok = await handle(post({ action: 'view', token: TOK }, { origin: 'https://demo.example.co' }), deps);
  assert.equal(ok.status, 200); assert.equal(ok.headers.get('access-control-allow-origin'), 'https://demo.example.co');
  assert.equal((await handle(new Request('https://x', { method: 'OPTIONS', headers: { origin: 'https://demo.example.co' } }), deps)).status, 204);
  assert.equal((await handle(new Request('https://x', { method: 'GET' }), deps)).status, 405);
});
test('view / click / slots call the matching service RPC with only validated arguments', async () => {
  const { deps, calls } = mk();
  await handle(post({ action: 'view', token: TOK.toUpperCase() }), deps);
  await handle(post({ action: 'click', token: TOK, what: "'; drop table x" }), deps);
  await handle(post({ action: 'slots', token: TOK, from: '2026-11-02', days: 7 }), deps);
  assert.deepEqual(calls.map(c => c.name), ['demo_view', 'demo_click', 'meeting_slots']);
  assert.deepEqual(calls[0].args, { p_token: TOK });
  assert.deepEqual(calls[1].args, { p_token: TOK, p_what: 'cta' });                    // the client cannot choose the click label
  assert.deepEqual(calls[2].args, { p_token: TOK, p_from: '2026-11-02', p_days: 7 });
});
test('malformed tokens look identical to unknown ones and never reach the database or the limiter', async () => {
  const { deps, calls, rl } = mk();
  for (const t of ['', 'zzz', TOK + 'a', "' or 1=1 --", '<script>', 42, null]) {
    const r = await handle(post({ action: 'view', token: t }), deps);
    assert.equal(r.status, 200); assert.deepEqual(await r.json(), { ok: true, found: false });
  }
  assert.equal(calls.length, 0); assert.equal(rl.length, 0);
});
test('unknown actions and bad JSON are rejected; body size is capped', async () => {
  const { deps, calls } = mk();
  for (const a of ['', 'drop', 'constructor', 'demo_view', undefined]) assert.equal((await handle(post({ action: a, token: TOK }), deps)).status, 400);
  assert.equal((await handle(post('not json'), deps)).status, 400);
  assert.equal((await handle(post('[1,2]'), deps)).status, 400);
  assert.equal((await handle(post({ action: 'book', token: TOK, notes: 'x'.repeat(5000) }), deps)).status, 413);
  assert.equal(calls.length, 0);
});
test('slots input validation', async () => {
  const { deps, calls } = mk();
  for (const p of [{ from: '2026-13-45' }, { from: 'tomorrow' }, { days: 0 }, { days: 400 }, { days: 'x' }]) assert.equal((await handle(post({ action: 'slots', token: TOK, ...p }), deps)).status, 400);
  assert.equal(calls.length, 0);
});
const BOOK = { action: 'book', token: TOK, start: '2026-11-03T10:00:00Z', name: 'Dr Demo', email: 'dr@demo-dental.example.co', phone: '07700 900123', notes: 'Prefers mornings' };
test('book: valid request is passed through; the database decides everything else', async () => {
  const { deps, calls } = mk({}, { data: { ok: true, meeting: { starts_at: '2026-11-03T10:00:00Z', timezone: 'Europe/London' } } });
  const r = await handle(post(BOOK), deps);
  assert.equal(r.status, 200); assert.equal(calls[0].name, 'book_meeting');
  assert.deepEqual(calls[0].args, { p_token: TOK, p_start: BOOK.start, p_name: 'Dr Demo', p_email: BOOK.email, p_phone: BOOK.phone, p_notes: 'Prefers mornings' });
});
test('book: bad / hostile fields are rejected before the database', async () => {
  const { deps, calls } = mk();
  const bad: Record<string, unknown>[] = [
    { start: 'next tuesday' }, { start: '2026-11-03T10:00:00' }, { start: '2026-11-03 10:00:00Z' }, { name: 'A' }, { name: '<b>x</b>' }, { name: 5 },
    { email: 'not-an-email' }, { email: 'a@b' }, { email: 'a b@c.co' }, { email: 'a@b.co, c@d.co' }, { phone: 'call me' }, { notes: '<script>alert(1)</script>' }, { notes: 'x'.repeat(501) },
  ];
  for (const p of bad) assert.equal((await handle(post({ ...BOOK, ...p }), deps)).status, 400, JSON.stringify(p));
  assert.equal(calls.length, 0);
});
test('book is rate limited much harder than reads, per IP and per token', async () => {
  const { deps, rl } = mk();
  await handle(post(BOOK), deps);
  assert.ok(rl.some(k => k.includes('203.0.113.9') && k.endsWith(':book')) && rl.some(k => k.includes('acq-demo:tok:')));
  let n = 0;
  const { deps: d2 } = mk({ rateLimit: async () => (++n <= 2 ? { allowed: true, retry_after_s: 0 } : { allowed: false, retry_after_s: 42 }) });
  await handle(post(BOOK), d2);                                        // consumes both checks
  const r = await handle(post(BOOK), d2);
  assert.equal(r.status, 429); assert.equal(r.headers.get('retry-after'), '42');
  const { deps: d3, calls } = mk({ rateLimit: async () => { throw new Error('db down'); } });
  assert.equal((await handle(post(BOOK), d3)).status, 429); assert.equal(calls.length, 0);   // fails closed
});
test('database rule failures are shown (safe business messages); anything else is a generic 500', async () => {
  let r = await handle(post(BOOK), mk({}, { error: { code: 'P0001', message: 'slot_unavailable', details: 'That time was just taken. Please pick another.' } }).deps);
  assert.equal(r.status, 400); assert.deepEqual(await r.json(), { error: 'slot_unavailable', message: 'That time was just taken. Please pick another.' });
  r = await handle(post(BOOK), mk({}, { error: { code: '58000', message: 'relation "acq.secret" does not exist' } }).deps);
  assert.equal(r.status, 500); assert.deepEqual(await r.json(), { error: 'internal_error' });
});
