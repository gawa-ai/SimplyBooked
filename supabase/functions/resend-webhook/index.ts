// Supabase Edge Function entrypoint (Deno). PUBLIC endpoint: deploy with  supabase functions deploy resend-webhook --no-verify-jwt
// Secrets (set with `supabase secrets set`, never in code): RESEND_WEBHOOK_SECRET (whsec_...), SUPABASE_URL + the server API key (injected; new sb_secret key preferred, legacy service_role as fallback).
// Resend dashboard -> Webhooks -> endpoint https://<project-ref>.supabase.co/functions/v1/resend-webhook
import { createClient } from 'npm:@supabase/supabase-js@2';
import { serviceKey } from '../_shared/keys.ts';
import { handle, type Deps } from './handler.ts';

const svc = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(k => Deno.env.get(k)), { auth: { persistSession: false }, db: { schema: 'acq' } });
const deps: Deps = {
  secret: Deno.env.get('RESEND_WEBHOOK_SECRET') ?? '',
  now: () => Date.now(),
  async record(args) {
    const { error } = await svc.rpc('record_delivery_event', args);
    if (error) throw error;
  },
};
Deno.serve(req => handle(req, deps));
