import { CONFIG } from './config.js';

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

// Header gets a hairline once the page scrolls.
const head = document.querySelector('.site-head');
const onScroll = () => head && head.classList.toggle('is-scrolled', window.scrollY > 8);
onScroll();
window.addEventListener('scroll', onScroll, { passive: true });

// "Book a call" appears only when a contact address is configured.
const email = (CONFIG.contactEmail || '').trim();
if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
  for (const a of document.querySelectorAll('.js-contact')) {
    a.href = `mailto:${email}?subject=${encodeURIComponent('SimplyBooked — book a call')}`;
    a.hidden = false;
  }
}

// Keep the example confirmation text in the near future: next Thursday at least two days away, in UK time.
const sms = document.querySelector('.sms');
if (sms) {
  const d = new Date(Date.now() + 2 * 864e5);
  while (new Intl.DateTimeFormat('en-GB', { weekday: 'short', timeZone: 'Europe/London' }).format(d) !== 'Thu') d.setTime(d.getTime() + 864e5);
  const when = new Intl.DateTimeFormat('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'Europe/London' }).format(d).replace(',', '');
  const text = `Hi Emma, your haircut at Leo's is booked for ${when} at 2:30pm. Ref K7Q2MP. Reply C to confirm.`;
  sms.querySelector('p').textContent = text;
  sms.setAttribute('aria-label', `Example confirmation text: ${text}`);
}

const year = document.querySelector('.js-year');
if (year) year.textContent = String(new Date().getFullYear());

// Films: lazy-load below the fold, play only while visible, never autoplay when the visitor prefers reduced motion.
const videos = [...document.querySelectorAll('video.js-video')];

function load(v) {
  if (v.dataset.src && !v.getAttribute('src') && !v.querySelector('source')) {
    v.src = v.dataset.src;
    v.preload = 'auto';
  }
}
function play(v) {
  if (reduceMotion.matches) return;
  load(v);
  const p = v.play();
  if (p && typeof p.catch === 'function') p.catch(() => { /* autoplay refused: the poster or first frame stays */ });
}
function pause(v) { if (!v.paused) v.pause(); }

for (const v of videos) {
  // a film that cannot load leaves its frame's calm background (and poster) instead of a broken player
  v.addEventListener('error', () => v.classList.add('is-broken'), true);
  if (reduceMotion.matches) {
    v.removeAttribute('autoplay');
    pause(v);
    v.preload = 'metadata';
    load(v);
  }
}

if ('IntersectionObserver' in window) {
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) (e.isIntersecting ? play : pause)(e.target);
  }, { rootMargin: '200px 0px', threshold: 0.15 });
  videos.forEach((v) => io.observe(v));
} else {
  videos.forEach(play);
}

reduceMotion.addEventListener?.('change', () => videos.forEach((v) => (reduceMotion.matches ? pause(v) : null)));

// "Watch the film": plays the brand film in a dialog, with controls; stops when closed.
const filmDialog = document.querySelector('.js-film-dialog');
const filmVideo = filmDialog?.querySelector('video');
document.querySelector('.js-film')?.addEventListener('click', () => {
  if (!filmDialog) return;
  filmDialog.showModal();
  filmDialog.querySelector('.js-film-close')?.focus();
  const p = filmVideo?.play();
  if (p && typeof p.catch === 'function') p.catch(() => {});
});
filmDialog?.querySelector('.js-film-close')?.addEventListener('click', () => filmDialog.close());
filmDialog?.addEventListener('click', (e) => { if (e.target === filmDialog) filmDialog.close(); });
filmDialog?.addEventListener('close', () => { filmVideo?.pause(); });

// The reel moves on its own, so it can be paused (WCAG 2.2.2).
const reel = document.querySelector('.reel');
const reelToggle = document.querySelector('.js-reel-toggle');
reelToggle?.addEventListener('click', () => {
  const paused = reel.classList.toggle('is-paused');
  reelToggle.setAttribute('aria-pressed', String(paused));
  reelToggle.textContent = paused ? 'Play the reel' : 'Pause the reel';
});
