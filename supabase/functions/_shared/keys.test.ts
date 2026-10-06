import { test } from 'node:test';
import assert from 'node:assert/strict';
import { serviceKey, publicKey } from './keys.ts';
const env = (o: Record<string, string>) => (k: string) => o[k];

test('prefers the new key dictionaries', () => {
  const g = env({ SUPABASE_SECRET_KEYS: '{"default":"sb_secret_new"}', SUPABASE_SERVICE_ROLE_KEY: 'legacy-svc',
                  SUPABASE_PUBLISHABLE_KEYS: '{"default":"sb_publishable_new"}', SUPABASE_ANON_KEY: 'legacy-anon' });
  assert.equal(serviceKey(g), 'sb_secret_new');
  assert.equal(publicKey(g), 'sb_publishable_new');
});
test('falls back to the legacy keys (missing, malformed or empty dictionaries)', () => {
  assert.equal(serviceKey(env({ SUPABASE_SERVICE_ROLE_KEY: 'legacy-svc' })), 'legacy-svc');
  assert.equal(serviceKey(env({ SUPABASE_SECRET_KEYS: 'not json', SUPABASE_SERVICE_ROLE_KEY: 'legacy-svc' })), 'legacy-svc');
  assert.equal(publicKey(env({ SUPABASE_PUBLISHABLE_KEYS: '{"default":""}', SUPABASE_ANON_KEY: 'legacy-anon' })), 'legacy-anon');
});
test('named keys and a clear error that never contains a key', () => {
  assert.equal(serviceKey(env({ SUPABASE_SECRET_KEYS: '{"default":"a","acq":"b"}' }), 'acq'), 'b');
  assert.throws(() => serviceKey(env({})), (e: Error) => /not configured/.test(e.message));
  assert.throws(() => publicKey(env({ SUPABASE_SERVICE_ROLE_KEY: 'svc' })), (e: Error) => !e.message.includes('svc'));
});
