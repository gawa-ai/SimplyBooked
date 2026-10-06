// Data access for the dashboard.
//   reads  -> PostgREST on the `acq` schema, with the signed-in user's token (row-level security applies)
//   writes -> the acq-api edge function, which validates, rate-limits and re-checks the user's role
import { CONFIG } from './config.js';
import { getSession, forceRefresh, clearSession } from './auth.js';

export class ApiError extends Error {
  constructor(message, { status = 0, code = 'error' } = {}) { super(message); this.status = status; this.code = code; }
}

const MESSAGES = {
  forbidden: 'Your role doesn\'t allow that. Ask the account owner.',
  rate_limited: 'That was a lot of changes at once. Wait a few seconds and try again.',
  origin_not_allowed: 'This website isn\'t on the dashboard\'s allowed list yet. Add it to ACQ_ALLOWED_ORIGINS in Supabase.',
  unauthenticated: 'Your session has ended. Sign in again.',
  internal_error: 'Something went wrong on our side. Try again in a moment.',
  invalid_status_change: 'A lead can\'t move straight to that stage.',
};

async function request(url, init, retry = true) {
  const s = await getSession();
  if (!s) throw new ApiError(MESSAGES.unauthenticated, { status: 401, code: 'unauthenticated' });
  const headers = { ...init.headers, Authorization: `Bearer ${s.access_token}` };
  let res;
  try { res = await fetch(url, { ...init, headers }); }
  catch { throw new ApiError('We couldn\'t reach SimplyBooked. Check your connection and try again.', { code: 'network' }); }
  if (res.status === 401) {
    if (retry) {
      const fresh = await forceRefresh();
      if (fresh) return request(url, init, false);
    }
    clearSession();
    throw new ApiError(MESSAGES.unauthenticated, { status: 401, code: 'unauthenticated' });
  }
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  if (!res.ok) {
    const code = body?.error || body?.code || `http_${res.status}`;
    const msg = MESSAGES[code] || body?.message || body?.details || MESSAGES.internal_error;
    throw new ApiError(msg, { status: res.status, code });
  }
  return body;
}

/** GET a view/table in the acq schema. `query` is a PostgREST query string (already encoded). */
export function select(view, query = '') {
  return request(`${CONFIG.supabaseUrl}/rest/v1/${view}${query ? `?${query}` : ''}`, {
    method: 'GET',
    headers: { apikey: CONFIG.publishableKey, 'Accept-Profile': 'acq', Accept: 'application/json' },
  });
}

/** Read-only RPC in the acq schema (e.g. dashboard_metrics). */
export function rpc(fn, args = {}) {
  return request(`${CONFIG.supabaseUrl}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: CONFIG.publishableKey, 'Content-Profile': 'acq', 'Accept-Profile': 'acq', 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
}

/** Every change goes through the acq-api edge function. Only these two headers are allowed by its CORS policy. */
export async function action(name, params = {}) {
  const body = await request(`${CONFIG.supabaseUrl}/functions/v1/acq-api`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: name, params }),
  });
  if (body?.ok !== true) {
    throw new ApiError(MESSAGES[body?.error] || body?.message || 'That change wasn\'t accepted.', { status: 400, code: body?.error || 'rejected' });
  }
  const data = body.data;
  if (data && typeof data === 'object' && data.ok === false) {
    throw new ApiError(data.message || MESSAGES[data.error] || 'That change wasn\'t accepted.', { status: 400, code: data.error || 'rejected' });
  }
  return data;
}
