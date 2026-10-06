# SimplyBooked website

Static site deployed by Netlify (`netlify.toml` at the repo root, publish folder `site/`). No build tools and no third-party scripts.

| Page | What it is |
|---|---|
| `index.html` | Landing page |
| `login.html` | Sign in: password, emailed sign-in link, and password reset |
| `app.html` | Dashboard. **Front desk** (Overview, Calendar, Calls and texts) for a business's own bookings; **Growth** (Sales, Pipeline, Approvals, Replies, Meetings, Clients) for the SimplyBooked team |
| `app.html?demo=1` | Front desk of a fictional barbershop, for showing prospects. Nothing is saved or sent. |
| `app.html?demo=sales` | Front desk plus the Growth screens, with sample data |

## Who sees what
- **SimplyBooked team** (a row in `acq.profiles`): Growth screens, plus the Front desk of every client whose booking system is provisioned (pick the business in the sidebar).
- **A client's owner or staff**: only their own business's Front desk. Give access with
  `select acq.add_client_user('<client id>', 'owner@theirbusiness.co.uk');` (run as an admin of your organisation, after creating their user under Authentication → Users). Switch it off with `acq.set_client_user_active('<client id>', '<email>', false)`.
- Front desk data comes from the `acq.portal_*` functions (migration `025_acq_client_portal.sql`). They check access on every call; the booking schema `bos` is never exposed.

## How the dashboard talks to Supabase
- **Front desk reads** call `acq.portal_overview / portal_day / portal_upcoming / portal_activity` with the signed-in user's token.
- **Reads** go to PostgREST views in the `acq` schema (`v_leads`, `v_outreach`, `v_replies`, `v_meetings`, `v_clients`, `dashboard_metrics()`), using the signed-in user's token. Row-level security limits every read to the user's own organisation.
- **Changes** go to the `acq-api` edge function, which validates input, rate-limits each user, and runs the change with the user's own token, so the database re-checks their role.
- Only the **publishable** key is in `js/config.js`. Never put a secret key in the website.

## Media
The photos and films are SimplyBooked generations from Higgsfield, listed in `scripts/media.txt`. On each deploy, Netlify runs `scripts/fetch-media.sh`, which copies them into `site/media/`. The deploy fails if a file can't be fetched, so a page with missing media is never published. Photos are resized on the fly by Netlify Image CDN (`/.netlify/images?...`).

## One-time setup
1. **Netlify:** import the GitHub repo. The build settings come from `netlify.toml`.
2. **Supabase → Edge Functions → Secrets:** set `ACQ_ALLOWED_ORIGINS` to the site's address, for example `https://simplybooked.netlify.app`. Otherwise `acq-api` refuses requests from the website.
3. **Supabase → Authentication → URL Configuration:** set **Site URL** to the site's address and add `https://<your-site>/login.html` to **Redirect URLs**. Sign-in links and password resets depend on this.
4. **Optional:** to show a "Book a call" button on the landing page, set `contactEmail` in `js/config.js`.

## Local preview
`python3 -m http.server -d site 8000`, then open `http://localhost:8000/app.html?demo=1`. Media and `/.netlify/images` only work once the site is deployed.
