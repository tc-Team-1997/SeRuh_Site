// ─────────────────────────────────────────────────────────────
// Share previews, without touching the application source.
//
// Crawlers and link unfurlers — WhatsApp, Slack, X, Google — do not
// run JavaScript. They read the HTML at a URL. SeRuh ships a single
// inlined bundle whose <head> carries one generic title and nothing
// else, so every shared link previews as bare text no matter which
// quote it points at.
//
// This runs at the edge, reads the content for the path from the
// public API, and splices Open Graph and Twitter tags into the HTML
// on the way out. The app itself is untouched.
//
// Safety posture — this sits in front of every HTML response, so a
// failure here is a site outage rather than a missing tag:
//   · everything is inside one try/catch that returns the original
//     response on any error;
//   · the upstream read has a hard timeout and is skipped entirely
//     for paths that need no content;
//   · a non-HTML or unexpected response is passed straight through.
// ─────────────────────────────────────────────────────────────

import { parseTarget, buildMeta, injectMeta } from '../lib/share-meta.mjs'

export const config = {
  path: ['/', '/daily', '/q/*', '/f/*', '/mood/*', '/c/*'],
}

const UPSTREAM_TIMEOUT_MS = 1500

// AbortSignal.timeout only bounds the request if the runtime's fetch
// honours it. This handler runs in front of every HTML response, so
// the bound should not rest on that assumption: race the read against
// a timer as well, and take whichever finishes first.
function withDeadline(promise, ms) {
  let t
  return Promise.race([
    promise.finally(() => clearTimeout(t)),
    new Promise((resolve) => { t = setTimeout(() => resolve(null), ms) }),
  ])
}

// The anon key is public by design — it ships inside the page — so
// reading it from the environment is configuration, not a secret.
// Falls back to skipping the content read rather than failing.
function supabase() {
  const url = Deno.env.get('SUPABASE_URL') || Deno.env.get('VITE_SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_ANON_KEY') || Deno.env.get('VITE_SUPABASE_ANON_KEY')
  return url && key ? { url, key } : null
}

async function fetchItem(target) {
  // Only these need content; the rest describe themselves.
  if (target.kind !== 'quote' && target.kind !== 'feeling' && target.kind !== 'daily') return null
  const cfg = supabase()
  if (!cfg) return null

  const path = target.kind === 'quote'
    ? `rest/v1/quotes_public?select=quote,category,mood&id=eq.${encodeURIComponent(target.id)}&limit=1`
    : target.kind === 'feeling'
      // feelings_public is the wall view: PUBLISHED and PUBLIC/ANONYMOUS
      // only, so a PRIVATE feeling can never be previewed here.
      ? `rest/v1/feelings_public?select=content,category,mood&id=eq.${encodeURIComponent(target.id)}&limit=1`
      : `rest/v1/rpc/get_todays_feeling`

  const res = await fetch(`${cfg.url}/${path}`, {
    method: target.kind === 'daily' ? 'POST' : 'GET',
    headers: { apikey: cfg.key, 'Content-Type': 'application/json' },
    body: target.kind === 'daily' ? '{}' : undefined,
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  })
  if (!res.ok) return null
  const data = await res.json()
  return Array.isArray(data) ? (data[0] ?? null) : (data ?? null)
}

export default async function handler(request, context) {
  const response = await context.next()

  try {
    const type = response.headers.get('content-type') || ''
    if (!type.includes('text/html')) return response

    const target = parseTarget(new URL(request.url).pathname)
    if (target.kind === 'none') return response

    let item = null
    try {
      item = await withDeadline(fetchItem(target), UPSTREAM_TIMEOUT_MS)
    } catch {
      // timeout, network, bad JSON — fall through to the generic card
      item = null
    }

    const url = new URL(request.url)
    url.search = ''
    url.hash = ''

    const meta = buildMeta({ target, item, url: url.toString() })
    const html = await response.text()
    const injected = injectMeta(html, meta)

    const headers = new Headers(response.headers)
    headers.delete('content-length')
    return new Response(injected, { status: response.status, headers })
  } catch {
    // Never let a preview problem become a site problem.
    return response
  }
}
