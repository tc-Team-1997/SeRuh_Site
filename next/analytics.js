// ─────────────────────────────────────────────────────────────
// Analytics for the /next front end.
//
// Same privacy contract as src/services/analytics.js, but with no
// build step: /next is plain modules served as-is, so configuration
// is passed in rather than read from import.meta.env.
//
// The rule that matters is unchanged and is enforced structurally,
// not by discipline: parameters pass an allowlist, so a feeling, a
// reply, a search, a name or an id cannot leave even if a caller
// passes one by mistake. On a platform where the content IS the
// vulnerable part, that has to be impossible rather than avoided.
// ─────────────────────────────────────────────────────────────

let measurementId = '';
let debug = false;
let initialised = false;

export const ALLOWED_PARAMS = new Set([
  'page_path', 'page_title', 'page_group',
  'emotion', 'category', 'visibility', 'share_method',
  'result_count', 'length_bucket', 'reason', 'decision',
  'source', 'surface', 'is_returning', 'error_kind',
]);

function cleanValue(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'boolean') return v;
  if (typeof v === 'string') return v.slice(0, 60);
  return undefined;
}

export function sanitize(params = {}) {
  const out = {};
  for (const [k, v] of Object.entries(params || {})) {
    if (!ALLOWED_PARAMS.has(k)) continue;
    const value = cleanValue(v);
    if (value !== undefined) out[k] = value;
  }
  return out;
}

/** Buckets, so "how long do people write" is answerable without ever holding what they wrote. */
export function lengthBucket(text) {
  const n = String(text ?? '').trim().length;
  if (n === 0) return '0';
  if (n <= 40) return '1-40';
  if (n <= 140) return '41-140';
  if (n <= 400) return '141-400';
  return '400+';
}

export const isEnabled = () => /^G-[A-Z0-9]{6,}$/.test(measurementId);

function gtag(...args) {
  window.dataLayer = window.dataLayer || [];
  window.dataLayer.push(args);
}

/** Load gtag once. Safe to call repeatedly; a no-op without an id. */
export function initAnalytics({ id = '', debug: dbg = false } = {}) {
  try {
    if (initialised) return;
    initialised = true;
    measurementId = String(id || '');
    debug = !!dbg;
    if (!isEnabled()) return;

    const s = document.createElement('script');
    s.async = true;
    s.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(measurementId)}`;
    document.head.appendChild(s);

    gtag('js', new Date());
    gtag('config', measurementId, {
      // page_view is ours, so gtag cannot add an unexpected one
      send_page_view: false,
      anonymize_ip: true,
      allow_google_signals: false,
      allow_ad_personalization_signals: false,
      debug_mode: debug,
    });
  } catch { /* analytics must never break the page */ }
}

export function trackEvent(name, params = {}) {
  try {
    if (!isEnabled()) return;
    // typeof first: test() would coerce null to "null", which matches
    if (typeof name !== 'string' || !/^[a-z][a-z0-9_]{1,39}$/.test(name)) return;
    gtag('event', name, sanitize(params));
  } catch { /* ignore */ }
}

let lastPath = null;
export function trackPageView(path, title) {
  try {
    const p = path || (typeof location !== 'undefined' ? location.pathname : '/');
    if (p === lastPath) return;
    lastPath = p;
    if (!isEnabled()) return;
    gtag('event', 'page_view', sanitize({
      page_path: p,
      page_title: title || (typeof document !== 'undefined' ? document.title : undefined),
      page_group: 'next',
    }));
  } catch { /* ignore */ }
}

/* ── the events this product actually wants answered ──────────
   Every one of these asks "which feature makes people come back",
   and none of them carries what anyone wrote. */

export const trackShareThoughtClicked = (surface) => trackEvent('share_thought_clicked', { surface });
export const trackThoughtSubmitted = ({ emotion, category, body } = {}) =>
  trackEvent('thought_submitted', { emotion, category, length_bucket: lengthBucket(body) });
export const trackThoughtRejected = (reason) => trackEvent('thought_rejected', { reason });
export const trackEmotionSelected = (emotion, surface) => trackEvent('emotion_selected', { emotion, surface });
export const trackCategorySelected = (category) => trackEvent('category_selected', { category });
export const trackFeelThisToo = (on) => trackEvent(on ? 'feel_this_too' : 'feel_this_too_undone', {});
export const trackReplySubmitted = ({ body } = {}) => trackEvent('reply_submitted', { length_bucket: lengthBucket(body) });
export const trackShareOpened = () => trackEvent('share_opened', {});
export const trackShareClicked = (method) => trackEvent('share_clicked', { share_method: method });
export const trackRandomThought = () => trackEvent('random_thought_clicked', {});
export const trackDailyViewed = () => trackEvent('daily_seruh_viewed', {});
export const trackReportSubmitted = (reason) => trackEvent('report_submitted', { reason });
export const trackAfterDarkViewed = (count) => trackEvent('after_dark_viewed', { result_count: count });
