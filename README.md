# Booking OS — AI Receptionist + Booking Automation (any business)

Custom Website + AI Receptionist (VAPI) + Booking System + Confirmations + Calendar Updates +
Reminders + Reschedule/Cancel + Follow-ups + Review Requests. One engine, maraming client (dental,
salon, clinic, spa, garage, etc.).

## Paano gumagana

```
 Website voice button ─┐                       ┌─► Postgres (Supabase)  ◄── the "brain"
 Phone call (VAPI) ────┼─► n8n GATEWAY ──────► │   bos.dispatch(): availability, anti-double-booking,
 Website form/dashboard┘   (6 nodes)           │   idempotency, verification, job scheduling
                                               │
 Customer texts back ────► n8n SMS AGENT ──────┤   keywords (C/YES/STOP) in SQL,
                           (AI Agent + tools)  │   free text → OpenAI agent using the same tools
                                               │
 Every minute ───────────► n8n WORKER ─────────┘   claims due jobs → Twilio SMS / Google Calendar
                           (6 nodes)               → confirmation, reminder, rescheduled, cancelled,
                                                     follow-up, review request, calendar create/update/delete
```

**Bakit mas malakas ito kaysa sa lumang 145-node workflow:**
- 28 nodes na lang (4 workflows). Nasa Postgres ang business logic, na tumatakbo sa iisang transaction kaya walang kalahating booking.
- **Imposible ang double booking.** Hinaharang ito ng database constraint (`bookings_no_overlap`), kahit sabay ang dalawang tawag.
- **Walang dobleng text o booking kapag nag-retry ang VAPI o Twilio** (idempotency + event de-dupe).
- **Hindi kayang galawin ng AI ang booking ng iba.** Ang numero ng caller o texter ay galing sa VAPI/Twilio, hindi sa AI. Ang website caller ay kailangang mag-verify gamit ang pangalan o reference.
- **Para sa pag-intindi ng tao ang AI.** Ang rules ay nasa database, kaya hindi puwedeng "mag-imbento" ng available slot.
- **Walang secret sa code.** Lahat ay nasa n8n credentials.

## Files

| File | Ano ito |
|---|---|
| `db/001_booking_os_schema.sql` | Buong database (schema `bos`). Puwedeng i-run nang paulit-ulit. |
| `db/002_seed_demo.sql` | Demo: BrightSmile Dental + Luxe Hair Studio |
| `db/010_add_business_TEMPLATE.sql` | Kopyahin at punan para sa bawat bagong client |
| `db/003_tests.sql`, `db/run_tests.sh` | 59 automated checks. **Sa throwaway DB lang, huwag sa production.** |
| `n8n/01..04-*.json` | Ang 4 na workflow na i-import sa VPS n8n |
| `n8n/build_workflows.py`, `n8n/harness.js` | Generator at contract test (30 checks) |
| `vapi/assistant-*.json`, `vapi/build_assistant.py` | VAPI assistant config per business |
| `web/voice-button-snippet.html` | "Talk to our AI Receptionist" button para sa website |

## Setup (sundin nang sunod-sunod)

### 1. Supabase (bagong project)
1. Gumawa ng project. Para sa UK clients, piliin ang region **London (eu-west-2)**.
2. Sa SQL Editor, i-run ang `db/001_booking_os_schema.sql`, tapos ang `db/002_seed_demo.sql` (demo).
3. Ilagay ang Twilio Account SID (hindi ito secret):
   `update bos.settings set value = 'ACxxxx' where key = 'twilio_account_sid';`

### 2. n8n sa VPS
- Kailangan ng **n8n 2.x** at HTTPS domain (hal. `https://n8n.yourdomain.com`).
- Env vars: `WEBHOOK_URL=https://n8n.yourdomain.com/` at `GENERIC_TIMEZONE=Europe/London`. I-backup ang `N8N_ENCRYPTION_KEY`.

### 3. Mga credential sa n8n (gamitin ang eksaktong pangalan)
| Pangalan | Type | Laman |
|---|---|---|
| BOS Postgres | Postgres | Supabase → Connect → **Session pooler**: host `aws-0-…pooler.supabase.com`, port 5432, db `postgres`, user `postgres.<project-ref>`, password, SSL: require |
| BOS Vapi Secret | Header Auth | Name `Authorization`, Value `Bearer <mahabang random secret A>` |
| BOS API Secret | Header Auth | Name `Authorization`, Value `Bearer <ibang random secret B>` |
| BOS Twilio Webhook Auth | Basic Auth | user + password (random) |
| BOS Twilio | Twilio API | Account SID + Auth Token |
| BOS Google Calendar | Google Calendar OAuth2 | i-sign in ang Google account na may access sa calendars |
| BOS OpenAI | OpenAI | API key |

### 4. I-import ang workflows
1. I-import ang `04-BOS-Error-Handler.json`, tapos ang `01`, `02`, `03`. Piliin ang credential sa bawat node na may babala.
2. Sa 01, 02 at 03: **Settings → Error workflow → "BOS · Error Handler"**.
3. I-publish/activate ang lahat ng apat.

### 5. Twilio (SMS)
- Phone number → Messaging → "A message comes in" → **Webhook, POST**:
  `https://<user>:<password>@n8n.yourdomain.com/webhook/bos/twilio-sms`
  (ang user/password ng "BOS Twilio Webhook Auth")
- Ilagay ang numero sa business: `update bos.businesses set sms_from = '+44…' where slug = '…';`

### 6. VAPI (AI Receptionist)
1. Sa VAPI dashboard, gumawa ng credential na **Bearer Token**: header `Authorization`, naka-on ang Bearer prefix, token = **secret A**. Kopyahin ang credential ID.
2. `python3 vapi/build_assistant.py brightsmile-demo "BrightSmile Dental" Sophie Europe/London https://n8n.yourdomain.com <credential-id>`
3. Gumawa ng assistant gamit ang nabuong JSON (dashboard o `POST https://api.vapi.ai/assistant`). Piliin ang voice sa dashboard.
4. `update bos.businesses set vapi_assistant_id = 'asst_…' where slug = 'brightsmile-demo';`
5. Opsyonal: mag-attach ng phone number sa assistant para sa totoong tawag.

### 7. Website button
- Ilagay ang `web/voice-button-snippet.html` (VAPI **public** key + assistant ID).
- **Sa kasalukuyang Netlify site:** haharangin ito ng `netlify.toml` (`microphone=()` at mahigpit na CSP). Basahin ang comment sa snippet para sa eksaktong babaguhin.

### 8. Google Calendar
- I-share ang calendar ng bawat business sa Google account na naka-connect sa n8n ("Make changes to events"), tapos: `update bos.businesses set calendar_id = '…@group.calendar.google.com' where slug = '…';`

### 9. Bagong client
Kopyahin ang `db/010_add_business_TEMPLATE.sql`, punan, at i-run. Pagkatapos ay ulitin ang step 5–8 para sa numero, assistant, website at calendar nila.

## Live acceptance test (naka-`test_mode` muna; SMS ay sa `test_numbers` lang)
1. Website button: magtanong ng oras → mag-book → may SMS confirmation → may event sa Google Calendar.
2. Tawagan ang VAPI number: hanapin ang booking (dapat walang tanong na verification dahil caller ID) → i-reschedule → dapat na-update ang SMS at ang parehong calendar event.
3. Mag-text ng "C" → dapat confirmed. Mag-text ng "pwede ba lumipat sa Friday 3pm?" → sasagot ang AI at ililipat.
4. I-cancel → cancellation SMS → na-delete ang calendar event.
5. Gawing 2 minuto ang reminder offset → dapat dumating ang reminder. Ibalik pagkatapos.
6. Tingnan ang `bos.errors`: dapat walang laman. Tingnan ang `bos.jobs`: dapat walang `failed`.
7. Kapag pumasa lahat: `update bos.businesses set test_mode = false where slug = '…';`

## Status ng verification (tapat)
| Bahagi | Status |
|---|---|
| Database logic (59 checks, concurrency race, DST) | **VERIFIED** sa local Postgres 16 |
| n8n Code nodes + SQL calls + response formats (30 checks) | **VERIFIED** gamit ang harness na tumatakbo sa totoong JS at SQL mula sa workflow JSON |
| Workflow JSON: node versions, parameter names, credentials | **VERIFIED** laban sa n8n source (v2.41) at static checks |
| Import sa totoong n8n, Twilio, Google Calendar, OpenAI agent, VAPI live call | **HINDI PA NA-TEST.** Walang access dito sa n8n server at sa mga provider. Gawin ang Live acceptance test sa itaas. |

## Mga limitasyon na dapat alam
- **One-way ang Google Calendar** (system → calendar). Hindi hinaharangan ng events na idinagdag nang mano-mano sa Google Calendar ang slots. Gamitin ang `bos.blocked_times` para sa leave o holidays.
- **Iisang Twilio account kada n8n instance** (magkakaibang numero kada business).
- **Walang email channel pa.** SMS lang.
- **Hindi pa nakakonekta ang lumang dashboard (dentalzample.netlify.app) sa bagong API.** Iyon ang susunod na hakbang.
- **Walang Dentally sync.** Kailangan muna ng partner o Pro-plan API access.
- **Seguridad:** ang lumang PATCH11 JSON ay may webhook secret na naka-hardcode sa Code nodes. Huwag na itong gamitin muli, at i-rotate kung aktibo pa.

---

## Client acquisition module (ACQ) — bago

Hanapin ang mga business → i-qualify → CRM pipeline → AI draft → **approval ng tao** → send → replies → demo → sales call → follow-ups → Won → onboarding. Nasa schema `acq`, hiwalay sa `bos`.

| File | Ano ito |
|---|---|
| `db/020`–`024_acq_*.sql` | Schema, CRM, outreach, replies/demos/meetings, follow-ups/onboarding/metrics. Puwedeng i-run nang paulit-ulit. |
| `db/tests/p1`–`p5.sql`, `db/run_acq_tests.sh`, `db/run_acq_tests_final.sh` | SQL tests. **Throwaway DB lang.** |
| `n8n/acq/10`–`19-*.json` | ACQ workflows (generated ng `n8n/acq_build.py` — huwag i-edit ang JSON nang mano-mano) |
| `n8n/acq_harness.js`, `n8n/validate.js` | Contract harness at static validation |
| `supabase/functions/acq-api`, `acq-track`, `acq-demo`, `resend-webhook` | Edge functions (secure dashboard actions, tracking/unsubscribe, demo page, Resend webhook) |
| `run_acq_all.sh` | Lahat ng local checks sa isang command |
| `BACKEND_BUILD_STATUS.md` | **Basahin ito**: ano ang built, env vars, manual setup, testing checklist, risks |
