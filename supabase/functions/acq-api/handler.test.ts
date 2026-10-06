// Run: npx tsx --test handler.test.ts
import test from 'node:test';
import assert from 'node:assert/strict';
import { handle, type Deps } from './handler.ts';

const LEAD = '11111111-2222-4333-8444-555555555555';
function mk(over: Partial<Deps> = {}, rpcResult: { data?: unknown; error?: { code?: string; message?: string; details?: string } | null } = {}) {
  const calls: { name: string; args: Record<string, unknown>; jwt: string }[] = [];
  const rl: string[] = [];
  const deps: Deps = {
    allowedOrigins: ['https://app.example.com'],
    getUserId: async jwt => (jwt === 'good' ? 'user-1' : null),
    userDb: jwt => ({ rpc: async (name, args) => { calls.push({ name, args, jwt }); return { data: rpcResult.data ?? { ok: true }, error: rpcResult.error ?? null }; } }),
    rateLimit: async key => { rl.push(key); return { allowed: true, retry_after_s: 0 }; },
    ...over,
  };
  return { deps, calls, rl };
}
const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request('https://x/acq-api', { method: 'POST', headers: { authorization: 'Bearer good', 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });

test('rejects missing / invalid JWT', async () => {
  const { deps } = mk();
  assert.equal((await handle(post({ action: 'move_lead' }, { authorization: '' }), deps)).status, 401);
  assert.equal((await handle(post({ action: 'move_lead' }, { authorization: 'Bearer nope' }), deps)).status, 401);
});
test('origin allow-list: unknown origin blocked, known origin gets exact CORS header (no wildcard)', async () => {
  const { deps } = mk();
  assert.equal((await handle(post({}, { origin: 'https://evil.example' }), deps)).status, 403);
  const ok = await handle(post({ action: 'requalify_lead', params: { lead_id: LEAD } }, { origin: 'https://app.example.com' }), deps);
  assert.equal(ok.status, 200); assert.equal(ok.headers.get('access-control-allow-origin'), 'https://app.example.com');
  const pre = await handle(new Request('https://x', { method: 'OPTIONS', headers: { origin: 'https://app.example.com' } }), deps);
  assert.equal(pre.status, 204);
});
test('only POST', async () => { assert.equal((await handle(new Request('https://x', { method: 'GET' }), mk().deps)).status, 405); });
test('unknown / prototype action names rejected', async () => {
  const { deps, calls } = mk();
  for (const a of ['drop_everything', 'constructor', '__proto__', 'toString', '']) assert.equal((await handle(post({ action: a }), deps)).status, 400);
  assert.equal(calls.length, 0);
});
test('input validation happens before any database call', async () => {
  const { deps, calls } = mk();
  const bad: [string, unknown][] = [
    ['move_lead', { lead_id: 'not-a-uuid', to: 'won' }], ['move_lead', { lead_id: LEAD, to: 'superstar' }],
    ['move_lead', { lead_id: LEAD, to: 'lost', reason: 'x'.repeat(201) }],
    ['import_leads', { items: [] }], ['import_leads', { items: Array(201).fill({ business_name: 'x' }) }], ['import_leads', { items: ['str'] }],
    ['queue_search_run', { source_key: 'osm', niche: 'dentist', country: 'GBR' }], ['queue_search_run', { source_key: 'osm', niche: 'd', country: 'GB' }],
    ['queue_search_run', { source_key: 'osm', niche: 'dentist', country: 'GB', max_results: 500 }],
  ];
  for (const [action, params] of bad) assert.equal((await handle(post({ action, params }), deps)).status, 400, action + JSON.stringify(params).slice(0, 60));
  assert.equal(calls.length, 0);
});
test('valid call runs the allow-listed RPC with the CALLER jwt and mapped args', async () => {
  const { deps, calls, rl } = mk();
  const r = await handle(post({ action: 'move_lead', params: { lead_id: LEAD, to: 'lost', reason: ' no budget ' } }), deps);
  assert.equal(r.status, 200);
  assert.deepEqual(calls[0], { name: 'move_lead', jwt: 'good', args: { p_lead: LEAD, p_to: 'lost', p_reason: 'no budget' } });
  assert.deepEqual(rl, ['acq-api:user-1:move_lead']);
  const q = await handle(post({ action: 'queue_search_run', params: { source_key: 'osm', niche: 'Dentists', city: 'Bristol', country: 'gb' } }), deps);
  assert.equal(q.status, 200); assert.equal(calls[1].args.p_country, 'GB'); assert.equal(calls[1].args.p_max, 20);
});
test('extra / unexpected params are dropped, not forwarded', async () => {
  const { deps, calls } = mk();
  await handle(post({ action: 'requalify_lead', params: { lead_id: LEAD, org_id: 'other-org', p_lead: 'x', role: 'owner' } }), deps);
  assert.deepEqual(Object.keys(calls[0].args), ['p_lead']);
});
test('rate limit returns 429 with Retry-After and does not call the database', async () => {
  const { deps, calls } = mk({ rateLimit: async () => ({ allowed: false, retry_after_s: 17 }) });
  const r = await handle(post({ action: 'requalify_lead', params: { lead_id: LEAD } }), deps);
  assert.equal(r.status, 429); assert.equal(r.headers.get('retry-after'), '17'); assert.equal(calls.length, 0);
});
test('rate limiter outage fails closed', async () => {
  const { deps, calls } = mk({ rateLimit: async () => { throw new Error('db down'); } });
  assert.equal((await handle(post({ action: 'requalify_lead', params: { lead_id: LEAD } }), deps)).status, 429);
  assert.equal(calls.length, 0);
});
test('database errors map to safe responses (no SQL leakage)', async () => {
  const body = { action: 'requalify_lead', params: { lead_id: LEAD } };
  let r = await handle(post(body), mk({}, { error: { code: 'P0001', message: 'invalid_transition', details: 'Cannot move a lead from new_lead to won.' } }).deps);
  assert.equal(r.status, 400); assert.deepEqual(await r.json(), { error: 'invalid_transition', message: 'Cannot move a lead from new_lead to won.' });
  r = await handle(post(body), mk({}, { error: { code: '42501', message: 'forbidden', details: 'Requires role member or higher.' } }).deps);
  assert.equal(r.status, 403);
  r = await handle(post(body), mk({}, { error: { code: '23505', message: 'duplicate key value violates unique constraint "leads_uq_domain"' } }).deps);
  assert.equal(r.status, 500); assert.deepEqual(await r.json(), { error: 'internal_error' });
});
test('oversized and malformed bodies', async () => {
  const { deps } = mk();
  assert.equal((await handle(post('{not json'), deps)).status, 400);
  assert.equal((await handle(post('[1,2]'), deps)).status, 400);
  assert.equal((await handle(post({ action: 'import_leads', params: { items: [{ business_name: 'x'.repeat(1_100_000) }] } }), deps)).status, 413);
});

test('phase 3 actions: approve_message validates ids and forwards to the right RPC with the caller JWT', async () => {
  const { deps, calls } = mk();
  assert.equal((await handle(post({ action: 'approve_message', params: { message_id: 'nope' } }), deps)).status, 400);
  assert.equal((await handle(post({ action: 'approve_message', params: { message_id: LEAD, body: 'x' } }), deps)).status, 400);   // edited body too short
  const ok = await handle(post({ action: 'approve_message', params: { message_id: LEAD } }), deps);
  assert.equal(ok.status, 200);
  assert.deepEqual(calls.map(c => [c.name, c.jwt]), [['approve_message', 'good']]);
  assert.equal(calls[0].args.p_message, LEAD);
});
test('approve_messages caps the batch and validates every id', async () => {
  const { deps, calls } = mk();
  assert.equal((await handle(post({ action: 'approve_messages', params: { message_ids: [] } }), deps)).status, 400);
  assert.equal((await handle(post({ action: 'approve_messages', params: { message_ids: Array(51).fill(LEAD) } }), deps)).status, 400);
  assert.equal((await handle(post({ action: 'approve_messages', params: { message_ids: [LEAD, 'bad'] } }), deps)).status, 400);
  assert.equal((await handle(post({ action: 'approve_messages', params: { message_ids: [LEAD, LEAD] } }), deps)).status, 200);
  assert.equal(calls.length, 1);
});
test('update_setting / set_outreach_enabled: shape checks; DB errors map to 400/403 without leaking SQL', async () => {
  const { deps } = mk();
  assert.equal((await handle(post({ action: 'update_setting', params: { key: 'Bad Key', value: 1 } }), deps)).status, 400);
  assert.equal((await handle(post({ action: 'update_setting', params: { key: 'qualify_threshold' } }), deps)).status, 400);
  assert.equal((await handle(post({ action: 'set_outreach_enabled', params: { enabled: 'yes' } }), deps)).status, 400);
  const f = mk({}, { error: { code: '42501', message: 'forbidden', details: 'Only an owner can change sender.' } });
  const r = await handle(post({ action: 'update_setting', params: { key: 'sender', value: {} } }), f.deps);
  assert.equal(r.status, 403); assert.match(JSON.stringify(await r.json()), /Only an owner/);
  const s = mk({}, { error: { code: '23505', message: 'duplicate key value violates unique constraint "x"' } });
  const r2 = await handle(post({ action: 'set_outreach_enabled', params: { enabled: true } }), s.deps);
  assert.equal(r2.status, 500); assert.doesNotMatch(await r2.text(), /duplicate key/);
});

// ---- Phase 4 actions
const RID = '22222222-3333-4444-8555-666666666666';
test('phase 4: reply / demo / meeting actions map to the right RPC with validated, renamed arguments', async () => {
  const { deps, calls } = mk();
  const send = (action: string, params: Record<string, unknown>) => handle(post({ action, params }), deps);
  assert.equal((await send('approve_reply_response', { reply_id: RID })).status, 200);
  assert.equal((await send('edit_reply_response', { reply_id: RID, body: 'Thanks for replying, would Thursday afternoon suit you?' })).status, 200);
  assert.equal((await send('send_demo', { demo_id: RID, subject: 'Your demo', body: 'Hi, here is the short demo we talked about. Let me know what you think.' })).status, 200);
  assert.equal((await send('schedule_meeting', { lead_id: LEAD, start: '2026-11-03T10:00:00Z', attendee_email: 'a@b.example.co' })).status, 200);
  assert.equal((await send('set_meeting_outcome', { meeting_id: RID, status: 'completed', outcome: 'won' })).status, 200);
  assert.deepEqual(calls.map(c => c.name), ['approve_reply_response', 'edit_reply_response', 'send_demo', 'schedule_meeting', 'set_meeting_outcome']);
  assert.deepEqual(calls[0].args, { p_reply: RID, p_body: null });
  assert.deepEqual(calls[3].args, { p_lead: LEAD, p_start: '2026-11-03T10:00:00Z', p_duration_min: 30, p_title: 'Intro call', p_channel: 'google_meet', p_attendee_name: null, p_attendee_email: 'a@b.example.co', p_notes: null });
  assert.ok(calls.every(c => c.jwt === 'good'));                       // always the caller's JWT, never a service role
});
test('phase 4: invalid shapes are rejected before the database', async () => {
  const { deps, calls } = mk();
  const bad: [string, Record<string, unknown>][] = [
    ['approve_reply_response', { reply_id: 'nope' }], ['edit_reply_response', { reply_id: RID, body: 'short' }], ['send_demo', { demo_id: RID, subject: 'x' }],
    ['create_demo', { lead_id: LEAD, config: 'string' }], ['create_demo', { lead_id: LEAD, config: { x: 'y'.repeat(5000) } }],
    ['schedule_meeting', { lead_id: LEAD, start: 'tomorrow' }], ['schedule_meeting', { lead_id: LEAD, start: '2026-11-03T10:00:00Z', duration_min: 5 }],
    ['schedule_meeting', { lead_id: LEAD, start: '2026-11-03T10:00:00Z', channel: 'carrier_pigeon' }], ['schedule_meeting', { lead_id: LEAD, start: '2026-11-03T10:00:00Z', attendee_email: 'a@b.co, c@d.co' }],
    ['set_meeting_outcome', { meeting_id: RID, status: 'finished' }], ['set_meeting_outcome', { meeting_id: RID, status: 'completed', outcome: 'maybe' }], ['match_reply_manually', { reply_id: RID }],
  ];
  for (const [action, params] of bad) assert.equal((await handle(post({ action, params }), deps)).status, 400, action + JSON.stringify(params));
  assert.equal(calls.length, 0);
});

// ---- Phase 5 actions
const FID = '33333333-4444-4555-8666-777777777777';
test('phase 5: follow-up / onboarding / metrics actions map to the right RPC with validated arguments (caller JWT only)', async () => {
  const { deps, calls } = mk();
  const send = (action: string, params: Record<string, unknown>) => handle(post({ action, params }), deps);
  assert.equal((await send('cancel_lead_followups', { lead_id: LEAD })).status, 200);
  assert.equal((await send('skip_followup', { followup_id: FID })).status, 200);
  assert.equal((await send('set_followup_due', { followup_id: FID, due_at: '2026-11-03T09:30:00+00:00' })).status, 200);
  assert.equal((await send('convert_lead_to_client', { lead_id: LEAD })).status, 200);
  assert.equal((await send('update_client_config', { client_id: FID, section: 'faqs', value: [{ q: 'Do you take card?', a: 'Yes, card only.' }] })).status, 200);
  assert.equal((await send('set_client_status', { client_id: FID, status: 'active' })).status, 200);
  assert.equal((await send('provision_bos_business', { client_id: FID })).status, 200);
  assert.equal((await send('dashboard_metrics', {})).status, 200);
  assert.equal((await send('performance_breakdown', { dimension: 'niche', days: 30 })).status, 200);
  assert.deepEqual(calls.map(c => c.name), ['cancel_lead_followups', 'skip_followup', 'set_followup_due', 'convert_lead_to_client', 'update_client_config',
    'set_client_status', 'provision_bos_business', 'dashboard_metrics', 'performance_breakdown']);
  assert.deepEqual(calls[2].args, { p_followup: FID, p_due: '2026-11-03T09:30:00+00:00' });
  assert.deepEqual(calls[4].args, { p_client: FID, p_section: 'faqs', p_value: [{ q: 'Do you take card?', a: 'Yes, card only.' }] });
  assert.deepEqual(calls[7].args, { p_days: 90 });
  assert.deepEqual(calls[8].args, { p_dim: 'niche', p_days: 30 });
  assert.ok(calls.every(c => c.jwt === 'good'));
});
test('phase 5: invalid shapes are rejected before the database', async () => {
  const { deps, calls } = mk();
  const bad: [string, Record<string, unknown>][] = [
    ['skip_followup', { followup_id: 'x' }], ['set_followup_due', { followup_id: FID, due_at: 'next week' }], ['set_followup_due', { followup_id: FID, due_at: '2026-11-03T09:30:00' }],
    ['update_client_config', { client_id: FID, section: 'secrets', value: {} }], ['update_client_config', { client_id: FID, section: 'faqs', value: 'text' }],
    ['update_client_config', { client_id: FID, section: 'faqs', value: { a: 'x'.repeat(21000) } }], ['set_client_status', { client_id: FID, status: 'deleted' }],
    ['dashboard_metrics', { days: 0 }], ['dashboard_metrics', { days: 'all' }], ['performance_breakdown', { dimension: 'email' }],
    ['performance_breakdown', { dimension: 'niche; drop' }], ['provision_bos_business', {}],
  ];
  for (const [action, params] of bad) assert.equal((await handle(post({ action, params }), deps)).status, 400, action + JSON.stringify(params));
  assert.equal(calls.length, 0);
});
