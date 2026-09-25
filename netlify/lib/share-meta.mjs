// ─────────────────────────────────────────────────────────────
// Pure helpers for the share-preview edge function.
//
// Kept out of netlify/edge-functions/ so Netlify does not register
// them as a function, and kept dependency-free so plain node can
// test them — which matters, because the edge function itself only
// runs on a deploy and this is where the logic worth checking lives.
//
// Nothing here touches the network or the DOM. Given a path and an
// item, it returns a string of tags and splices it into HTML.
// ─────────────────────────────────────────────────────────────

export const SITE_NAME = 'SeRuh'
export const TAGLINE = 'Where Feelings Find Words'

/** Which piece of content, if any, a path is asking for. */
export function parseTarget(pathname) {
  const p = String(pathname || '/').replace(/\/+$/, '') || '/'
  let m
  if ((m = p.match(/^\/q\/([A-Za-z0-9-]{1,64})$/))) return { kind: 'quote', id: m[1] }
  if ((m = p.match(/^\/f\/([A-Za-z0-9-]{1,64})$/))) return { kind: 'feeling', id: m[1] }
  if ((m = p.match(/^\/mood\/([a-z0-9-]{1,40})$/i))) return { kind: 'mood', slug: m[1].toLowerCase() }
  if ((m = p.match(/^\/c\/([a-z0-9-]{1,60})$/i))) return { kind: 'category', slug: m[1].toLowerCase() }
  if (p === '/daily') return { kind: 'daily' }
  if (p === '/') return { kind: 'home' }
  return { kind: 'none' }
}

const titleCase = (s) => String(s).split('-').filter(Boolean)
  .map(w => w[0].toUpperCase() + w.slice(1)).join(' ')

/** Collapse a written line into something that fits a preview card. */
export function flatten(text, max = 200) {
  const t = String(text ?? '').replace(/\s*\n+\s*/g, ' ').replace(/\s{2,}/g, ' ').trim()
  if (t.length <= max) return t
  // cut on a word boundary rather than mid-word
  const cut = t.slice(0, max)
  const sp = cut.lastIndexOf(' ')
  return (sp > max * 0.6 ? cut.slice(0, sp) : cut).trimEnd() + '…'
}

export function escapeAttr(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

/**
 * The title and description a given target should preview as.
 * `item` is whatever the caller managed to fetch; when it is missing
 * the result still describes the page sensibly, so a failed upstream
 * read degrades to a decent generic card instead of a broken one.
 */
export function describe(target, item) {
  switch (target.kind) {
    case 'quote':
      if (!item?.quote) break
      return {
        title: `${flatten(item.quote, 60)} — ${SITE_NAME}`,
        description: flatten(item.quote, 200),
        section: item.category || null,
      }
    case 'feeling':
      if (!item?.content) break
      return {
        title: `${flatten(item.content, 60)} — ${SITE_NAME}`,
        description: flatten(item.content, 200),
        section: item.category || null,
      }
    case 'mood':
      return {
        title: `Feeling ${titleCase(target.slug)} — ${SITE_NAME}`,
        description: `Words for when you feel ${titleCase(target.slug).toLowerCase()}. ${SITE_NAME} — ${TAGLINE}.`,
        section: null,
      }
    case 'category':
      return {
        title: `${titleCase(target.slug)} — ${SITE_NAME}`,
        description: `${titleCase(target.slug)} on ${SITE_NAME}. ${TAGLINE}.`,
        section: titleCase(target.slug),
      }
    case 'daily':
      if (item?.quote) {
        return {
          title: `Today on ${SITE_NAME}`,
          description: flatten(item.quote, 200),
          section: null,
        }
      }
      return { title: `Today on ${SITE_NAME}`, description: `A feeling a day. ${TAGLINE}.`, section: null }
  }
  return {
    title: `${SITE_NAME} — ${TAGLINE}`,
    description: `For the thoughts we feel, but don't always know how to say. ${SITE_NAME} — ${TAGLINE}.`,
    section: null,
  }
}

/**
 * Build the tag block. og:image is deliberately absent until there is
 * a real per-quote image to point at — a card with no image beats one
 * pointing at a 404, and every platform falls back to a text card.
 */
export function buildMeta({ target, item, url }) {
  const d = describe(target, item)
  const type = (target.kind === 'quote' || target.kind === 'feeling') ? 'article' : 'website'
  const tags = [
    `<link rel="canonical" href="${escapeAttr(url)}">`,
    `<meta property="og:type" content="${type}">`,
    `<meta property="og:site_name" content="${escapeAttr(SITE_NAME)}">`,
    `<meta property="og:url" content="${escapeAttr(url)}">`,
    `<meta property="og:title" content="${escapeAttr(d.title)}">`,
    `<meta property="og:description" content="${escapeAttr(d.description)}">`,
    `<meta property="og:locale" content="en_IN">`,
    `<meta name="twitter:card" content="summary">`,
    `<meta name="twitter:title" content="${escapeAttr(d.title)}">`,
    `<meta name="twitter:description" content="${escapeAttr(d.description)}">`,
  ]
  if (d.section) tags.push(`<meta property="article:section" content="${escapeAttr(d.section)}">`)
  return { tags: tags.join('\n'), title: d.title, description: d.description }
}

/**
 * Bolt the comments widget onto the deployed app.
 *
 * The app's source does not exist, so the only place to add a script
 * to it is on the way out. Deferred, so it never delays first paint,
 * and appended last so a failure to fetch it leaves the page whole.
 */
export function injectWidget(html, src = '/seruh-comments.js') {
  if (typeof html !== 'string') return html;
  const close = html.search(/<\/body>/i);
  if (close === -1) return html;
  if (html.includes(src)) return html;
  return html.slice(0, close) + `<script src="${src}" defer></script>\n` + html.slice(close);
}

/**
 * Splice the tags into <head>, replacing the build's own <title> and
 * meta description so a shared quote does not preview under the
 * generic homepage title. Returns the original HTML untouched if the
 * document is not shaped as expected.
 */
export function injectMeta(html, { tags, title, description }) {
  if (typeof html !== 'string' || !/<head[\s>]/i.test(html)) return html
  let out = html
  out = out.replace(/<title>[\s\S]*?<\/title>/i, `<title>${escapeAttr(title)}</title>`)
  out = out.replace(
    /<meta\s+name=["']description["'][^>]*>/i,
    `<meta name="description" content="${escapeAttr(description)}">`
  )
  const close = out.search(/<\/head>/i)
  if (close === -1) return out
  return out.slice(0, close) + tags + '\n' + out.slice(close)
}
