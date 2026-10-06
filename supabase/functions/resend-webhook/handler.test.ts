// Run: npx tsx --test handler.test.ts
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { handle, type Deps } from './handler.ts';

const KEY = Buffer.from('super-secret-key-bytes-1234567890');
const SECRET = 'whsec_' + KEY.toString('base64');
const NOW = 1_800_000_000_000;
function mk(over: Partial<Deps> = {}) {
  const rec: Record<string, unknown>[] = [];
  const deps: Deps = { secret: SECRET, now: () => NOW, record: async a => { rec.push(a); }, ...over };
  return { deps, rec };
}
// independent signer (node:crypto) — not the code under test
const sigOf = (id: string, ts: string, body: string) => 'v1,' + createHmac('sha256', KEY).update(`${id}.${ts}.${body}`).digest('base64');
function post(payload: unknown, o: { id?: string; ts?: string; sig?: string; raw?: string } = {}) {
  const raw = o.raw ?? JSON.stringify(payload); const id = o.id ?? 'msg_1'; const ts = o.ts ?? String(NOW / 1000);
  return new Request('https://x/resend-webhook', { method: 'POST', body: raw, headers: { 'svix-id': id, 'svix-timestamp': ts, 'svix-signature': o.sig ?? sigOf(id, ts, raw) } });
}
const ev = (type: string, data: Record<string, unknown> = { email_id: 're_abc' }) => ({ type, created_at: '2026-10-06T10:00:00.000Z', data });

test('valid signature is accepted and forwarded with the svix-id as event id', async () => {
  const { deps, rec } = mk();
  const r = await handle(post(ev('email.opened')), deps);
  assert.equal(r.status, 200);
  assert.deepEqual(rec, [{ p_provider: 'resend', p_event_id: 'msg_1', p_type: 'email.opened', p_provider_message_id: 're_abc', p_at: '2026-10-06T10:00:00.000Z', p_meta: {} }]);
});
test('bad / missing / tampered signatures are rejected before any parsing or DB call', async () => {
  const { deps, rec } = mk();
  assert.equal((await handle(post(ev('email.opened'), { sig: 'v1,AAAA' }), deps)).status, 400);
  assert.equal((await handle(post(ev('email.opened'), { sig: '' }), deps)).status, 400);
  const raw = JSON.stringify(ev('email.opened')); const good = sigOf('msg_1', String(NOW / 1000), raw);
  assert.equal((await handle(post(null, { raw: raw.replace('re_abc', 're_xyz'), sig: good }), deps)).status, 400);      // body changed
  assert.equal((await handle(post(null, { raw, sig: good.replace('v1,', 'v2,') }), deps)).status, 400);                  // wrong version
  assert.equal((await handle(post(ev('email.opened'), { id: 'msg_other', sig: good }), deps)).status, 400);               // other id
  assert.equal(rec.length, 0);
});
test('multiple signatures in the header (key rotation): any valid one passes', async () => {
  const { deps, rec } = mk(); const raw = JSON.stringify(ev('email.clicked'));
  const sig = 'v1,AAAA ' + sigOf('msg_1', String(NOW / 1000), raw);
  assert.equal((await handle(post(null, { raw, sig }), deps)).status, 200); assert.equal(rec.length, 1);
});
test('replay window: old and future timestamps rejected', async () => {
  const { deps, rec } = mk();
  assert.equal((await handle(post(ev('email.opened'), { ts: String(NOW / 1000 - 301) }), deps)).status, 400);
  assert.equal((await handle(post(ev('email.opened'), { ts: String(NOW / 1000 + 301) }), deps)).status, 400);
  assert.equal((await handle(post(ev('email.opened'), { ts: String(NOW / 1000 - 299) }), deps)).status, 200);
  assert.equal(rec.length, 1);
});
test('bounce details are passed through (type + message, trimmed)', async () => {
  const { deps, rec } = mk();
  await handle(post(ev('email.bounced', { email_id: 're_abc', bounce: { type: 'Permanent', subType: 'General', message: 'x'.repeat(500) } })), deps);
  assert.equal((rec[0].p_meta as Record<string, string>).bounce_type, 'Permanent'); assert.equal((rec[0].p_meta as Record<string, string>).bounce_message.length, 300);
});
test('events we do not act on, or without an email id, are acknowledged without a DB call', async () => {
  const { deps, rec } = mk();
  for (const p of [ev('email.sent'), ev('email.received'), ev('domain.updated'), ev('email.opened', {}), { type: 5 }]) assert.equal((await handle(post(p), deps)).status, 200);
  assert.equal(rec.length, 0);
});
test('DB failure => 500 so Resend retries; wrong method; missing secret; oversized body', async () => {
  assert.equal((await handle(post(ev('email.opened')), mk({ record: async () => { throw new Error('db'); } }).deps)).status, 500);
  assert.equal((await handle(new Request('https://x', { method: 'GET' }), mk().deps)).status, 405);
  assert.equal((await handle(post(ev('email.opened')), mk({ secret: '' }).deps)).status, 500);
  assert.equal((await handle(post(null, { raw: 'x'.repeat(300_000) }), mk().deps)).status, 413);
  assert.equal((await handle(post(null, { raw: 'not json' }), mk().deps)).status, 400 );   // valid signature but invalid JSON
});
