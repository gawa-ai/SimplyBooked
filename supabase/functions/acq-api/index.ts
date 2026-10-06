// Supabase Edge Function entrypoint (Deno). Secrets are read from function secrets, never hard-coded:
//   SUPABASE_URL + the project API keys (injected by Supabase; new sb_* keys preferred, legacy JWT keys as fallback),
//   ACQ_ALLOWED_ORIGINS (comma list, set by you)
// Deploy: supabase functions deploy acq-api --no-verify-jwt
//   The gateway JWT check does not understand the new API keys, so the handler authenticates every request itself:
//   it rejects calls without a user JWT and validates that JWT with Supabase Auth (auth.getUser) before doing anything.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { serviceKey, publicKey } from '../_shared/keys.ts';
import { handle, type Deps } from './handler.ts';

const url = Deno.env.get('SUPABASE_URL')!;
const env = (k: string) => Deno.env.get(k);
const anon = publicKey(env);
const service = serviceKey(env);
const allowedOrigins = (Deno.env.get('ACQ_ALLOWED_ORIGINS') ?? '').split(',').map(s => s.trim()).filter(Boolean);

// service client is used ONLY for the rate limiter (acq.hit_rate_limit) — never for business actions
const svc = createClient(url, service, { auth: { persistSession: false }, db: { schema: 'acq' } });

const deps: Deps = {
  allowedOrigins,
  async getUserId(jwt) {
    const { data, error } = await createClient(url, anon, { auth: { persistSession: false } }).auth.getUser(jwt);
    return error ? null : data.user?.id ?? null;
  },
  userDb(jwt) {
    const c = createClient(url, anon, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false }, db: { schema: 'acq' } });
    return { rpc: (name, args) => c.rpc(name, args) as never };
  },
  async rateLimit(key, limit, windowS) {
    const { data, error } = await svc.rpc('hit_rate_limit', { p_key: key, p_limit: limit, p_window_s: windowS });
    if (error) throw error;
    return data as { allowed: boolean; retry_after_s: number };
  },
};

Deno.serve(req => handle(req, deps));
