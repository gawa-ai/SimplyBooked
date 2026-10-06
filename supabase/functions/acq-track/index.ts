// Supabase Edge Function entrypoint (Deno). PUBLIC endpoint: deploy with  supabase functions deploy acq-track --no-verify-jwt
// Secrets: SUPABASE_URL + the server API key (injected; new sb_secret key preferred, legacy service_role as fallback). The service role is used ONLY for two service-only RPCs:
// acq.hit_rate_limit and acq.unsubscribe_by_token (which accepts nothing but a 32-hex token).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { serviceKey } from '../_shared/keys.ts';
import { handle, type Deps } from './handler.ts';

const svc = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(k => Deno.env.get(k)), { auth: { persistSession: false }, db: { schema: 'acq' } });
const deps: Deps = {
  async rateLimit(key, limit, windowS) {
    const { data, error } = await svc.rpc('hit_rate_limit', { p_key: key, p_limit: limit, p_window_s: windowS });
    if (error) throw error;
    return data as { allowed: boolean; retry_after_s: number };
  },
  async unsubscribe(token) {
    const { error } = await svc.rpc('unsubscribe_by_token', { p_token: token });
    if (error) throw error;
  },
};
Deno.serve(req => handle(req, deps));
