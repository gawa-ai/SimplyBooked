// Supabase Edge Function entrypoint (Deno). PUBLIC endpoint: supabase functions deploy acq-demo --no-verify-jwt
// Secrets: SUPABASE_URL + the server API key (injected; new sb_secret key preferred, legacy service_role as fallback), ACQ_DEMO_ORIGINS (comma list of the demo page origins, set by you).
// The service role calls ONLY these service-only RPCs: hit_rate_limit, demo_view, demo_click, meeting_slots, book_meeting.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { serviceKey } from '../_shared/keys.ts';
import { handle, type Deps } from './handler.ts';

const svc = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(k => Deno.env.get(k)), { auth: { persistSession: false }, db: { schema: 'acq' } });
const deps: Deps = {
  allowedOrigins: (Deno.env.get('ACQ_DEMO_ORIGINS') ?? '').split(',').map(s => s.trim()).filter(Boolean),
  async rateLimit(key, limit, windowS) {
    const { data, error } = await svc.rpc('hit_rate_limit', { p_key: key, p_limit: limit, p_window_s: windowS });
    if (error) throw error;
    return data as { allowed: boolean; retry_after_s: number };
  },
  rpc: (name, args) => svc.rpc(name, args) as never,
};
Deno.serve(req => handle(req, deps));
