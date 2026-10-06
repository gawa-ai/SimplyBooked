"""Shared helpers for the ACQ (client-acquisition) n8n workflow generator.
Same conventions as the Booking OS generator: typeVersions pinned to n8n 2.x, Postgres node 2.5 with array
Query Parameters (arrays -> one $n per element, objects JSON-stringified), credentials by NAME only (no secrets)."""
import json, uuid, pathlib

OUT = pathlib.Path(__file__).parent / "acq"
NS = uuid.UUID("5b0c9e0e-3a64-4f0b-8c2e-7a1d9d3f6b21")

def nid(wf, name):
    return str(uuid.uuid5(NS, f"{wf}:{name}"))

CRED = {
    "postgres": {"postgres": {"id": "REPLACE_postgres", "name": "BOS Postgres"}},
    "openai":   {"openAiApi": {"id": "REPLACE_openai", "name": "BOS OpenAI"}},
    "resend":   {"httpHeaderAuth": {"id": "REPLACE_acq_resend", "name": "ACQ Resend"}},
    "inbound":  {"httpHeaderAuth": {"id": "REPLACE_acq_inbound", "name": "ACQ Inbound Webhook Secret"}},
    "gcal":     {"googleCalendarOAuth2Api": {"id": "REPLACE_gcal", "name": "BOS Google Calendar"}},
}

def node(wf, name, typ, ver, pos, params, creds=None, **extra):
    n = {"parameters": params, "id": nid(wf, name), "name": name, "type": typ, "typeVersion": ver, "position": pos}
    if creds: n["credentials"] = creds
    n.update(extra)
    return n

def pg(wf, name, pos, query, replacement=None, **extra):
    opts = {"queryBatching": "independently"}
    if replacement: opts["queryReplacement"] = replacement
    return node(wf, name, "n8n-nodes-base.postgres", 2.5, pos,
                {"operation": "executeQuery", "query": query, "options": opts}, CRED["postgres"], **extra)

def code(wf, name, pos, js, each=True):
    p = {"jsCode": js}
    if each: p["mode"] = "runOnceForEachItem"
    return node(wf, name, "n8n-nodes-base.code", 2, pos, p)

def schedule(wf, name, pos, minutes):
    return node(wf, name, "n8n-nodes-base.scheduleTrigger", 1.2, pos,
                {"rule": {"interval": [{"field": "minutes", "minutesInterval": minutes}]}})

def switch(wf, name, pos, pairs):
    return node(wf, name, "n8n-nodes-base.switch", 3.2, pos, {"rules": {"values": [
        {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
                        "conditions": [{"id": str(uuid.uuid5(NS, wf + key + left + right)), "leftValue": left, "rightValue": right,
                                        "operator": {"type": "string", "operation": "equals"}}], "combinator": "and"},
         "renameOutput": True, "outputKey": key} for key, left, right in pairs]}, "options": {}})

def http(wf, name, pos, params, creds=None, **extra):
    base = {"options": {"response": {"response": {"fullResponse": True, "neverError": True}}}}
    for k, v in params.items():
        if k == "options": base["options"].update(v)
        else: base[k] = v
    return node(wf, name, "n8n-nodes-base.httpRequest", 4.2, pos, base, creds, onError="continueRegularOutput", **extra)

def conn(*edges):
    c = {}
    for e in edges:
        src, dst = e[0], e[1]; idx = e[2] if len(e) > 2 else 0; typ = e[3] if len(e) > 3 else "main"
        outs = c.setdefault(src, {}).setdefault(typ, [])
        while len(outs) <= idx: outs.append([])
        outs[idx].append({"node": dst, "type": typ, "index": 0})
    return c

def workflow(name, nodes, connections):
    return {"name": name, "nodes": nodes, "connections": connections, "active": False,
            "settings": {"executionOrder": "v1", "saveDataErrorExecution": "all", "saveDataSuccessExecution": "all", "saveManualExecutions": True},
            "pinData": {}, "meta": {"templateCredsSetupCompleted": False}, "tags": []}

def emit(files):
    OUT.mkdir(exist_ok=True)
    for fname, wf in files.items():
        (OUT / fname).write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")
        print(f"{fname}: {len(wf['nodes'])} nodes")
