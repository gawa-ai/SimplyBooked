// Run: npx tsx --test handler.test.ts
import test from 'node:test';
import assert from 'node:assert/strict';
import { handle, type Deps } from './handler.ts';

const TOK = 'a'.repeat(32);
function mk(over: Partial<Deps> = {}) {
  const unsub: string[] = [], rl: string[] = [];
  const deps: Deps = { rateLimit: async k => { rl.push(k); return { allowed: true, retry_after_s: 0 }; }, unsubscribe: async t => { unsub.push(t); }, ...over };
  return { deps, unsub, rl };
}
const req = (method: string, path: string, headers: Record<string, string> = {}) => new Request('https://x.example/acq-track' + path, { method, headers });

test('GET shows a confirmation page and never unsubscribes (link scanners prefetch)', async () => {
  const { deps, unsub } = mk();
  const r = await handle(req('GET', `/unsubscribe?t=${TOK}`), deps);
  assert.equal(r.status, 200); assert.match(await r.text(), /<form method="post"/); assert.equal(unsub.length, 0);
});
test('POST unsubscribes (button + RFC 8058 one-click) and answers the same for unknown tokens', async () => {
  const { deps, unsub } = mk();
  const a = await handle(req('POST', `/unsubscribe?t=${TOK}`), deps);
  const b = await handle(req('POST', `/unsubscribe?t=${'0'.repeat(32)}`), deps);
  assert.equal(a.status, 200); assert.equal(await a.text(), await b.text());
  assert.deepEqual(unsub, [TOK, '0'.repeat(32)]);
});
test('malformed tokens never reach the database and the page is the same', async () => {
  const { deps, unsub } = mk();
  for (const t of ['', 'zzz', "'; drop table x;--", TOK + 'a', '<script>']) {
    const r = await handle(req('POST', `/unsubscribe?t=${encodeURIComponent(t)}`), deps);
    assert.equal(r.status, 200);
  }
  assert.equal(unsub.length, 0);
});
test('GET page cannot be used for reflected XSS', async () => {
  const { deps } = mk();
  const body = await (await handle(req('GET', `/unsubscribe?t=${encodeURIComponent('"><script>alert(1)</script>')}`), deps)).text();
  assert.doesNotMatch(body, /<script>alert/); assert.match(body, /unsubscribe\?t="/);
});
test('rate limited per client IP', async () => {
  const { deps, rl } = mk({ rateLimit: async k => ({ allowed: false, retry_after_s: 12 }) });
  const r = await handle(req('POST', `/unsubscribe?t=${TOK}`, { 'x-forwarded-for': '203.0.113.9, 10.0.0.1' }), deps);
  assert.equal(r.status, 429); assert.equal(r.headers.get('retry-after'), '12');
  const ok = mk(); await handle(req('GET', `/unsubscribe?t=${TOK}`, { 'x-forwarded-for': '203.0.113.9, 10.0.0.1' }), ok.deps);
  assert.deepEqual(ok.rl, ['acq-track:203.0.113.9']);
});
test('limiter outage fails closed; DB outage is a retryable 500, not a false "unsubscribed"', async () => {
  const bad = mk({ rateLimit: async () => { throw new Error('db down'); } });
  assert.equal((await handle(req('POST', `/unsubscribe?t=${TOK}`), bad.deps)).status, 429);
  const down = mk({ unsubscribe: async () => { throw new Error('db down'); } });
  assert.equal((await handle(req('POST', `/unsubscribe?t=${TOK}`), down.deps)).status, 500);
});
test('security headers, other methods and paths', async () => {
  const { deps } = mk();
  const r = await handle(req('GET', `/unsubscribe?t=${TOK}`), deps);
  assert.match(r.headers.get('content-security-policy')!, /default-src 'none'/); assert.equal(r.headers.get('x-frame-options'), 'DENY');
  assert.equal((await handle(req('DELETE', `/unsubscribe?t=${TOK}`), deps)).status, 405);
  assert.equal((await handle(req('GET', '/admin'), deps)).status, 404);
});
