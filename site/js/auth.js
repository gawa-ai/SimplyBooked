// Minimal Supabase Auth client (REST). Only the publishable key ever reaches the browser.
// Emailed links use the PKCE flow: the link only works in the browser that asked for it, so nobody can sign
// someone else into their account by sending them a crafted link.
import { CONFIG } from './config.js';

const KEY = 'simplybooked.session';
const PKCE_KEY = 'simplybooked.pkce';
const AUTH = `${CONFIG.supabaseUrl}/auth/v1`;

export class AuthError extends Error {
  constructor(message, code, status = 0) { super(message); this.code = code || 'auth_error'; this.status = status; }
}

function friendly(body, status) {
  const code = body?.error_code || body?.code || body?.error || '';
  const raw = body?.msg || body?.error_description || body?.message || '';
  const err = (msg, c) => new AuthError(msg, c || String(code) || `http_${status}`, status);
  if (code === 'invalid_credentials' || /invalid login credentials/i.test(raw)) return err('That email and password don\'t match. Check them and try again.', 'invalid_credentials');
  if (code === 'email_not_confirmed') return err('Confirm your email address first, using the link we sent you.');
  if (code === 'over_request_rate_limit' || code === 'over_email_send_rate_limit' || status === 429) return err('Too many attempts. Wait a minute, then try again.', 'rate_limited');
  if (code === 'otp_disabled' || code === 'user_not_found' || /signups not allowed/i.test(raw)) return err('There is no SimplyBooked account for that email.', 'user_not_found');
  if (code === 'weak_password' || /password should/i.test(raw)) return err(raw || 'Choose a longer password.', 'weak_password');
  if (code === 'same_password') return err('Your new password must be different from the old one.');
  if (code === 'flow_state_not_found' || code === 'flow_state_expired' || code === 'bad_code_verifier' || /code verifier/i.test(raw)) {
    return err('That link has expired, or was opened in a different browser. Request a new one here.', 'link_invalid');
  }
  return err(raw || 'Something went wrong. Try again in a moment.');
}

async function call(path, { method = 'POST', body, token, query } = {}) {
  const url = new URL(`${AUTH}${path}`);
  if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  const headers = { apikey: CONFIG.publishableKey, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  let res;
  try {
    res = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined });
  } catch {
    throw new AuthError('We couldn\'t reach SimplyBooked. Check your connection and try again.', 'network');
  }
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = null; }
  if (!res.ok) throw friendly(data, res.status);
  return data;
}

/* ---------- session storage (shared by every open tab) ---------- */

let memory = null; // used only when localStorage is unavailable

function read() {
  try { return JSON.parse(localStorage.getItem(KEY) || 'null'); } catch { return memory; }
}

function save(s, previousUser = null) {
  if (!s?.access_token) return null;
  const expiresIn = Number(s.expires_in);
  const session = {
    access_token: s.access_token,
    refresh_token: s.refresh_token,
    // the browser's own clock decides expiry, so a computer with the wrong time still behaves
    expires_at: Math.floor(Date.now() / 1000) + (expiresIn > 0 ? expiresIn : 3600),
    user: s.user ? { id: s.user.id, email: s.user.email } : previousUser,
  };
  memory = session;
  try { localStorage.setItem(KEY, JSON.stringify(session)); } catch { /* private mode: this page only */ }
  return session;
}

export function clearSession() {
  memory = null;
  try { localStorage.removeItem(KEY); } catch { /* ignore */ }
}

const fresh = (s) => s?.access_token && s.expires_at - 60 > Date.now() / 1000;

let refreshing = null;
function refresh(stale) {
  if (!refreshing) {
    refreshing = (async () => {
      // another tab may already have refreshed: reuse its tokens instead of spending the old refresh token again
      const now = read();
      if (now && now.refresh_token !== stale.refresh_token && fresh(now)) return now;
      try {
        const d = await call('/token', { query: { grant_type: 'refresh_token' }, body: { refresh_token: stale.refresh_token } });
        return save(d, stale.user);
      } catch (e) {
        // only a rejected refresh token ends the session; outages and rate limits do not
        if (e.status === 400 || e.status === 401 || e.status === 403) {
          const latest = read();
          if (latest && latest.refresh_token !== stale.refresh_token && fresh(latest)) return latest;
          clearSession();
        }
        throw e;
      }
    })().finally(() => { refreshing = null; });
  }
  return refreshing;
}

/** Returns a valid session (refreshing it when close to expiry) or null. */
export async function getSession() {
  const s = read();
  if (!s?.access_token) return null;
  if (fresh(s)) return s;
  if (!s.refresh_token) { clearSession(); return null; }
  try { return await refresh(s); } catch { return null; }
}

/** Forces a refresh (used after a 401). */
export async function forceRefresh() {
  const s = read();
  if (!s?.refresh_token) { clearSession(); return null; }
  try { return await refresh({ ...s, expires_at: 0 }); } catch { return null; }
}

/* ---------- sign-in ---------- */

export async function signInWithPassword(email, password) {
  const d = await call('/token', { query: { grant_type: 'password' }, body: { email, password } });
  return save(d);
}

const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
async function startPkce(type) {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(48)));
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  try { localStorage.setItem(PKCE_KEY, JSON.stringify({ verifier, type, at: Date.now() })); } catch { /* links then need the same tab */ }
  return { code_challenge: b64url(digest), code_challenge_method: 's256' };
}

// Only existing users can receive a sign-in link: accounts are created by the organisation owner.
export async function sendMagicLink(email, redirectTo) {
  await call('/otp', { query: { redirect_to: redirectTo }, body: { email, create_user: false, ...(await startPkce('magiclink')) } });
}

export async function sendPasswordReset(email, redirectTo) {
  await call('/recover', { query: { redirect_to: redirectTo }, body: { email, ...(await startPkce('recovery')) } });
}

export async function updatePassword(password) {
  const s = await getSession();
  if (!s) throw new AuthError('Your reset link has expired. Request a new one.', 'expired');
  await call('/user', { method: 'PUT', token: s.access_token, body: { password } });
}

export async function signOut() {
  const s = await getSession();
  clearSession();
  if (s?.access_token) { try { await call('/logout', { token: s.access_token, query: { scope: 'local' } }); } catch { /* already signed out here */ } }
}

const LINK_ERRORS = {
  otp_expired: 'That link has expired or was already used. Request a new one.',
  access_denied: 'That link can\'t be used any more. Request a new one.',
};

/**
 * Handles the return from an emailed link. Returns { type } after signing in, { error } when the link can't be
 * used, or null when the URL carries nothing for us. Error text shown to people is always our own wording.
 */
export async function consumeAuthRedirect() {
  const query = new URLSearchParams(location.search);
  const hash = new URLSearchParams(location.hash.replace(/^#/, ''));
  const clean = () => history.replaceState(null, '', location.pathname);

  if (query.get('error') || query.get('error_code') || hash.get('error') || hash.get('error_code')) {
    const code = query.get('error_code') || hash.get('error_code') || query.get('error') || hash.get('error');
    clean();
    return { error: LINK_ERRORS[code] || 'That link didn\'t work. Request a new one.' };
  }

  const code = query.get('code');
  if (code) {
    clean();
    let pkce = null;
    try { pkce = JSON.parse(localStorage.getItem(PKCE_KEY) || 'null'); } catch { pkce = null; }
    if (!pkce?.verifier) return { error: 'Open the link in the same browser you requested it from, or request a new one here.' };
    try {
      const d = await call('/token', { query: { grant_type: 'pkce' }, body: { auth_code: code, code_verifier: pkce.verifier } });
      save(d);
    } catch (e) {
      return { error: e.message };
    } finally {
      try { localStorage.removeItem(PKCE_KEY); } catch { /* ignore */ }
    }
    return { type: pkce.type || 'magiclink' };
  }

  // Invitations sent from the Supabase dashboard still arrive with tokens in the address. They are only accepted
  // as invitations, and the person must then choose their own password.
  if (hash.get('access_token') && hash.get('type') === 'invite') {
    clean();
    const access = hash.get('access_token');
    try {
      const user = await call('/user', { method: 'GET', token: access });
      save({ access_token: access, refresh_token: hash.get('refresh_token'), expires_in: hash.get('expires_in'), user });
    } catch (e) {
      return { error: e.message };
    }
    return { type: 'invite' };
  }
  if (hash.get('access_token')) { clean(); return { error: 'That link can\'t be used here. Request a new sign-in link.' }; }
  return null;
}
