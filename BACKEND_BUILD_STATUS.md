# BACKEND_BUILD_STATUS — SimplyBooked (Booking OS + ACQ)

Last updated: 2026-10-06. Labels: **VERIFIED** = a test or check ran and passed (result quoted). **SUPPORTED** = matches official docs / source, not executed against the live service. **HYPOTHESIS** = expected, not checked.

## 1. What is built

Two modules share one Supabase Postgres project:

| Module | Schema | What it does |
|---|---|---|
| Booking OS | `bos` | AI receptionist booking engine (VAPI voice, website, SMS agent): availability, no double booking, reminders, follow-ups, review requests, Google Calendar sync. Unchanged from the original project. |
| Client acquisition (ACQ) | `acq` | Find businesses → qualify (score 0–100, reasons, pain points) → CRM pipeline → AI drafts → **human approval** → send (email; SMS off by default) → track delivery/opens/clicks/replies → classify replies (suggestions need approval) → personalised demo page → book a sales call (Google Calendar) → follow-ups → Won → client + onboarding checklist + AI-receptionist config → provision a `bos` business (test mode). Dashboard metrics. |

Design rules (enforced in the database, not in n8n or the browser):
- Nothing reaches a sendable status without approval (`outreach_requires_approval`, `outreach_approver_recorded`, and `outreach_auto_approval_followups_only`: auto-approval exists only for follow-ups, only when the org opts in, and only after a person approved the first message).
- Multi-tenant: every row carries `org_id`; composite FKs keep children in their parent's org; RLS on every table; `org_id` is immutable.
- Pipeline state machine (guard trigger) with an append-only event log; append-only `activity_logs`.
- Suppression list (unsubscribe, bounce, complaint, erasure, manual) checked at import, drafting, claim and send time; erasure keeps only hashed identifiers.
- Send caps: send window, daily per-channel limit, per-domain limit, min gap, campaign daily limit, reputation guard (auto-pause on bounces/complaints).
- Every cold email carries the postal address, a one-click unsubscribe link and `List-Unsubscribe` headers; sending is blocked until the sender identity and tracking URL are set.
- AI output is validated by the database (no links, no placeholders, length limits); lead/web data is passed to the model only as delimited untrusted data.

## 2. Tables (`acq`, 21) and views (7)

`organizations, profiles, system_settings, lead_sources, lead_search_runs, leads, lead_qualification, pipeline_events, outreach_campaigns, outreach_messages, replies, demos, meetings, followups, clients, onboarding_tasks, suppressions, activity_logs, rate_limits, webhook_events, digests`
Views (security_invoker): `v_leads, v_pipeline, v_outreach, v_replies, v_meetings, v_followups, v_clients`.
`bos` (15 tables) is unchanged: see `README.md`.

## 3. Functions / endpoints

**User RPCs** (granted to `authenticated`; each re-checks org + role inside):
`import_leads, move_lead, mark_do_not_contact, erase_lead (admin), reinstate_lead (owner), requalify_lead, queue_search_run, edit_draft, approve_message, approve_messages, reject_message, redraft_lead, update_setting (admin; sender/tracking/SMS = owner), set_outreach_enabled (owner), edit_reply_response, approve_reply_response, reject_reply_response, mark_reply_handled, match_reply_manually, create_demo, revoke_demo, send_demo, schedule_meeting, cancel_meeting, set_meeting_outcome, cancel_lead_followups, skip_followup, set_followup_due, convert_lead_to_client, update_client_config, set_client_status, provision_bos_business, dashboard_metrics, performance_breakdown, add_member (admin)`.

**Service-only functions** (n8n / edge functions; not executable by `anon` or `authenticated`):
claim/complete queues for search runs, qualification, drafting, outbound, reply classification, meeting calendar, follow-ups, digests; `ingest_reply`, `record_delivery_event`, `unsubscribe_by_token`, `demo_view`, `demo_click`, `meeting_slots`, `book_meeting`, `hit_rate_limit`, `maintenance`, `create_organization`.
VERIFIED (local): 0 functions in `acq`/`bos` executable by `anon`.

**Edge functions** (`supabase/functions/`):

| Function | Auth | Purpose |
|---|---|---|
| `acq-api` | user JWT, validated in code (`auth.getUser`) + origin allow-list + per-user rate limit | The only door the dashboard uses for privileged actions; calls the user RPCs **with the caller's JWT** (never the server key). 34 allow-listed actions. |
| `acq-track` | public | Unsubscribe link in every email: GET shows a confirm page (never mutates, safe for mail scanners), POST unsubscribes (RFC 8058 one-click). Token only, identical responses, per-IP rate limit. Opens/clicks/bounces come from the Resend webhook. |
| `acq-demo` | public | Demo page data (64-hex token), CTA click tracking, slot list and booking (rate-limited per IP and per token). |
| `resend-webhook` | Svix signature (`RESEND_WEBHOOK_SECRET`) | Delivery events → `record_delivery_event`; replay window + de-dupe. |
| `_shared/keys.ts` | — | Reads the new `sb_publishable`/`sb_secret` keys (`SUPABASE_PUBLISHABLE_KEYS` / `SUPABASE_SECRET_KEYS`), falls back to legacy `anon`/`service_role` (Supabase retires those at the end of 2026). |

## 4. n8n workflows (generated — never hand-edit the JSON)

Booking OS (`n8n/01-04`, from `build_workflows.py`): Gateway, Worker, SMS Agent, Error Handler.
ACQ (`n8n/acq/10-19`, from `acq_build.py` + `acq_phase2..5.py`):

| # | Workflow | Trigger | Credentials |
|---|---|---|---|
| 10 | Lead Finder (OpenStreetMap / Overpass) | every 5 min | BOS Postgres |
| 11 | Lead Qualification (AI score, reasons, pain points) | every 2 min | BOS Postgres, BOS OpenAI |
| 12 | Draft Generator (drafts only) | every 5 min | BOS Postgres, BOS OpenAI |
| 13 | Outbound Sender (approved only) | every 1 min | BOS Postgres, ACQ Resend, BOS Twilio |
| 14 | Reply Intake (`POST /webhook/acq/reply-intake`) | webhook | BOS Postgres, ACQ Inbound Webhook Secret |
| 15 | Reply Classifier (labels + suggested answer, never sends) | every 2 min | BOS Postgres, BOS OpenAI |
| 16 | Meeting Calendar Sync (create/update/delete, Meet link) | every 1 min | BOS Postgres, BOS Google Calendar |
| 17 | Follow-up Drafter (drafts only; DB decides approval) | every 10 min | BOS Postgres, BOS OpenAI |
| 18 | Daily Digest (internal email, counts only) | every 30 min | BOS Postgres, ACQ Resend |
| 19 | Maintenance (expire demos, trim counters) | daily 03:17 | BOS Postgres |

## 5. Environment variables / credentials (names only — values never go in code, JSON or chat)

Supabase Edge Function secrets (Dashboard → Edge Functions → Secrets):
- `ACQ_ALLOWED_ORIGINS` — comma list of dashboard origins allowed to call `acq-api` (e.g. `https://app.example.com`).
- `ACQ_DEMO_ORIGINS` — comma list of origins hosting the demo page.
- `RESEND_WEBHOOK_SECRET` — the `whsec_…` signing secret from the Resend webhook.
- Injected automatically: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS` (legacy `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`).

n8n credentials (exact names): `BOS Postgres`, `BOS OpenAI`, `BOS Twilio`, `BOS Google Calendar`, `ACQ Resend` (Header Auth: `Authorization: Bearer re_…`), `ACQ Inbound Webhook Secret` (Header Auth), plus the original `BOS Vapi Secret`, `BOS API Secret`, `BOS Twilio Webhook Auth`.

## 6. Production (Supabase project `jdqidbgjlttojhseyugr`, eu-west-1, Postgres 17)

| Step | Status |
|---|---|
| `db/001_booking_os_schema.sql` | Applied 2026-10-06. **VERIFIED**: function / column / constraint / index fingerprints identical to the locally tested schema; RLS on all 15 tables. |
| `db/002_seed_demo.sql` | Applied (BrightSmile Dental + Luxe Hair demo, `test_mode = true`, fictional numbers). |
| `db/020_acq_schema.sql` | Applied 2026-10-06. |
| `db/021`–`024` | **Pending.** Contain `delete from` inside functions (lead erasure, rate-limit and housekeeping cleanup), which this session's database tool cannot run without an approval prompt. Run them in the SQL Editor (section 7, step 1). |
| Edge functions | Not deployed yet (deploy after 021–024; section 7). |
| n8n workflows | Not imported (no n8n access from here). |

## 7. Remaining manual setup (in order)

1. **Supabase SQL Editor** → run, one at a time and in order: `db/021_acq_leads_crm.sql`, `db/022_acq_outreach.sql`, `db/023_acq_replies_demos_meetings.sql`, `db/024_acq_followups_onboarding_metrics.sql`. Each is safe to re-run.
2. **Settings → API → Exposed schemas**: add `acq` (keep `bos` **unexposed**).
3. Create your login (Authentication → Users), then in the SQL Editor: `select acq.create_organization('SimplyBooked', 'simplybooked', 'you@yourdomain.com');`
4. Settings via the dashboard / `acq-api` `update_setting` (owner): `sender` (from_name, from_email on a verified Resend domain, reply_to_email, **postal_address**), `tracking_base_url` = `https://jdqidbgjlttojhseyugr.supabase.co/functions/v1/acq-track`, `demo_base_url` (your demo page, https), `notify_email`, `meeting` (hours, calendar_id), `send_window`. Keep `outreach_enabled = false` until the live test passes.
5. Edge function secrets (section 5), then deploy: `supabase functions deploy acq-api acq-track acq-demo resend-webhook --no-verify-jwt` (all four authenticate in code).
6. Resend: verify the sending domain (SPF/DKIM/DMARC); webhook → `https://jdqidbgjlttojhseyugr.supabase.co/functions/v1/resend-webhook` (copy its signing secret into `RESEND_WEBHOOK_SECRET`); route inbound replies to n8n `/webhook/acq/reply-intake` with the shared-secret header.
7. n8n: create the credentials in section 5, import `n8n/acq/10-19` (and `n8n/01-04` for Booking OS), set each one's Error workflow, activate.
8. Lead sources: OpenStreetMap/Overpass works without a key. Google Places is a placeholder provider; check the Google Maps Platform terms (storage/caching limits) before wiring it.

## 8. Testing checklist

Local (throwaway Postgres 16 databases; never production) — run `./run_acq_all.sh`:
- [x] bos SQL suite: 59 checks — **VERIFIED**
- [x] bos n8n contract harness: 30 checks — **VERIFIED**
- [x] acq SQL suites, phase by phase, every migration applied twice: phases 1–5 pass — **VERIFIED**
- [x] acq SQL suites on the final schema (all migrations first): 67 + 110 + 105 + 89 + 109 = 480 checks — **VERIFIED**
- [x] n8n static validation, 14 workflows (versions, expressions, references, no hard-coded secrets) — **VERIFIED**
- [x] acq n8n contract harness (real Code-node JS + real Query Parameters vs DB): 82 checks — **VERIFIED**
- [x] Edge functions: strict TypeScript check + 44 unit tests — **VERIFIED**

Live acceptance (do in this order, `outreach_enabled = false` until step 4):
1. Import 3 leads (CSV) → they get qualified (scores, reasons) → appear in the pipeline.
2. Draft generated → shows as **pending approval**; nothing in Resend.
3. Approve one draft to your own address with `outreach_enabled` still false → nothing is sent (blocked).
4. Enable outreach → the approved email arrives with the footer, postal address and a working unsubscribe link; Resend webhook marks it delivered/opened.
5. Reply to it → reply appears, classified, suggested response pending approval.
6. Send the demo → open the demo link → book a slot → meeting + Google Calendar event with Meet link.
7. Unsubscribe link → lead suppressed, pending follow-ups cancelled.
8. Mark Won → client + onboarding checklist → fill config → go-live review → `provision_bos_business` → new `bos` business in test mode.
9. `select * from acq.activity_logs order by id desc limit 50;` and Supabase advisors show no errors.

## 9. Not verified / known risks

- Live Resend, OpenAI, Overpass, Google Calendar, Twilio, VAPI and n8n import: **not tested** (no access from here) — the contract harness proves the data contracts, not the providers.
- Edge functions have not run on the Supabase Deno runtime yet (unit-tested under Node with the same handler code) — **SUPPORTED**.
- Production is Postgres 17; local tests ran on Postgres 16. The applied `bos` schema fingerprints match exactly — **VERIFIED** for 001; ACQ to be fingerprinted after 021–024.
- Reply matching by email `Message-ID` is best effort (some clients drop `In-Reply-To`); unmatched replies land in a triage list.
- Homepage fetching for qualification has a residual DNS-rebinding SSRF risk (hostname checks only); keep n8n egress restricted.

## 2026-10-06 — Client portal (Front desk)
- VERIFIED: migration 025_acq_client_portal applied to prod (acq_025_client_portal); 40 new checks pass locally (db/tests/p6.sql) on top of the 480 existing ones; anon has no execute on any acq function; client_users has RLS.
- Found and fixed during testing: a NULL comparison in the access check would have let a signed-in client user through. Covered by test 605.
- NOT TESTED LIVE: portal RPCs against real bookings (prod has no bos data yet).
