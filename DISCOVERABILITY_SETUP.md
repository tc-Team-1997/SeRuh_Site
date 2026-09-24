# SeRuh — Discoverability

Two problems, both fixed without touching the application source.

**Shared links previewed as bare text.** SeRuh ships one inlined bundle whose `<head>` carries a single generic title. Every shared link — a quote, a feeling, the homepage — unfurled identically, with no quote and no image. On a product whose content travels by forwarded message, that is the growth loop severed at its exit.

**Nothing was indexable.** One URL, no `robots.txt`, no sitemap, and any deep path returning 404.

| Added | What it does |
| --- | --- |
| `netlify/edge-functions/share-preview.js` | Injects Open Graph + Twitter tags per path, at the edge |
| `netlify/lib/share-meta.mjs` | The pure logic — path parsing, card text, HTML injection |
| `netlify/lib/share-meta.test.mjs` | 40 assertions on the pure logic |
| `netlify/lib/share-preview.integration.test.mjs` | 30 assertions on the handler itself |
| `_redirects` | `/q/:id`, `/f/:id`, `/mood/:m`, `/c/:slug`, `/daily` serve the app |
| `robots.txt` | Crawl guidance, points at the sitemap |
| `sitemap.xml` | 62 URLs, generated |
| `scripts/generate-sitemap.mjs` | Regenerates it from the public API |

---

## What you must do

**1. Give the edge function the Supabase config.** Netlify → Site configuration → Environment variables:

```
SUPABASE_URL       https://stowxeobdtvhapkzsvaq.supabase.co
SUPABASE_ANON_KEY  <the anon key already in index.html>
```

Neither is a secret — both ship inside the page today. Scope them to **Functions** (edge functions read them at request time, not build time).

> **This project's PostgREST default exposed schema is not `public`.** A bare REST request returns `PGRST205 — Could not find the table 'api.quotes_public'`. The site is unaffected because supabase-js names the schema itself, but anything using raw `fetch` must send `Accept-Profile: public` on reads and `Content-Profile: public` on RPC calls. The edge function and the sitemap generator both do, and the integration suite asserts it. Worth checking Project Settings → API → Exposed schemas: `api` appears to be listed first and does not contain the views.

Without them the function still runs and still injects a complete card; it just cannot fetch the quote, so an item previews under the brand title instead of its own text. It degrades, it does not fail.

**2. Deploy.** Netlify picks up `netlify/edge-functions/` automatically — there is no `netlify.toml`, and none was added, so your existing deploy settings are untouched.

**3. Verify with the platforms' own debuggers**, not by reading the markup:

- Facebook / WhatsApp — [Sharing Debugger](https://developers.facebook.com/tools/debug/)
- X — [Card Validator](https://cards-dev.twitter.com/validator)
- LinkedIn — [Post Inspector](https://www.linkedin.com/post-inspector/)
- Slack — paste the link into any channel

Try `https://seruh.netlify.app/f/<id>` for a real wall post. Expect the post's own words as the title and description.

**4. Submit the sitemap** in Google Search Console once `/sitemap.xml` returns 200.

---

## What changes for a visitor

Nothing visible yet, and that is deliberate. `/q/<id>` now serves the app instead of 404, but the app still opens at the homepage because its navigation is hash-based and it does not read the path. A crawler sees the right quote; a person sees the homepage.

That gap closes with **E-02's in-app half**, which needs the application source. Until then the preview is honest about the content and the landing is generic — worth shipping, because the preview is the half that decides whether anyone clicks at all.

---

## Regenerating the sitemap

```bash
node scripts/generate-sitemap.mjs --dry   # report only
node scripts/generate-sitemap.mjs         # write sitemap.xml
```

It reads Supabase config out of `index.html`, so it needs no environment. Re-run it when quotes are added or the wall grows meaningfully; the file is committed, not built.

**It reads only the public views** — `quotes_public`, `categories_public`, `feelings_public`. Those exclude `PRIVATE` and anything not `PUBLISHED`, so a private feeling cannot reach the sitemap by construction. The script asserts that anyway, along with URL uniqueness, origin, and the 50k limit, and refuses to write if any assertion fails.

---

## Safety

This function sits in front of **every HTML response**, so its failure mode is a site outage rather than a missing tag. Four guards:

- One `try/catch` around the whole handler returns the original response on any error.
- The upstream read has its own `try/catch`, a 1.5 s `AbortSignal.timeout`, **and** a `Promise.race` deadline. The signal alone only bounds the request if the runtime's fetch honours it; integration testing caught the handler hanging against an upstream that ignored the signal, so the bound no longer rests on that assumption.
- Paths needing no content — `/`, `/mood/*`, `/c/*` — make no upstream call at all.
- A non-HTML response is passed straight through untouched.

Content is escaped for attribute context before injection. Test section 6 pushes `"goodbye" & <script>alert(1)</script>` through as a feeling and asserts nothing script-shaped reaches the page.

`/f/:id` reads `feelings_public`, never the `feelings` table, so a `PRIVATE` feeling cannot be previewed even if someone guesses its id.

**Known cost:** the handler buffers the 777 KB response to do the injection, which defeats streaming and adds a small amount of latency on every HTML request. Acceptable at this page weight; it becomes worth revisiting if the bundle grows or if code splitting lands.

---

## Regression notes

Run before and after any change here:

```bash
node netlify/lib/share-meta.test.mjs                  # 40 assertions, pure logic
node netlify/lib/share-preview.integration.test.mjs   # 30 assertions, the handler
node scripts/generate-sitemap.mjs --dry               # asserts, writes nothing
```

The integration suite imports `share-preview.js` unmodified and shims only `Deno.env`, so what it exercises is what ships: a real wall post end to end, the homepage making no upstream call, missing configuration, four kinds of upstream failure, non-HTML and 404 pass-through, hostile paths, and an assertion that `/f/:id` reads `feelings_public` and never the `feelings` table.

Checked explicitly, because these are the ways this change could break the existing product:

| Risk | Status |
| --- | --- |
| `_redirects` swallowing `#/admin` or `#/me` | **Safe by construction** — a fragment never reaches the server. Only five explicit prefixes are rewritten; there is no catch-all. |
| Unknown paths becoming soft 404s | **Avoided** — no `/*` rule, so a typo still returns a real 404. |
| Injection corrupting the page | Asserted: exactly one `<title>`, one description, body and charset untouched, tags inside `<head>`. Dry-run against the live 777 KB bundle grew it by 1,262 bytes with the root div intact. |
| Private content previewed or indexed | Public views only, in both the function and the generator. |
| Edge function failing the site | Returns the original response on any error; a hanging upstream is bounded twice over. Verified against a stub that ignores the abort signal. |

After deploying, confirm by hand: the homepage still loads, `#/admin` still reaches the admin panel, and `#/me` still opens My SeRuh.
