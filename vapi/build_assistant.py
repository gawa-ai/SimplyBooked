#!/usr/bin/env python3
"""Builds the Vapi assistant JSON for one business.

Usage:  python3 build_assistant.py <business-slug> "<Business Name>" "<Receptionist>" <Timezone> <n8n-base-url> <vapi-credential-id>
Output: assistant-<slug>.json  -> paste into Vapi (Assistant > Advanced > JSON) or POST https://api.vapi.ai/assistant

Every tool calls the same n8n Gateway webhook; ?business=<slug> tells the database which business it is.
The caller's phone number is taken from Vapi call data by n8n, never from the model.
"""
import json, sys, pathlib

slug, name, agent, tz, base, cred = (sys.argv[1:7] + [None] * 6)[:6]
slug = slug or "brightsmile-demo"
name = name or "BrightSmile Dental"
agent = agent or "Sophie"
tz = tz or "Europe/London"
base = (base or "https://n8n.YOUR-VPS-DOMAIN.com").rstrip("/")
cred = cred or "REPLACE_WITH_VAPI_BEARER_CREDENTIAL_ID"

server = {"url": f"{base}/webhook/bos/vapi?business={slug}", "credentialId": cred, "timeoutSeconds": 20}

def tool(fn, desc, props, required=()):
    return {"type": "function", "async": False,
            "function": {"name": fn, "description": desc,
                         "parameters": {"type": "object", "properties": props, "required": list(required)}},
            "server": server}

S = lambda d: {"type": "string", "description": d}
DATE = S("Date as YYYY-MM-DD in the business's local time. Work it out from today's date.")
TIME = S("Time as HH:MM in 24-hour format, business local time.")

tools = [
    tool("get_business_info", "Get today's date, opening hours, services, prices, address and policies. Call at the start of every conversation.", {}),
    tool("check_availability", "Check open times for a service. Use before offering or booking any time.",
         {"service": S("Service name as returned by get_business_info"), "date": DATE,
          "time": S("Preferred time HH:MM (24h). Leave empty to list openings that day.")}, ["service", "date"]),
    tool("book_appointment", "Book an appointment after the caller agreed to a time that check_availability showed as free.",
         {"customer_name": S("Caller's full name"), "phone": S("Mobile number for the text confirmation. Leave empty on phone calls unless the caller wants a different number."),
          "service": S("Service name"), "date": DATE, "time": TIME, "notes": S("Optional short note for the team")},
         ["customer_name", "service", "date", "time"]),
    tool("find_appointment", "Look up the caller's upcoming bookings.",
         {"phone": S("Phone number on the booking (not needed on phone calls from the same number)"),
          "customer_name": S("First name on the booking, for verification"), "ref": S("Booking reference, if they have it")}),
    tool("reschedule_appointment", "Move an existing booking to a new date and time. Check availability first.",
         {"ref": S("Booking reference, if known"), "phone": S("Phone number on the booking, if not calling from it"),
          "customer_name": S("First name on the booking, for verification"), "date": DATE, "time": TIME}, ["date", "time"]),
    tool("cancel_appointment", "Cancel a booking after the caller clearly confirmed they want to cancel.",
         {"ref": S("Booking reference, if known"), "phone": S("Phone number on the booking, if not calling from it"),
          "customer_name": S("First name on the booking, for verification"), "reason": S("Reason, if given")}),
]

prompt = f"""You are {agent}, the friendly receptionist for {name}. You speak on the phone and through the website voice button.
Today is {{{{"now" | date: "%A %d %B %Y, %H:%M", "{tz}"}}}} ({tz}).

HOW YOU WORK
- At the start of every conversation call get_business_info, and use only that information for hours, services, prices and policies.
- Keep every reply to one or two short spoken sentences. Ask one question at a time.
- For any time the caller wants, call check_availability first. Offer at most three options.
- Before booking, repeat back: name, service, day, date and time, and get a clear yes. Then call book_appointment.
- Only say something is booked, moved or cancelled when the tool result has "ok": true. Read the date and time from the result, and spell the booking reference letter by letter.
- If a result has "ok": false, use its "message" to ask for what is missing or offer the alternatives it gives.
- On phone calls the caller's number is used automatically. On website calls, ask for a mobile number for the text confirmation.
- To change or cancel a booking, you may be asked to verify: ask for the first name on the booking or the reference from their text.
- Never give medical, legal or financial advice. For anything you cannot handle, offer to take a message and say the team will call back.
- If the system is unavailable, apologise, take their name and number, and say the team will call back."""

assistant = {
    "name": f"{name} - AI Receptionist",
    "firstMessage": f"Hi, thanks for calling {name}, this is {agent}. How can I help you today?",
    "model": {"provider": "openai", "model": "gpt-4.1", "temperature": 0.3,
              "messages": [{"role": "system", "content": prompt}], "tools": tools},
    "server": server,
    "serverMessages": ["end-of-call-report"],
    "endCallFunctionEnabled": True,
    "metadata": {"business": slug},
}
out = pathlib.Path(__file__).parent / f"assistant-{slug}.json"
out.write_text(json.dumps(assistant, indent=2, ensure_ascii=False) + "\n")
print(f"wrote {out.name}: {len(tools)} tools -> {server['url']}")
