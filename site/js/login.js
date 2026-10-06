import { signInWithPassword, sendMagicLink, sendPasswordReset, updatePassword, getSession, consumeAuthRedirect } from './auth.js';

const $ = (s) => document.querySelector(s);
const form = $('.js-form');
const email = $('#email');
const password = $('#password');
const submit = $('.js-submit');
const errorEl = $('.js-error');
const notice = $('.js-notice');
const fieldEmail = $('.js-field-email');
const fieldPassword = $('.js-field-password');
const toReset = $('.js-to-reset');
const toLink = $('.js-to-link');
const toPassword = $('.js-to-password');
const reveal = $('.js-reveal');

const APP = '/app.html';
const here = () => `${location.origin}/login.html`;

const MODES = {
  password: { title: 'Welcome back', sub: 'Sign in to see today\'s bookings, calls and messages.', button: 'Sign in', email: true, password: true, autocomplete: 'current-password' },
  link: { title: 'Sign in with a link', sub: 'We\'ll email you a one-time link. No password needed.', button: 'Email me a link', email: true, password: false },
  reset: { title: 'Reset your password', sub: 'Enter your email and we\'ll send you a link to choose a new password.', button: 'Send reset link', email: true, password: false },
  newPassword: { title: 'Choose a new password', sub: 'Use at least 8 characters. You\'ll stay signed in afterwards.', button: 'Save new password', email: false, password: true, autocomplete: 'new-password', label: 'New password' },
};
let mode = 'password';

function setMode(next, { keepNotice = false } = {}) {
  mode = next;
  const m = MODES[next];
  $('.js-title').textContent = m.title;
  $('.js-sub').textContent = m.sub;
  submit.textContent = m.button;
  fieldEmail.hidden = !m.email;
  fieldPassword.hidden = !m.password;
  email.required = m.email;
  password.required = m.password;
  password.autocomplete = m.autocomplete || 'current-password';
  $('.js-password-label').textContent = m.label || 'Password';
  toReset.hidden = next !== 'password';
  toLink.hidden = next !== 'password';
  toPassword.hidden = !(next === 'link' || next === 'reset');
  $('.js-alt').hidden = next === 'newPassword';
  showError('');
  if (!keepNotice) showNotice('');
  (m.email ? email : password).focus();
}

function showError(msg) {
  errorEl.textContent = msg;
  errorEl.hidden = !msg;
  email.setAttribute('aria-invalid', msg && mode !== 'newPassword' ? 'true' : 'false');
  password.setAttribute('aria-invalid', msg && MODES[mode].password ? 'true' : 'false');
}
function showNotice(msg, isError = false) {
  notice.textContent = msg;
  notice.hidden = !msg;
  notice.classList.toggle('is-error', isError);
}
function busy(on) {
  submit.disabled = on;
  submit.setAttribute('aria-busy', String(on));
}

const validEmail = (v) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  showError('');
  const m = MODES[mode];
  const em = email.value.trim();
  if (m.email && !validEmail(em)) return showError('Enter the email address you use for SimplyBooked.');
  if (m.password && password.value.length < (mode === 'newPassword' ? 8 : 1)) {
    return showError(mode === 'newPassword' ? 'Use at least 8 characters.' : 'Enter your password.');
  }
  busy(true);
  try {
    if (mode === 'password') {
      await signInWithPassword(em, password.value);
      location.replace(APP);
      return;
    }
    if (mode === 'newPassword') {
      await updatePassword(password.value);
      location.replace(APP);
      return;
    }
    try {
      if (mode === 'link') await sendMagicLink(em, here());
      else await sendPasswordReset(em, here());
    } catch (err) {
      // Never reveal whether an account exists for an email address.
      if (err.code !== 'user_not_found') throw err;
    }
    showNotice(mode === 'link'
      ? `If ${em} has a SimplyBooked account, a sign-in link is on its way. It works once and expires soon.`
      : `If ${em} has a SimplyBooked account, a reset link is on its way.`);
  } catch (err) {
    showError(err.message);
  } finally {
    busy(false);
  }
});

toReset.addEventListener('click', () => setMode('reset'));
toLink.addEventListener('click', () => setMode('link'));
toPassword.addEventListener('click', () => setMode('password'));
reveal.addEventListener('click', () => {
  const show = password.type === 'password';
  password.type = show ? 'text' : 'password';
  reveal.textContent = show ? 'Hide' : 'Show';
  reveal.setAttribute('aria-pressed', String(show));
  password.focus();
});

// Film: never autoplay for visitors who prefer reduced motion; hide it quietly if it can't load.
const film = document.querySelector('.login-film video');
if (film) {
  film.addEventListener('error', () => film.classList.add('is-broken'), true);
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) { film.removeAttribute('autoplay'); film.pause(); }
}

async function handleAuthRedirect(initial) {
  const result = await consumeAuthRedirect();
  if (result?.error) { setMode('password'); showNotice(result.error, true); return; }
  if (result?.type === 'recovery' || result?.type === 'invite') { setMode('newPassword'); return; }
  if (result) { location.replace(APP); return; }
  if (initial) {
    if (await getSession()) { location.replace(APP); return; }
    email.focus();
  }
}
// Email links normally open a fresh page, but the same tab may already be on this page.
window.addEventListener('hashchange', () => handleAuthRedirect(false));
handleAuthRedirect(true);
