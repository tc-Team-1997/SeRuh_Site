// ─────────────────────────────────────────────────────────────
// Google Analytics 4 — the only place gtag is touched.
//
//   UI components  →  analytics (this module)  →  gtag.js  →  GA4
//
// This sits alongside the existing first-party tracking in
// services/api.js (api.track → track_event → analytics_events),
// which stays exactly as it is. That one answers "what does the
// admin Analytics page show"; this one answers "how public is
// SeRuh becoming". Neither replaces the other.
//
// Three rules this module keeps, so callers don't have to:
//   1. It never throws. Analytics failing is not a reason for
//      SeRuh to fail.
//   2. It never sends what a person wrote. Parameters go through
//      an allowlist; anything not on it is dropped.
//   3. It never sends a page_view twice for the same view, even
//      under StrictMode's double-invoked effects.
// ─────────────────────────────────────────────────────────────

const MEASUREMENT_ID = import.meta.env.VITE_GA_MEASUREMENT_ID || ''
const DEBUG = import.meta.env.VITE_GA_DEBUG === 'true'

// Real sends happen in production, or anywhere VITE_GA_DEBUG=true is
// set deliberately. Local development stays out of production data.
export const isAnalyticsEnabled =
  /^G-[A-Z0-9]{6,}$/.test(MEASUREMENT_ID) && (import.meta.env.PROD || DEBUG)

/* ═══════════════════════ privacy allowlist ═══════════════════════
   Every parameter SeRuh is allowed to send. A feeling, a quote body,
   a search query, a name, an email, a token — none of it is on this
   list, so none of it can leave, even if a caller passes it by
   mistake. Add to this list deliberately, never casually. */

const ALLOWED_PARAMS = new Set([
  'page_path', 'page_title', 'page_group',
  'quote_id', 'feeling_id', 'category', 'mood', 'style', 'length',
  'visibility', 'share_method', 'search_type', 'result_count',
  'query_length', 'reason', 'source', 'decision', 'traffic_type',
  'is_returning', 'error_kind',
])

// Values are scalars only, clamped. An object or array would be a
// route for text to slip through nested.
function cleanValue(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v
  if (typeof v === 'boolean') return v
  if (typeof v === 'string') return v.slice(0, 60)
  return undefined
}

function sanitize(params = {}) {
  const out = {}
  for (const [k, v] of Object.entries(params)) {
    if (!ALLOWED_PARAMS.has(k)) continue
    const value = cleanValue(v)
    if (value !== undefined) out[k] = value
  }
  return out
}

// Buckets, so "how long are people's searches" is answerable without
// ever holding what they searched for.
function lengthBucket(text) {
  const n = String(text ?? '').trim().length
  if (n === 0) return '0'
  if (n <= 10) return '1-10'
  if (n <= 25) return '11-25'
  if (n <= 60) return '26-60'
  return '60+'
}

/* ═══════════════════════ initialisation ═══════════════════════ */

let initialised = false
let internalTraffic = false

function gtag(...args) {
  window.dataLayer = window.dataLayer || []
  window.dataLayer.push(args)
}

/** Load gtag.js once and configure it. Safe to call repeatedly. */
export function initAnalytics() {
  try {
    if (initialised) return
    initialised = true

    if (!isAnalyticsEnabled) {
      if (import.meta.env.DEV && !MEASUREMENT_ID) {
        console.info('[analytics] VITE_GA_MEASUREMENT_ID not set — GA4 disabled (this is fine locally)')
      }
      return
    }

    // async, after paint: analytics must not sit in front of the app
    const s = document.createElement('script')
    s.async = true
    s.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(MEASUREMENT_ID)}`
    s.onerror = () => { if (import.meta.env.DEV) console.info('[analytics] gtag failed to load — SeRuh continues normally') }
    document.head.appendChild(s)

    gtag('js', new Date())
    gtag('config', MEASUREMENT_ID, {
      // page_view is sent by trackPageView, never automatically —
      // otherwise the first view is counted twice.
      send_page_view: false,
      anonymize_ip: true,
      // no user_id, no user properties: SeRuh sends product
      // behaviour, not people.
      allow_google_signals: false,
      allow_ad_personalization_signals: false,
      debug_mode: DEBUG,
    })
  } catch { /* analytics must never break the app */ }
}

/**
 * Mark this session as internal (admin / platform manager) so GA4 can
 * filter it out of public engagement metrics. This is the parameter
 * GA4's own "internal traffic" data filter reads — see
 * ANALYTICS_SETUP.md. It is a reporting hint, never a security control.
 */
export function setInternalTraffic(isInternal) {
  try {
    internalTraffic = !!isInternal
    if (isAnalyticsEnabled) {
      gtag('set', { traffic_type: internalTraffic ? 'internal' : undefined })
    }
  } catch { /* ignore */ }
}

/* ═══════════════════════ event core ═══════════════════════ */

/** Send any event. Prefer the named helpers below over calling this directly. */
export function trackEvent(name, params = {}) {
  try {
    if (!isAnalyticsEnabled) return
    // typeof first: test() would coerce null to "null", which matches
    if (typeof name !== 'string' || !/^[a-z][a-z0-9_]{1,39}$/.test(name)) return
    const payload = sanitize(params)
    if (internalTraffic) payload.traffic_type = 'internal'
    gtag('event', name, payload)
  } catch { /* ignore */ }
}

/* ═══════════════════════ pageviews ═══════════════════════
   SeRuh has no router — navigation is window.location.hash, read by
   the two hashchange listeners already in the app. So "pages" are
   derived from the hash and sent as virtual pageviews. No second
   routing mechanism is introduced.

     #/admin…       → /admin
     #/me/saved     → /me/saved
     #explore       → /explore
     (none) or #    → /                                            */

const SECTIONS = new Set(['home', 'explore', 'today', 'unsaid', 'write', 'generate', 'story'])

/** Translate a location hash into a stable virtual page path. */
export function pathFromHash(hash = '') {
  const h = String(hash).replace(/^#/, '')
  if (!h) return '/'
  if (h.startsWith('/admin')) {
    const sub = h.replace(/^\/admin\/?/, '').split(/[?#]/)[0]
    return sub ? `/admin/${sub}` : '/admin'
  }
  if (h.startsWith('/me')) {
    const sub = h.replace(/^\/me\/?/, '').split(/[?#]/)[0]
    return sub ? `/me/${sub}` : '/me'
  }
  const anchor = h.split(/[?#]/)[0]
  if (SECTIONS.has(anchor)) return `/${anchor}`
  return anchor ? `/${anchor.slice(0, 40)}` : '/'
}

function pageGroupOf(path) {
  if (path.startsWith('/admin')) return 'admin'
  if (path.startsWith('/me')) return 'my_seruh'
  return 'public'
}

// Module scope, so StrictMode re-running an effect cannot resend:
// React remounts components, it does not reload the module.
let lastPath = null

/**
 * Send a page_view for the current (or given) path. Repeated calls for
 * the same path are ignored, which is what makes this safe under
 * StrictMode, re-renders, and a hashchange that lands on the same view.
 */
export function trackPageView(path, title) {
  try {
    const p = path || pathFromHash(typeof window !== 'undefined' ? window.location.hash : '')
    if (p === lastPath) return
    lastPath = p
    if (!isAnalyticsEnabled) return
    gtag('event', 'page_view', sanitize({
      page_path: p,
      page_title: title || (typeof document !== 'undefined' ? document.title : undefined),
      page_group: pageGroupOf(p),
      ...(internalTraffic ? { traffic_type: 'internal' } : {}),
    }))
  } catch { /* ignore */ }
}

/**
 * Wire pageviews to the navigation the app already uses: one initial
 * view, then one per hashchange and per back/forward. Call once, from
 * the app root. Returns a cleanup function.
 */
export function startPageViewTracking() {
  try {
    if (typeof window === 'undefined') return () => {}
    const onNav = () => trackPageView()
    trackPageView()                                   // initial load / refresh / direct hash
    window.addEventListener('hashchange', onNav)      // in-app navigation
    window.addEventListener('popstate', onNav)        // back / forward
    return () => {
      window.removeEventListener('hashchange', onNav)
      window.removeEventListener('popstate', onNav)
    }
  } catch {
    return () => {}
  }
}

/* ═══════════════════════ SeRuh events ═══════════════════════
   Named helpers, so no component ever writes a raw event name or
   decides which parameters are safe.

   Call the success-shaped ones (liked, saved, published, completed)
   only after the backend has confirmed. See ANALYTICS_SETUP.md. */

/* ── discovery ── */
export const trackSearch = ({ searchType = 'quote_search', resultCount, query } = {}) =>
  trackEvent('search_performed', {
    search_type: searchType,
    result_count: typeof resultCount === 'number' ? resultCount : undefined,
    query_length: lengthBucket(query),   // a bucket, never the query
  })

export const trackMoodSelected = (mood) => trackEvent('mood_selected', { mood })
export const trackSurpriseMe = () => trackEvent('surprise_me_clicked')
export const trackDailySeRuhViewed = (quote) =>
  trackEvent('daily_seruh_viewed', { quote_id: quote?.id, category: quote?.category, mood: quote?.mood })

/* ── quote engagement ── */
const quoteParams = (q) => ({ quote_id: q?.id, category: q?.category, mood: q?.mood })

export const trackQuoteViewed = (q) => trackEvent('quote_viewed', quoteParams(q))
export const trackQuoteLiked = (q) => trackEvent('quote_liked', quoteParams(q))
export const trackQuoteUnliked = (q) => trackEvent('quote_unliked', quoteParams(q))
export const trackQuoteSaved = (q) => trackEvent('quote_saved', quoteParams(q))
export const trackQuoteUnsaved = (q) => trackEvent('quote_unsaved', quoteParams(q))
export const trackQuoteCopied = (q) => trackEvent('quote_copied', quoteParams(q))
export const trackQuoteShared = (q, shareMethod = 'other') =>
  trackEvent('quote_shared', { ...quoteParams(q), share_method: shareMethod })

/* ── feelings ──
   Only metadata: visibility, category, mood. Never the feeling. An
   anonymous or private feeling contributes a count and nothing else. */
export const trackFeelingStarted = () => trackEvent('feeling_started')

export const trackFeelingSubmitted = ({ visibility, category, mood } = {}) =>
  trackEvent('feeling_submitted', { visibility, category, mood })

export const trackFeelingPublished = ({ visibility, category, mood, decision } = {}) =>
  trackEvent('feeling_published', { visibility, category, mood, decision })

export const trackFeelingRejected = ({ decision = 'REJECT', reason } = {}) =>
  trackEvent('feeling_rejected', { decision, reason })

export const trackFeelingReported = (reason) => trackEvent('feeling_reported', { reason })
export const trackFeelingDeleted = () => trackEvent('feeling_deleted')

/* ── AI ── */
export const trackAIGenerationStarted = ({ mood, style, length } = {}) =>
  trackEvent('ai_generation_started', { mood, style, length })

export const trackAIGenerationCompleted = ({ mood, style, length } = {}) =>
  trackEvent('ai_generation_completed', { mood, style, length })

export const trackAIGenerationFailed = ({ errorKind = 'unknown' } = {}) =>
  trackEvent('ai_generation_failed', { error_kind: errorKind })

/* ── sharing ── */
export const trackShareCardGenerated = (q) => trackEvent('share_card_generated', quoteParams(q))
export const trackShareClicked = (shareMethod = 'other') =>
  trackEvent('share_clicked', { share_method: shareMethod })

/* ── auth (counts only — never an identity) ── */
export const trackSignedUp = () => trackEvent('sign_up_completed')
export const trackLoggedIn = () => trackEvent('login_completed')
