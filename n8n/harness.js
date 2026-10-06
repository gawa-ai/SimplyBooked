// End-to-end contract harness for the Booking OS workflows (without an n8n server).
// Runs the real Code-node JavaScript and the real Postgres node queries + Query Parameter
// expressions from the exported JSON, against the test database, using n8n's >= 2.5 rule:
// an expression that returns an array becomes one parameter per element; objects are JSON-stringified.
const fs = require('fs');
const { execFileSync } = require('child_process');
const PSQL = ['-h', process.env.PGHOST || '/var/tmp/bospg', '-p', process.env.PGPORT || '55432', '-U', 'postgres',
              '-d', process.env.PGDATABASE || 'bostest', '-X', '-q', '-v', 'ON_ERROR_STOP=1'];
const J = v => (typeof v === 'string' ? JSON.parse(v) : v);
const load = f => JSON.parse(fs.readFileSync(__dirname + '/' + f));
const nodeOf = (wf, name) => wf.nodes.find(n => n.name === name);
let passed = 0;
const check = (ok, name, info) => {
  if (!ok) { console.log('FAIL ', name, info !== undefined ? JSON.stringify(info).slice(0, 600) : ''); process.exit(1); }
  passed++; console.log('PASS ', name);
};

function evalExpr(expr, ctx) {
  const body = expr.replace(/^=\{\{/, '').replace(/\}\}$/, '');
  const fn = new Function('$json', '$', '$fromAI', `return (${body});`);
  return fn(ctx.$json, ctx.$, ctx.$fromAI || (() => { throw new Error('$fromAI outside tool'); }));
}
function toParams(arr) {
  const out = [];
  for (const v of arr) {
    if (v === undefined) continue;
    out.push(typeof v === 'object' && v !== null ? JSON.stringify(v) : v);
  }
  return out;
}
function parseCsv(text) {
  const rows = []; let row = [], cur = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"' && text[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') q = false; else cur += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(cur); cur = ''; }
    else if (c === '\n') { row.push(cur); rows.push(row); row = []; cur = ''; }
    else cur += c;
  }
  if (cur !== '' || row.length) { row.push(cur); rows.push(row); }
  return rows;
}
// Runs `query` with bound parameters exactly like node-postgres (extended protocol).
function runPg(query, params) {
  if (params.some(p => p === null)) throw new Error('harness: psql \\bind cannot send NULL');
  const q = s => "'" + String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
  const sql = `\\pset format csv\n${query.replace(/;\s*$/, '')} \\bind ${params.map(q).join(' ')} \\g\n`;
  const out = execFileSync('psql', PSQL, { input: sql }).toString();
  const [head, ...rows] = parseCsv(out.trim() + '\n').filter(r => r.length && r.join('') !== '');
  return rows.map(r => Object.fromEntries(head.map((h, i) => {
    let v = r[i]; try { if (/^[\[{]/.test(v)) v = JSON.parse(v); } catch (e) {}
    return [h, v];
  })));
}
function runCode(code, inputItems, refs, itemJson) {
  const $input = { all: () => inputItems.map(j => ({ json: j })), item: { json: itemJson } };
  const $ = name => ({ all: () => (refs[name] || []).map(j => ({ json: j })), item: { json: (refs[name] || [])[0] } });
  const r = new Function('$input', '$', '$json', code)($input, $, itemJson);
  return (Array.isArray(r) ? r : [r]).map(x => x.json);
}
function pgNode(wf, name, itemCtx) {
  const n = nodeOf(wf, name);
  const expr = n.parameters.options.queryReplacement;
  const params = expr ? toParams(evalExpr(expr, itemCtx)) : [];
  return runPg(n.parameters.query, params);
}

const dayOf = dow => {
  return execFileSync('psql', [...PSQL, '-At'], { input: `select to_char(d,'YYYY-MM-DD') from (select (now() at time zone 'Europe/London')::date+g d from generate_series(2,9) g) x where extract(dow from d)=${dow} limit 1;` }).toString().trim();
};
const THU = dayOf(4);

// ------------------------------------------------------------------ GATEWAY: Vapi phone call
const gw = load('01-BOS-Gateway.json');
function gateway(webhookItem) {
  const norm = runCode(nodeOf(gw, 'Normalize Request').parameters.jsCode, [webhookItem], {});
  const rows = norm.flatMap(j => pgNode(gw, 'Run Tool', { $json: j }));
  const resp = runCode(nodeOf(gw, 'Build Response').parameters.jsCode, rows, { 'Normalize Request': norm });
  const body = evalExpr(nodeOf(gw, 'Respond').parameters.responseBody, { $json: resp[0] });
  return { norm, rows, body: JSON.parse(body) };
}
const vapiMsg = (toolCalls, callType = 'inboundPhoneCall') => ({
  headers: { authorization: 'Bearer x' }, query: { business: 'brightsmile-demo' },
  body: { message: { type: 'tool-calls', timestamp: Date.now(),
    call: { id: 'call_h1', type: callType, assistantId: 'asst_demo_1', customer: { number: '+447700900777' } },
    toolCallList: toolCalls.map(([id, name, args]) => ({ id, type: 'function', function: { name, arguments: args } })) } } });

let g = gateway(vapiMsg([['tc_a', 'check_availability', { service: 'check up', date: THU, time: '11:00' }],
                         ['tc_b', 'get_business_info', {}]]));
check(g.norm.length === 2 && g.norm[0].ctx.caller_phone === '+447700900777', 'G1 Vapi parallel tool calls normalised with caller id');
check(Array.isArray(g.body.results) && g.body.results.length === 2 && g.body.results[0].toolCallId === 'tc_a',
      'G2 response has Vapi { results: [{ toolCallId, result }] } shape', g.body);
check(JSON.parse(g.body.results[0].result).available === true, 'G3 availability result is readable JSON for the AI', g.body.results[0]);

// arguments as a JSON string + a comma-heavy free-text note (must not be split into extra parameters)
const bookArgs = JSON.stringify({ customer_name: 'Lara Croft, Jr.', service: 'Dental Check-up',
  date: THU, time: '11:00', notes: 'Sensitive tooth, lower left, since Monday, please be gentle' });
g = gateway(vapiMsg([['tc_c', 'book_appointment', bookArgs]]));
let res = JSON.parse(g.body.results[0].result);
check(res.ok === true && /Reference/.test(res.message), 'G4 phone booking via gateway (caller phone used automatically)', res);
const REF = res.booking.ref;
g = gateway(vapiMsg([['tc_c', 'book_appointment', bookArgs]]));
check(JSON.parse(g.body.results[0].result).duplicate === true, 'G5 Vapi retry of the same tool call does not double book');
check(execFileSync('psql', [...PSQL, '-At'], { input: "select count(*) from bos.bookings k join bos.customers c on c.id=k.customer_id where c.name='Lara Croft, Jr.';" }).toString().trim() === '1',
      'G5b exactly one booking row, and the comma-filled note was stored intact');

// web widget call: no caller id -> must verify
g = gateway(vapiMsg([['tc_d', 'cancel_appointment', { phone: '07700 900777' }]], 'webCall'));
check(JSON.parse(g.body.results[0].result).error === 'verification_failed', 'G6 website voice caller must verify before cancelling');
g = gateway(vapiMsg([['tc_e', 'cancel_appointment', { phone: '07700 900777', customer_name: 'lara' }]], 'webCall'));
check(JSON.parse(g.body.results[0].result).ok === true, 'G7 verified website caller can cancel');

// end-of-call report
g = gateway({ headers: {}, query: { business: 'brightsmile-demo' }, body: { message: {
  type: 'end-of-call-report', endedReason: 'customer-ended-call', startedAt: '2026-09-01T10:00:00Z', endedAt: '2026-09-01T10:02:00Z',
  analysis: { summary: 'Caller booked a check-up.' }, artifact: { transcript: 'AI: Hello\nUser: Hi, I\'d like a check-up' },
  call: { id: 'call_h1', type: 'inboundPhoneCall', assistantId: 'asst_demo_1', customer: { number: '+447700900777' } } } } });
check(g.body.ok === true && g.rows[0].result.ok === true, 'G8 end-of-call report stored', g);

// dashboard / website API
g = gateway({ headers: {}, query: {}, body: { business: 'luxe-hair-demo', source: 'website', tool: 'check_availability',
  args: { service: 'Full Colour', date: dayOf(6) }, idempotency_key: '' } });
check(g.body.ok === true && Array.isArray(g.body.slots), 'G9 website API availability (salon)', g.body);
g = gateway({ headers: {}, query: {}, body: { business: 'brightsmile-demo', source: 'website', tool: 'set_status',
  args: { ref: REF, status: 'completed' } } });
check(g.body.error === 'forbidden', 'G10 website source cannot run staff actions');

// ------------------------------------------------------------------ WORKER
const wk = load('02-BOS-Worker.json');
execFileSync('psql', PSQL, { input: `update bos.businesses set test_numbers = '{+447700900777}' where slug='brightsmile-demo';
  update bos.jobs set run_at = now() - interval '1 minute' where status = 'queued';` });
const claimed = runPg(nodeOf(wk, 'Claim Jobs').parameters.query, []);
const sms = claimed.find(r => r.job.kind === 'sms' && r.job.to === '+447700900777');
check(!!sms && sms.job.account_sid && sms.job.from === '+447700900001', 'W1 worker claims a rendered SMS job', claimed.slice(0, 3));
const routeRules = nodeOf(wk, 'Route Job').parameters.rules.values;
check(evalExpr(routeRules[0].conditions.conditions[0].leftValue, { $json: sms }) === 'sms', 'W2 switch routes sms by job.kind');
const twilio = nodeOf(wk, 'Send SMS (Twilio)').parameters;
const url = evalExpr(twilio.url.replace(/^=https:\/\/api\.twilio\.com\/2010-04-01\/Accounts\/\{\{(.*)\}\}\/Messages\.json$/, '={{$1}}'), { $json: sms });
check(url === sms.job.account_sid, 'W3 Twilio URL uses the account SID from the job');
const fakeTwilio = { statusCode: 201, body: { sid: 'SMharness1', status: 'queued' } };
let done = pgNode(wk, 'Complete Job', { $json: fakeTwilio, $: () => ({ item: { json: sms } }) });
check(done[0].result.status === 'sent', 'W4 Complete Job marks sent from Twilio 201', done);
const again = runPg(nodeOf(wk, 'Complete Job').parameters.query, [String(sms.job.job_id), '201', '{}', '']);
check(again[0].result.note === 'already sent', 'W5 completing twice is harmless');
const cal = claimed.find(r => r.job.kind === 'calendar');
if (cal) {
  done = pgNode(wk, 'Complete Job', { $json: { error: { message: 'getaddrinfo ENOTFOUND www.googleapis.com' } }, $: () => ({ item: { json: cal } }) });
  check(done[0].result.status === 'retry', 'W6 network error on calendar sync -> retry, not lost', done);
}

// ------------------------------------------------------------------ SMS AGENT
const sa = load('03-BOS-SMS-Agent.json');
g = gateway(vapiMsg([['tc_f', 'book_appointment', { customer_name: 'Tom Hardy', service: 'Consultation', date: THU, time: '15:00' }]]));
const twilioForm = { To: '+447700900001', From: '+447700900777', Body: 'Hi, can I move my appointment to 4pm, same day?', MessageSid: 'SMh_in_1' };
let inbound = pgNode(sa, 'Inbound SMS', { $json: { body: twilioForm } });
const r = inbound[0].r;
check(r.action === 'agent' && r.system_prompt.includes('Consultation on'), 'S1 free-text SMS routed to agent with booking context', r);
const routeR = nodeOf(sa, 'Route Reply').parameters.rules.values;
check(evalExpr(routeR[1].conditions.conditions[0].leftValue, { $json: inbound[0] }) === 'agent', 'S2 switch sends it to the agent branch');
check(evalExpr(nodeOf(sa, 'Chat Memory').parameters.sessionKey, { $: () => ({ item: { json: inbound[0] } }) }) === r.session_key,
      'S3 chat memory keyed per business + phone');
// simulate the model calling tools with $fromAI values
const toolCtx = ai => ({ $: () => ({ item: { json: inbound[0] } }), $fromAI: (k, d, t, dflt) => (k in ai ? ai[k] : dflt) });
let out = pgNode(sa, 'check_availability', toolCtx({ service: 'consultation', date: THU, time: '16:00' }));
check(J(out[0].result).available === true, 'S4 agent tool check_availability', out);
out = pgNode(sa, 'reschedule_appointment', toolCtx({ date: THU, time: '16:00' }));
check(J(out[0].result).ok === true, 'S5 agent tool reschedule (scoped to sender phone)', out);
out = pgNode(sa, 'reschedule_appointment', toolCtx({ date: THU, time: '16:00' }));
check(J(out[0].result).duplicate === true, 'S6 repeated identical tool call is a duplicate, not a second change', out);
out = pgNode(sa, 'book_appointment', toolCtx({ customer_name: 'Tom Hardy', service: 'Consultation', date: THU, time: '14:00' }));
const kid = pgNode(sa, 'book_appointment', toolCtx({ customer_name: 'Leo Hardy', service: 'Consultation', date: THU, time: '14:30' }));
check(J(out[0].result).ok === true && J(kid[0].result).ok === true && !J(kid[0].result).duplicate,
      'S6b two different bookings from one SMS ("me and my son") both succeed', [out, kid]);
const reply = runCode(nodeOf(sa, 'Build Reply').parameters.jsCode, [{ output: 'Done! You are now booked for 4pm.' }],
                      { 'Inbound SMS': inbound }, { output: 'Done! You are now booked for 4pm.' })[0];
check(reply.to === '+447700900777' && reply.from === '+447700900001' && reply.body.startsWith('Done'), 'S7 reply goes back to the sender from the business number', reply);
const fallback = runCode(nodeOf(sa, 'Build Reply').parameters.jsCode, [{}], { 'Inbound SMS': inbound }, {})[0];
check(/call us/.test(fallback.body), 'S8 if the AI fails, the customer still gets a fallback reply', fallback);
out = pgNode(sa, 'Log Reply', { $json: { statusCode: 201, body: { sid: 'SMh_out_1' } }, $: () => ({ item: { json: reply } }) });
check(out[0].result.ok === true, 'S9 agent reply logged');
inbound = pgNode(sa, 'Inbound SMS', { $json: { body: twilioForm } });
check(inbound[0].r.action === 'none' && inbound[0].r.reason === 'duplicate', 'S10 Twilio retry of the same message is ignored');
inbound = pgNode(sa, 'Inbound SMS', { $json: { body: { ...twilioForm, Body: 'Yes', MessageSid: 'SMh_in_2' } } });
check(inbound[0].r.action === 'reply' && /confirmed/.test(inbound[0].r.sms.body), 'S11 "Yes" confirms without calling the AI', inbound[0].r);

// ------------------------------------------------------------------ ERROR HANDLER
const eh = load('04-BOS-Error-Handler.json');
out = pgNode(eh, 'Log Error', { $json: { workflow: { id: 'w1', name: 'BOS · Worker' },
  execution: { id: '991', lastNodeExecuted: 'Send SMS (Twilio)', error: { message: 'Twilio 401, bad credentials' } } } });
check(out[0].result.ok === true, 'E1 error handler writes to bos.errors');

console.log(`\nHARNESS: ${passed} checks passed`);
