// Resolves the project's API keys inside an Edge Function.
// Supabase injects the new keys as JSON dictionaries (SUPABASE_SECRET_KEYS / SUPABASE_PUBLISHABLE_KEYS, key "default")
// and, for now, the legacy JWT keys (SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY, retired end of 2026).
// Prefer the new keys; fall back to the legacy ones. Never logs or returns a key in an error message.
type Get = (name: string) => string | undefined;

function fromDict(get: Get, name: string, keyName: string): string | null {
  const raw = get(name);
  if (!raw) return null;
  try {
    const v = (JSON.parse(raw) as Record<string, unknown>)[keyName];
    return typeof v === 'string' && v.length > 0 ? v : null;
  } catch { return null; }
}

export function serviceKey(get: Get, keyName = 'default'): string {
  const k = fromDict(get, 'SUPABASE_SECRET_KEYS', keyName) ?? get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!k) throw new Error('server key not configured (SUPABASE_SECRET_KEYS / SUPABASE_SERVICE_ROLE_KEY)');
  return k;
}

export function publicKey(get: Get, keyName = 'default'): string {
  const k = fromDict(get, 'SUPABASE_PUBLISHABLE_KEYS', keyName) ?? get('SUPABASE_ANON_KEY') ?? '';
  if (!k) throw new Error('public key not configured (SUPABASE_PUBLISHABLE_KEYS / SUPABASE_ANON_KEY)');
  return k;
}
