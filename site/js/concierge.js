// Web concierge: demo receptionist (text first, optional free browser voice).
// All answers and bookings come from the server (/api/concierge); no secret or key lives in the browser.
const API = '/api/concierge';
const $ = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; };
const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
const canSpeak = 'speechSynthesis' in window;

let businesses = [], biz = null, session = '', turn = 0, busy = false;
let voiceMode = false, rec = null, listening = false, finalText = '', sendTimer = 0;
const el = {};

function newSession() {
  const a = new Uint8Array(8); crypto.getRandomValues(a);
  session = Array.from(a, b => b.toString(16).padStart(2, '0')).join('');
  turn = 0;
}
function add(text, cls) {
  const m = $('div', 'cc-msg ' + cls, text);
  el.log.appendChild(m); el.log.scrollTop = el.log.scrollHeight; return m;
}
function say(text) {
  if (!canSpeak || !voiceMode) return Promise.resolve();
  return new Promise(res => {
    const u = new SpeechSynthesisUtterance(text); u.lang = 'en-GB'; u.rate = 1.03;
    const v = speechSynthesis.getVoices().find(x => /en-GB/i.test(x.lang)) || speechSynthesis.getVoices().find(x => /^en/i.test(x.lang));
    if (v) u.voice = v;
    u.onend = u.onerror = () => res();
    speechSynthesis.cancel(); speechSynthesis.speak(u);
  });
}
function stopListening() { listening = false; clearTimeout(sendTimer); try { rec && rec.abort(); } catch (e) {} el.mic && el.mic.classList.remove('live'); }
function startListening() {
  if (!SR || !voiceMode || busy) return;
  finalText = '';
  rec = new SR(); rec.lang = 'en-GB'; rec.interimResults = true; rec.continuous = false;
  rec.onresult = ev => {
    let t = '';
    for (const r of ev.results) t += r[0].transcript;
    el.input.value = t; finalText = t; clearTimeout(sendTimer);
    sendTimer = setTimeout(() => { const x = finalText.trim(); if (x) { stopListening(); send(x); } }, 1600);
  };
  rec.onerror = ev => { if (ev.error === 'not-allowed' || ev.error === 'service-not-allowed') { voiceMode = false; add('Microphone is blocked. You can keep typing instead.', 'sys'); } stopListening(); };
  rec.onend = () => { if (listening && voiceMode && !busy && !finalText.trim()) { try { rec.start(); } catch (e) {} } };
  try { rec.start(); listening = true; el.mic.classList.add('live'); } catch (e) {}
}
function toggleVoice() {
  voiceMode = !voiceMode;
  el.mic.setAttribute('aria-pressed', String(voiceMode));
  if (voiceMode) { add('Voice on. Just speak and I will answer out loud.', 'sys'); startListening(); }
  else { stopListening(); if (canSpeak) speechSynthesis.cancel(); }
}

async function send(text) {
  text = text.trim(); if (!text || busy || !biz) return;
  busy = true; el.input.value = ''; el.send.disabled = true; el.starters.hidden = true;
  add(text, 'me');
  const typing = add('', 'bot'); const dots = $('span', 'cc-typing'); dots.append($('i'), $('i'), $('i')); typing.appendChild(dots);
  turn += 1;
  let reply = 'Sorry, something went wrong. Please try again.';
  let preview = null;
  try {
    const ctl = new AbortController(); const to = setTimeout(() => ctl.abort(), 40000);
    const r = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ business: biz.slug, session, message: text, turn }) });
    clearTimeout(to);
    if (r.status === 429) reply = 'You are going a little fast. Please wait a moment and try again.';
    else if (r.ok) { const j = await r.json(); if (j && j.reply) reply = String(j.reply); if (j && j.preview) preview = j.preview; }
  } catch (e) { reply = 'I could not reach the system just now. Please try again.'; }
  typing.textContent = reply;
  if (preview) addPreview(preview);
  el.log.scrollTop = el.log.scrollHeight;
  busy = false; el.send.disabled = false;
  await say(reply);
  if (voiceMode) startListening(); else el.input.focus();
}

function addPreview(p) {
  const card = $('div', 'cc-preview');
  card.appendChild($('div', 'cc-pv-h', 'Sample only: nothing is actually sent in this demo'));
  if (p.sms) { const t = $('div', 'cc-pv-sms'); t.appendChild($('b', '', 'Text to customer')); t.appendChild($('span', '', String(p.sms))); card.appendChild(t); }
  if (p.calendar) { const c = $('div', 'cc-pv-cal'); c.appendChild($('b', '', 'Google Calendar')); c.appendChild($('span', '', String(p.calendar.title) + ' · ' + String(p.calendar.when))); card.appendChild(c); }
  el.log.appendChild(card); el.log.scrollTop = el.log.scrollHeight;
}

function pick(b) {
  biz = b; newSession(); stopListening();
  if (canSpeak) speechSynthesis.cancel();
  el.log.textContent = '';
  el.name.textContent = b.receptionist + ' · ' + b.name;
  el.chips.forEach(c => c.setAttribute('aria-pressed', String(c.dataset.slug === b.slug)));
  add('Hi, this is ' + b.receptionist + ' at ' + b.name + '. How can I help?', 'bot');
  el.starters.textContent = ''; el.starters.hidden = false;
  (b.starters || []).forEach(s => { const c = $('button', 'cc-chip', s); c.type = 'button'; c.addEventListener('click', () => send(s)); el.starters.appendChild(c); });
  if (voiceMode) { say('Hi, this is ' + b.receptionist + ' at ' + b.name + '. How can I help?').then(startListening); }
}

function build() {
  const launch = $('button', 'cc-launch'); launch.type = 'button';
  launch.append($('span', 'cc-dot'), document.createTextNode('Try our AI receptionist'));
  const p = $('section', 'cc-panel'); p.setAttribute('role', 'dialog'); p.setAttribute('aria-label', 'AI receptionist demo');
  const head = $('div', 'cc-head'); const av = $('div', 'cc-avatar', 'S');
  const tt = $('div', 'cc-title'); const b1 = $('b', '', 'AI receptionist demo'); el.name = $('span', '', 'Pick a business to try');
  tt.append(b1, el.name);
  const x = $('button', 'cc-x', '×'); x.type = 'button'; x.setAttribute('aria-label', 'Close');
  head.append(av, tt, x);
  const picker = $('div', 'cc-picker'); picker.setAttribute('role', 'group'); picker.setAttribute('aria-label', 'Choose a demo business');
  el.log = $('div', 'cc-log'); el.log.setAttribute('aria-live', 'polite');
  el.starters = $('div', 'cc-starters'); el.starters.hidden = true;
  const form = $('form', 'cc-form');
  el.input = $('input', 'cc-input'); el.input.type = 'text'; el.input.placeholder = 'Type your message…'; el.input.maxLength = 500; el.input.autocomplete = 'off';
  el.input.setAttribute('aria-label', 'Your message');
  el.mic = $('button', 'cc-btn mic', '🎤'); el.mic.type = 'button'; el.mic.setAttribute('aria-label', 'Talk instead of typing'); el.mic.setAttribute('aria-pressed', 'false');
  if (!SR) el.mic.hidden = true;
  el.send = $('button', 'cc-btn', '➤'); el.send.type = 'submit'; el.send.setAttribute('aria-label', 'Send');
  form.append(el.input, el.mic, el.send);
  const foot = $('div', 'cc-foot', 'Demo with sample businesses. AI can make mistakes. Voice uses your browser (Chrome or Edge work best).');
  p.append(head, picker, el.log, el.starters, form, foot);
  document.body.append(launch, p);

  const open = async () => {
    p.classList.add('open'); launch.hidden = true;
    if (!businesses.length) {
      try { const r = await fetch(API + '/businesses'); businesses = r.ok ? await r.json() : []; } catch (e) { businesses = []; }
      if (!businesses.length) { add('The demo is unavailable right now. Please try again later.', 'sys'); return; }
      el.chips = businesses.map(b => { const c = $('button', 'cc-chip', b.industry ? b.industry.replace(/^./, m => m.toUpperCase()) : b.name); c.type = 'button'; c.dataset.slug = b.slug; c.setAttribute('aria-pressed', 'false'); c.addEventListener('click', () => pick(b)); picker.appendChild(c); return c; });
      pick(businesses[0]);
    }
    el.input.focus();
  };
  const close = () => { p.classList.remove('open'); launch.hidden = false; stopListening(); voiceMode = false; el.mic.setAttribute('aria-pressed', 'false'); if (canSpeak) speechSynthesis.cancel(); launch.focus(); };
  launch.addEventListener('click', open); x.addEventListener('click', close);
  p.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
  form.addEventListener('submit', e => { e.preventDefault(); send(el.input.value); });
  el.mic.addEventListener('click', toggleVoice);
  if (canSpeak) speechSynthesis.getVoices();
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', build); else build();
