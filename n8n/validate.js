// Static validation of generated n8n workflow JSON. Usage: node validate.js [dir=.]
const fs = require('fs'), path = require('path');
const dir = process.argv[2] || '.';
const SUPPORTED = {
  'n8n-nodes-base.webhook':[1,1.1,2,2.1,2.2], 'n8n-nodes-base.code':[1,2], 'n8n-nodes-base.postgres':[2,2.1,2.2,2.3,2.4,2.5,2.6,2.7],
  'n8n-nodes-base.postgresTool':[2,2.1,2.2,2.3,2.4,2.5,2.6,2.7], 'n8n-nodes-base.respondToWebhook':[1,1.1,1.2,1.3,1.4,1.5],
  'n8n-nodes-base.scheduleTrigger':[1,1.1,1.2,1.3,1.4], 'n8n-nodes-base.switch':[3,3.1,3.2,3.3,3.4],
  'n8n-nodes-base.httpRequest':[3,4,4.1,4.2,4.3,4.4,4.5], 'n8n-nodes-base.errorTrigger':[1],
  '@n8n/n8n-nodes-langchain.agent':[2,2.1,2.2,3,3.1], '@n8n/n8n-nodes-langchain.lmChatOpenAi':[1,1.1,1.2,1.3],
  '@n8n/n8n-nodes-langchain.memoryPostgresChat':[1,1.1,1.2,1.3,1.4] };
let problems = 0; const bad = m => { problems++; console.log('  PROBLEM', m); };
function walk(v, f, p='') { if (typeof v === 'string') f(v, p); else if (v && typeof v === 'object') for (const k in v) walk(v[k], f, p+'.'+k); }
const SECRET = /(sk-[A-Za-z0-9]{20,}|re_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{30,}|AC[a-f0-9]{32}|Bearer\s+[A-Za-z0-9._-]{20,})/;
for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort()) {
  const wf = JSON.parse(fs.readFileSync(path.join(dir, f))); console.log(f, '-', wf.nodes.length, 'nodes');
  const names = new Set(), ids = new Set();
  for (const n of wf.nodes) {
    if (names.has(n.name)) bad('dup name '+n.name); names.add(n.name);
    if (ids.has(n.id)) bad('dup id '+n.id); ids.add(n.id);
    if (!(SUPPORTED[n.type]||[]).includes(n.typeVersion)) bad(`unsupported ${n.type}@${n.typeVersion}`);
    if (n.parameters.jsCode) { try { new Function('$input','$','$json', n.parameters.jsCode); } catch (e) { bad(`${n.name} JS: ${e.message}`); } }
    walk(n.parameters, (s, p) => {
      if (SECRET.test(s)) bad(`${n.name}${p} looks like a hard-coded secret`);
      if (!s.startsWith('=')) return;
      for (const m of s.matchAll(/\{\{([\s\S]*?)\}\}(?!\})/g)) {
        try { new Function('$json','$','$fromAI','$input', 'return (' + m[1] + ');'); }
        catch (e) { bad(`${n.name}${p} expr: ${e.message} :: ${m[1].slice(0,80)}`); }
      }
    });
    walk(n.parameters, s => { for (const m of s.matchAll(/\$\('([^']+)'\)/g)) if (!wf.nodes.some(x => x.name === m[1])) bad(`${n.name} refs missing node ${m[1]}`); });
  }
  const targets = new Set();
  for (const [src, outs] of Object.entries(wf.connections)) {
    if (!names.has(src)) bad('conn from missing '+src);
    for (const [typ, arr] of Object.entries(outs)) for (const list of arr) for (const c of list) {
      if (!names.has(c.node)) bad('conn to missing '+c.node); targets.add(c.node);
    }
  }
  for (const n of wf.nodes) if (!/Trigger|webhook|Webhook/.test(n.type) && !targets.has(n.name) && !wf.connections[n.name]) bad('orphan '+n.name);
  // every Postgres query parameter placeholder must be fed by the Query Parameters expression
  for (const n of wf.nodes.filter(n => n.type.endsWith('.postgres'))) {
    const q = n.parameters.query || ''; const max = Math.max(0, ...[...q.matchAll(/\$(\d+)/g)].map(m => +m[1]));
    if (max && !(n.parameters.options || {}).queryReplacement) bad(`${n.name} uses $${max} but has no Query Parameters`);
  }
}
console.log(problems ? `FAILED: ${problems} problem(s)` : 'STATIC VALIDATION: PASS');
process.exit(problems ? 1 : 0);
