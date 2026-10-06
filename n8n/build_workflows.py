#!/usr/bin/env python3
"""Generates the Booking OS n8n workflows (importable JSON).

Node typeVersions were checked against the n8n source (master, v2.41.0):
  webhook 2, code 2, postgres/postgresTool 2.5, respondToWebhook 1.1, scheduleTrigger 1.2,
  switch 3.2, httpRequest 4.2, errorTrigger 1, agent 2.2, lmChatOpenAi 1.2, memoryPostgresChat 1.3
Postgres >= 2.5 is required: it evaluates a Query Parameters expression that returns an array
item-by-item (objects are JSON-stringified), so text containing commas is never split.
"""
import json, uuid, pathlib

OUT = pathlib.Path(__file__).parent
NS = uuid.UUID("7d2f4a1e-0b6c-4c3e-9a51-3f0c1b2d4e5f")

def nid(wf, name):
    return str(uuid.uuid5(NS, f"{wf}:{name}"))

CRED = {
    "postgres":   {"postgres": {"id": "REPLACE_postgres", "name": "BOS Postgres"}},
    "vapi":       {"httpHeaderAuth": {"id": "REPLACE_vapi_secret", "name": "BOS Vapi Secret"}},
    "api":        {"httpHeaderAuth": {"id": "REPLACE_api_secret", "name": "BOS API Secret"}},
    "twilio_in":  {"httpBasicAuth": {"id": "REPLACE_twilio_basic", "name": "BOS Twilio Webhook Auth"}},
    "twilio":     {"twilioApi": {"id": "REPLACE_twilio", "name": "BOS Twilio"}},
    "gcal":       {"googleCalendarOAuth2Api": {"id": "REPLACE_gcal", "name": "BOS Google Calendar"}},
    "openai":     {"openAiApi": {"id": "REPLACE_openai", "name": "BOS OpenAI"}},
}

def node(wf, name, typ, ver, pos, params, creds=None, **extra):
    n = {"parameters": params, "id": nid(wf, name), "name": name, "type": typ,
         "typeVersion": ver, "position": pos}
    if creds:
        n["credentials"] = creds
    n.update(extra)
    return n

def pg_query(wf, name, pos, query, replacement=None, tool_desc=None, **extra):
    params = {"operation": "executeQuery", "query": query, "options": {}}
    if replacement:
        params["options"]["queryReplacement"] = replacement
    typ = "n8n-nodes-base.postgres"
    if tool_desc:
        typ = "n8n-nodes-base.postgresTool"
        params = {"descriptionType": "manual", "toolDescription": tool_desc, **params}
    else:
        params["options"]["queryBatching"] = "independently"
    return node(wf, name, typ, 2.5, pos, params, CRED["postgres"], **extra)

def webhook(wf, name, pos, path, auth, cred):
    return node(wf, name, "n8n-nodes-base.webhook", 2, pos,
                {"httpMethod": "POST", "path": path, "authentication": auth,
                 "responseMode": "responseNode", "options": {}},
                cred, webhookId=nid(wf, name + ":hook"))

def switch_rules(pairs):
    return {"rules": {"values": [
        {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
                        "conditions": [{"id": str(uuid.uuid5(NS, left + right)), "leftValue": left, "rightValue": right,
                                        "operator": {"type": "string", "operation": "equals"}}],
                        "combinator": "and"},
         "renameOutput": True, "outputKey": key}
        for key, left, right in pairs]}, "options": {}}

def twilio_send(wf, name, pos, src):
    return node(wf, name, "n8n-nodes-base.httpRequest", 4.2, pos, {
        "method": "POST",
        "url": f"=https://api.twilio.com/2010-04-01/Accounts/{{{{ {src}.account_sid }}}}/Messages.json",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "twilioApi",
        "sendBody": True,
        "contentType": "form-urlencoded",
        "bodyParameters": {"parameters": [
            {"name": "To", "value": f"={{{{ {src}.to }}}}"},
            {"name": "From", "value": f"={{{{ {src}.from }}}}"},
            {"name": "Body", "value": f"={{{{ {src}.body }}}}"}]},
        "options": {"response": {"response": {"fullResponse": True, "neverError": True}}, "timeout": 20000},
    }, CRED["twilio"], onError="continueRegularOutput", retryOnFail=False)

def conn(*edges):
    """edges: (from, to) or (from, to, output_index) or (from, to, idx, type)"""
    c = {}
    for e in edges:
        src, dst = e[0], e[1]
        idx = e[2] if len(e) > 2 else 0
        typ = e[3] if len(e) > 3 else "main"
        outs = c.setdefault(src, {}).setdefault(typ, [])
        while len(outs) <= idx:
            outs.append([])
        outs[idx].append({"node": dst, "type": typ, "index": 0})
    return c

def workflow(name, nodes, connections):
    return {"name": name, "nodes": nodes, "connections": connections, "active": False,
            "settings": {"executionOrder": "v1", "saveDataErrorExecution": "all",
                         "saveDataSuccessExecution": "all", "saveManualExecutions": True},
            "pinData": {}, "meta": {"templateCredsSetupCompleted": False}, "tags": []}

# ---------------------------------------------------------------------------------------------
# 1. GATEWAY — Vapi (phone + website voice button) and the website / dashboard API
# ---------------------------------------------------------------------------------------------
NORMALIZE_JS = r"""// Turns a Vapi server message or an API request into one item per tool call.
// Identity (business, caller phone) comes from Vapi/call data, never from what the AI says.
const out = [];
for (const item of $input.all()) {
  const req = item.json || {};
  const body = req.body || {};
  const q = req.query || {};
  const msg = body.message;

  if (msg && typeof msg === 'object') {
    const call = msg.call || {};
    const isPhone = String(call.type || '').toLowerCase().includes('phone');
    const base = {
      channel: 'vapi',
      business: String(q.business || msg.assistant?.metadata?.business || ''),
      source: isPhone ? 'voice' : 'web_voice',
      ctx: {
        assistant_id: String(call.assistantId || msg.assistant?.id || ''),
        caller_phone: isPhone ? String(call.customer?.number || msg.customer?.number || '') : '',
        call_id: String(call.id || ''),
      },
      idem: '',
      tool_call_id: '',
    };

    if (msg.type === 'tool-calls') {
      const calls = (Array.isArray(msg.toolCallList) && msg.toolCallList.length)
        ? msg.toolCallList
        : (msg.toolWithToolCallList || []).map(t => t.toolCall).filter(Boolean);
      for (const tc of calls) {
        let args = tc.function?.arguments ?? tc.arguments ?? tc.parameters ?? {};
        if (typeof args === 'string') { try { args = JSON.parse(args || '{}'); } catch (e) { args = {}; } }
        out.push({ json: { ...base, kind: 'tool', tool: String(tc.function?.name || tc.name || ''),
                           args, idem: String(tc.id || ''), tool_call_id: String(tc.id || '') } });
      }
      if (!calls.length) out.push({ json: { ...base, kind: 'event', tool: 'noop', args: {} } });
    } else if (msg.type === 'end-of-call-report') {
      const art = msg.artifact || {};
      out.push({ json: { ...base, source: 'vapi_event', kind: 'event', tool: 'record_call', args: {
        call_id: String(call.id || ''),
        call_type: String(call.type || ''),
        customer_phone: String(call.customer?.number || msg.customer?.number || ''),
        started_at: String(msg.startedAt || call.startedAt || ''),
        ended_at: String(msg.endedAt || call.endedAt || ''),
        ended_reason: String(msg.endedReason || call.endedReason || ''),
        summary: String(msg.analysis?.summary || msg.summary || ''),
        transcript: String(art.transcript || msg.transcript || ''),
        recording_url: String(art.recordingUrl || art.recording?.mono?.combinedUrl || msg.recordingUrl || ''),
        cost: msg.cost ?? call.cost ?? '',
      } } });
    } else {
      out.push({ json: { ...base, kind: 'event', tool: 'noop', args: {} } });
    }
  } else {
    // Website form / dashboard / server-to-server. Keep the API secret server-side only.
    const source = ['website', 'dashboard', 'api'].includes(body.source) ? body.source : 'api';
    let args = body.args ?? body.payload ?? {};
    if (typeof args === 'string') { try { args = JSON.parse(args || '{}'); } catch (e) { args = {}; } }
    out.push({ json: {
      channel: 'api', kind: 'tool', source,
      business: String(body.business || q.business || ''),
      tool: String(body.tool || body.action || ''),
      args,
      idem: String(body.idempotency_key || ''),
      tool_call_id: '',
      ctx: { trusted: source === 'dashboard', caller_phone: '' },
    } });
  }
}
return out;
"""

RESPONSE_JS = r"""// Vapi expects { results: [{ toolCallId, result }] }. Everything else gets the tool result.
const rows = $input.all().map(i => i.json);
const reqs = $('Normalize Request').all().map(i => i.json);
const unavailable = {
  ok: false, error: 'system_unavailable',
  message: 'The booking system is not responding right now. Apologise, take the caller\'s name and number, and say the team will call back.',
};

if ((reqs[0] || {}).channel === 'vapi') {
  const results = [];
  rows.forEach((r, i) => {
    const id = r.tool_call_id || reqs[i]?.tool_call_id;
    if (!id) return;
    results.push({ toolCallId: id, result: JSON.stringify(r.result || unavailable) });
  });
  return [{ json: { response: results.length ? { results } : { ok: true } } }];
}
const r = rows[0] || {};
return [{ json: { response: r.result || { ...unavailable, detail: r.error?.message || r.error || null } } }];
"""

GW = "gateway"
gateway = workflow("BOS · Gateway (Voice + Website + API)", [
    webhook(GW, "Vapi Webhook", [0, 0], "bos/vapi", "headerAuth", CRED["vapi"]),
    webhook(GW, "API Webhook", [0, 220], "bos/api", "headerAuth", CRED["api"]),
    node(GW, "Normalize Request", "n8n-nodes-base.code", 2, [260, 110], {"jsCode": NORMALIZE_JS}),
    pg_query(GW, "Run Tool", [500, 110],
             "select $1::text as tool_call_id, $2::text as kind,\n"
             "       bos.dispatch(nullif($3, ''), $4, $5::jsonb, nullif($6, ''), $7, $8::jsonb) as result;",
             "={{ [ $json.tool_call_id ?? '', $json.kind ?? '', $json.business ?? '', $json.tool ?? '', "
             "$json.args ?? {}, $json.idem ?? '', $json.source ?? 'api', $json.ctx ?? {} ] }}",
             onError="continueRegularOutput", alwaysOutputData=True),
    node(GW, "Build Response", "n8n-nodes-base.code", 2, [740, 110], {"jsCode": RESPONSE_JS}),
    node(GW, "Respond", "n8n-nodes-base.respondToWebhook", 1.1, [980, 110],
         {"respondWith": "json", "responseBody": "={{ JSON.stringify($json.response) }}", "options": {}}),
], conn(("Vapi Webhook", "Normalize Request"), ("API Webhook", "Normalize Request"),
        ("Normalize Request", "Run Tool"), ("Run Tool", "Build Response"), ("Build Response", "Respond")))

# ---------------------------------------------------------------------------------------------
# 2. WORKER — sends confirmations, reminders, follow-ups, reviews; syncs Google Calendar
# ---------------------------------------------------------------------------------------------
WK = "worker"
COMPLETE_ARGS = ("={{ [ $('Claim Jobs').item.json.job.job_id, $json.statusCode ?? 0, "
                 "($json.body && typeof $json.body === 'object') ? $json.body : { raw: String($json.body ?? '') }, "
                 "$json.error ? JSON.stringify($json.error).slice(0, 400) : '' ] }}")
worker = workflow("BOS · Worker (SMS + Calendar)", [
    node(WK, "Every Minute", "n8n-nodes-base.scheduleTrigger", 1.2, [0, 100],
         {"rule": {"interval": [{"field": "minutes", "minutesInterval": 1}]}}),
    pg_query(WK, "Claim Jobs", [230, 100], "select job from bos.claim_jobs(25) as job;"),
    node(WK, "Route Job", "n8n-nodes-base.switch", 3.2, [460, 100],
         switch_rules([("sms", "={{ $json.job.kind }}", "sms"), ("calendar", "={{ $json.job.kind }}", "calendar")])),
    twilio_send(WK, "Send SMS (Twilio)", [720, 0], "$json.job"),
    node(WK, "Sync Google Calendar", "n8n-nodes-base.httpRequest", 4.2, [720, 220], {
        "method": "={{ $json.job.method }}",
        "url": "={{ $json.job.url }}",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "googleCalendarOAuth2Api",
        "sendBody": "={{ $json.job.method !== 'DELETE' }}",
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify($json.job.body) }}",
        "options": {"response": {"response": {"fullResponse": True, "neverError": True}}, "timeout": 20000},
    }, CRED["gcal"], onError="continueRegularOutput"),
    pg_query(WK, "Complete Job", [980, 100],
             "select bos.complete_job($1::bigint, $2::int, $3::jsonb, nullif($4, '')) as result;", COMPLETE_ARGS),
], conn(("Every Minute", "Claim Jobs"), ("Claim Jobs", "Route Job"),
        ("Route Job", "Send SMS (Twilio)", 0), ("Route Job", "Sync Google Calendar", 1),
        ("Send SMS (Twilio)", "Complete Job"), ("Sync Google Calendar", "Complete Job")))

# ---------------------------------------------------------------------------------------------
# 3. SMS AGENT — customer texts back; keywords handled in SQL, the rest by the AI agent
# ---------------------------------------------------------------------------------------------
SA = "sms"
R = "$('Inbound SMS').item.json.r"
BUILD_REPLY_JS = r"""const r = $('Inbound SMS').item.json.r;
const agentText = typeof $json.output === 'string' ? $json.output.trim() : '';
let body = agentText || r.sms?.body || r.fallback_reply;
if (body.length > 640) body = body.slice(0, 637) + '...';
return { json: { business_id: r.business_id, to: r.from, from: r.to, account_sid: r.account_sid, body } };
"""
TOOL_SQL = "select bos.dispatch($1, '{tool}', $2::jsonb, $3, 'sms', $4::jsonb)::text as result;"
def tool_args(tool, fields):
    obj = ", ".join(f"{k}: $fromAI('{k}', '{d}', 'string'{', ' + repr(dflt) if dflt is not None else ''})"
                    for k, d, dflt in fields)
    return (f"={{{{ [ {R}.business_id, {{ {obj} }}, {R}.idem_prefix + ':{tool}', "
            f"{{ caller_phone: {R}.from }} ] }}}}")

sms = workflow("BOS · SMS Agent (Twilio inbound)", [
    webhook(SA, "Twilio SMS Webhook", [0, 100], "bos/twilio-sms", "basicAuth", CRED["twilio_in"]),
    pg_query(SA, "Inbound SMS", [230, 100], "select bos.inbound_sms($1, $2, $3, $4, $5::jsonb) as r;",
             "={{ [ $json.body.To ?? '', $json.body.From ?? '', $json.body.Body ?? '', $json.body.MessageSid ?? '', $json.body ?? {} ] }}"),
    node(SA, "Ack Twilio", "n8n-nodes-base.respondToWebhook", 1.1, [460, 100], {
        "respondWith": "text",
        "responseBody": '<?xml version="1.0" encoding="UTF-8"?><Response></Response>',
        "options": {"responseHeaders": {"entries": [{"name": "Content-Type", "value": "text/xml"}]}}}),
    node(SA, "Route Reply", "n8n-nodes-base.switch", 3.2, [680, 100],
         switch_rules([("reply", "={{ $json.r.action }}", "reply"), ("agent", "={{ $json.r.action }}", "agent")])),
    node(SA, "SMS Agent", "@n8n/n8n-nodes-langchain.agent", 2.2, [920, 240], {
        "promptType": "define",
        "text": "={{ $json.r.message }}",
        "options": {"systemMessage": "={{ $json.r.system_prompt }}", "maxIterations": 6}},
        onError="continueRegularOutput"),
    node(SA, "OpenAI Model", "@n8n/n8n-nodes-langchain.lmChatOpenAi", 1.2, [760, 460], {
        "model": {"__rl": True, "mode": "list", "value": "gpt-5-mini", "cachedResultName": "gpt-5-mini"},
        "options": {}}, CRED["openai"]),
    node(SA, "Chat Memory", "@n8n/n8n-nodes-langchain.memoryPostgresChat", 1.3, [900, 460], {
        "sessionIdType": "customKey",
        "sessionKey": f"={{{{ {R}.session_key }}}}",
        "tableName": "bos_chat_histories",
        "contextWindowLength": 12}, CRED["postgres"]),
    pg_query(SA, "check_availability", [1040, 460], TOOL_SQL.format(tool="check_availability"),
             tool_args("check_availability", [
                 ("service", "Service name as listed under SERVICES", None),
                 ("date", "Date as YYYY-MM-DD in the business timezone", None),
                 ("time", "Preferred time as HH:MM (24h), or empty to list openings that day", "")]),
             tool_desc="Check open appointment times for a service on a date. Always use before offering or booking a time."),
    pg_query(SA, "book_appointment", [1180, 460], TOOL_SQL.format(tool="book"),
             tool_args("book", [
                 ("customer_name", "Customer full name", None),
                 ("service", "Service name as listed under SERVICES", None),
                 ("date", "Date as YYYY-MM-DD", None),
                 ("time", "Time as HH:MM (24h)", None),
                 ("notes", "Optional short note for the team, or empty", "")]),
             tool_desc="Book an appointment for this customer (their phone number is added automatically). Only after check_availability showed the time is free and the customer agreed."),
    pg_query(SA, "reschedule_appointment", [1320, 460], TOOL_SQL.format(tool="reschedule"),
             tool_args("reschedule", [
                 ("ref", "Booking reference if the customer has more than one booking, else empty", ""),
                 ("date", "New date as YYYY-MM-DD", None),
                 ("time", "New time as HH:MM (24h)", None)]),
             tool_desc="Move this customer's existing booking to a new date and time. Check availability first."),
    pg_query(SA, "cancel_appointment", [1460, 460], TOOL_SQL.format(tool="cancel"),
             tool_args("cancel", [
                 ("ref", "Booking reference if the customer has more than one booking, else empty", ""),
                 ("reason", "Short reason if given, else empty", "")]),
             tool_desc="Cancel this customer's booking. Only when the customer clearly asked to cancel."),
    node(SA, "Build Reply", "n8n-nodes-base.code", 2, [1180, 100],
         {"mode": "runOnceForEachItem", "jsCode": BUILD_REPLY_JS}),
    twilio_send(SA, "Send Reply SMS", [1420, 100], "$json"),
    pg_query(SA, "Log Reply", [1660, 100],
             "select bos.log_outbound($1::uuid, $2, $3, $4, $5, $6::int) as result;",
             "={{ [ $('Build Reply').item.json.business_id, $('Build Reply').item.json.to, $('Build Reply').item.json.from, "
             "$('Build Reply').item.json.body, $json.body?.sid ?? '', $json.statusCode ?? 0 ] }}"),
], conn(("Twilio SMS Webhook", "Inbound SMS"), ("Inbound SMS", "Ack Twilio"), ("Ack Twilio", "Route Reply"),
        ("Route Reply", "Build Reply", 0), ("Route Reply", "SMS Agent", 1),
        ("SMS Agent", "Build Reply"), ("Build Reply", "Send Reply SMS"), ("Send Reply SMS", "Log Reply"),
        ("OpenAI Model", "SMS Agent", 0, "ai_languageModel"),
        ("Chat Memory", "SMS Agent", 0, "ai_memory"),
        ("check_availability", "SMS Agent", 0, "ai_tool"),
        ("book_appointment", "SMS Agent", 0, "ai_tool"),
        ("reschedule_appointment", "SMS Agent", 0, "ai_tool"),
        ("cancel_appointment", "SMS Agent", 0, "ai_tool")))

# ---------------------------------------------------------------------------------------------
# 4. ERROR HANDLER — any failed execution lands in bos.errors
# ---------------------------------------------------------------------------------------------
EH = "errors"
errors = workflow("BOS · Error Handler", [
    node(EH, "On Workflow Error", "n8n-nodes-base.errorTrigger", 1, [0, 0], {}),
    pg_query(EH, "Log Error", [260, 0], "select bos.log_error($1, $2, $3, $4::jsonb) as result;",
             "={{ [ $json.workflow?.name ?? '', $json.execution?.lastNodeExecuted ?? '', "
             "$json.execution?.error?.message ?? 'unknown error', "
             "{ execution_id: $json.execution?.id ?? null, url: $json.execution?.url ?? null, workflow_id: $json.workflow?.id ?? null } ] }}"),
], conn(("On Workflow Error", "Log Error")))

FILES = {
    "01-BOS-Gateway.json": gateway,
    "02-BOS-Worker.json": worker,
    "03-BOS-SMS-Agent.json": sms,
    "04-BOS-Error-Handler.json": errors,
}
for fname, wf in FILES.items():
    (OUT / fname).write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")
    print(f"{fname}: {len(wf['nodes'])} nodes")
