# SeRuh — Analytics Setup

Two systems, kept deliberately separate, plus the first-party tracking SeRuh already had.

| System | Answers | Where it lives |
| --- | --- | --- |
| **Netlify Web Analytics** | How much traffic, from where, to which pages | Netlify dashboard — no code |
| **Google Analytics 4** | What people do once they arrive | `src/services/analytics.js` |
| **First-party `analytics_events`** *(already existed)* | The admin Analytics page | `api.track()` → `track_event` RPC |

The third one is **not** being replaced. It feeds `admin_analytics_overview`, `admin_category_stats`, `admin_top_quotes` and `admin_ai_stats`, and it already records `category_view`, `feeling_submit`, `login`, `logout`, `quote_copy`, `quote_share`, `random_quote`, `search` and `signup`. GA4 sits beside it and answers a different question: reach and growth, rather than what the admin panel charts.

---

## Architecture notes that shape this

**SeRuh has no router.** There is no `react-router`, no `pushState` routing. Navigation is `window.location.hash`, read by two `hashchange` listeners already in the app:

```
#/admin…              → admin shell
#/me, #/me/saved, …   → My SeRuh
#home #explore #today #unsaid #write #generate #story   → sections of the public one-page site
```

So GA4 "pages" are **virtual pageviews derived from the hash**, sent on load, on `hashchange` and on `popstate`. No second routing mechanism is introduced. `pathFromHash()` does the mapping and `startPageViewTracking()` attaches the listeners.

**The build is a single inlined file.** `vite-plugin-singlefile` inlines everything into one `index.html`, so `gtag.js` is the only external script the page loads. It is appended asynchronously and its failure is caught — analytics cannot delay or break rendering.

**React StrictMode is on.** In development it double-invokes effects. The pageview dedupe lives at *module* scope, not in component state, so a remounted component cannot resend a view. This is covered by test section 2.

---

## 1. Netlify Web Analytics

Server-side, cookieless, nothing to install. It counts requests at the edge, so ad-blockers and script blockers do not affect it — which is exactly why it is the trustworthy number for *reach*.

**Enable it:** Netlify → your SeRuh project → **Logs & Metrics → Analytics → Enable Analytics**. It is a paid add-on per site, and data starts from the moment you enable it — it does not backfill.

**View it:** the same place, once enabled.

| Metric | What it means | How to read it |
| --- | --- | --- |
| **Pageviews** | Every page request served | Total volume. Refreshes count. |
| **Unique visitors** | Distinct IP addresses, per day | **Not a headcount.** One office or campus behind one NAT is one visitor; one person on phone-then-laptop is two. Treat it as a trend line, not a census. |
| **Top pages** | Most-requested paths | On SeRuh this is nearly all `/` — the site is one page. Section-level detail comes from GA4's virtual pageviews instead. |
| **Top sources** | Referring domains | Where reach is actually coming from: search, social, direct, a link someone shared. |
| **Top locations** | Country, by IP | Useful for SeRuh specifically, given the Hindi/Urdu content on the wall. |
| **404s** | Requests with no page | Should be near zero. A spike means a broken shared link. |
| **Bandwidth** | Bytes served | Worth watching: the bundle is ~777 KB, so bandwidth tracks visitors closely. |

Do not rebuild any of this in the app. It is the one thing GA4 cannot do well, because GA4 only sees browsers that run its script.

---

## 2. Google Analytics 4

1. **Create the property** — [analytics.google.com](https://analytics.google.com) → Admin → Create → Property. Name it *SeRuh*, set the timezone and currency.
2. **Create a Web data stream** — Admin → Data streams → Add stream → Web. URL `https://seruh.netlify.app`, stream name *SeRuh Web*.
3. **Copy the Measurement ID** — the `G-XXXXXXXXXX` shown on the stream. It is not a secret; it ships in the page.
4. **Set it locally** — copy `.env.example` to `.env` and fill in:
   ```
   VITE_GA_MEASUREMENT_ID=G-XXXXXXXXXX
   ```
   > There is **no `.gitignore` at the repo root**, so a `.env` here is not ignored by default. Add one before creating the file, or keep the value only in Netlify.
5. **Set it in Netlify** — Project → **Site configuration → Environment variables → Add a variable**. Key `VITE_GA_MEASUREMENT_ID`, value `G-XXXXXXXXXX`, scoped to **Builds** (Vite inlines it at build time — a runtime-only variable will not reach the bundle).
6. **Redeploy.** Environment variables are read during the build, so an existing deploy will not pick it up. Trigger a fresh deploy.
7. **Verify** — GA4 → Admin → **DebugView** (with `VITE_GA_DEBUG=true`, or the GA Debugger extension), or **Reports → Realtime**. Navigate Home → Explore → Write → Home and confirm four `page_view` events with `page_path` `/home`, `/explore`, `/write`, `/home` — and no duplicates.

### If the ID is missing

`isAnalyticsEnabled` is false, `initAnalytics()` returns immediately, no script is injected, and every `track*` call is a no-op. Development logs one informational line and nothing else. The site behaves identically.

### Development vs production

Real sends happen when `import.meta.env.PROD` is true, **or** when `VITE_GA_DEBUG=true` is set deliberately. Localhost therefore stays out of production data unless you opt in.

---

## 3. Wiring it into the app

Initialise once at the app root, and mark admin sessions so GA4 can filter them:

```jsx
// App.jsx
import { useEffect } from 'react'
import { initAnalytics, startPageViewTracking, setInternalTraffic } from './services/analytics'

initAnalytics()                                  // module scope: runs once per page load

export default function App() {
  useEffect(() => startPageViewTracking(), [])   // returns its own cleanup
  // …
}
```

```jsx
// wherever admin status is already known (AuthContext / AdminApp)
useEffect(() => { setInternalTraffic(isAdmin) }, [isAdmin])
```

### Event call sites

**Fire success-shaped events only after the backend confirms.** The helper names say which is which — `trackFeelingSubmitted` and `trackFeelingPublished` belong *inside* the resolved branch, never next to the click.

```jsx
// correct
const res = await api.publishFeeling({ ...fields })
if (res?.ok) {
  trackFeelingSubmitted({ visibility, category, mood })
  trackFeelingPublished({ visibility, category, mood, decision: res.decision })
} else {
  trackFeelingRejected({ decision: res?.decision })
}

// correct — the like event reflects what the RPC returned, not the optimistic UI
const r = await api.toggleQuoteLike(quote.id)
r.liked ? trackQuoteLiked(quote) : trackQuoteUnliked(quote)
```

| Where | Call |
| --- | --- |
| App root | `initAnalytics()`, `startPageViewTracking()` |
| Auth / admin context | `setInternalTraffic(isAdmin)` |
| Quote card — like, after RPC | `trackQuoteLiked` / `trackQuoteUnliked` |
| Quote card — save, after RPC | `trackQuoteSaved` / `trackQuoteUnsaved` |
| Quote card — copy | `trackQuoteCopied` |
| Quote card / share modal | `trackQuoteShared(quote, method)`, `trackShareClicked(method)` |
| Share card canvas render | `trackShareCardGenerated(quote)` |
| Quote opened / detail view | `trackQuoteViewed(quote)` |
| Mood selector | `trackMoodSelected(mood)` |
| ✦ Surprise Me — click handler only | `trackSurpriseMe()` |
| Search — after results return | `trackSearch({ searchType, resultCount, query })` |
| Today's Feeling / Daily SeRuh | `trackDailySeRuhViewed(quote)` |
| Write Feeling — form opened | `trackFeelingStarted()` |
| Write Feeling — after RPC | `trackFeelingSubmitted` / `trackFeelingPublished` / `trackFeelingRejected` |
| Report modal — after RPC | `trackFeelingReported(reason)` |
| My Feelings — after delete | `trackFeelingDeleted()` |
| Find My Words — on submit | `trackAIGenerationStarted({ mood, style, length })` |
| Find My Words — after response | `trackAIGenerationCompleted` / `trackAIGenerationFailed` |
| Auth — after success | `trackLoggedIn()` / `trackSignedUp()` |

`trackSurpriseMe()` goes in the click handler, never in a render path or an effect keyed on the quote — otherwise a re-render counts as a click.

---

## 4. Event catalogue

| Event | Purpose | Parameters |
| --- | --- | --- |
| `page_view` | Page / section visit | `page_path`, `page_title`, `page_group` |
| `search_performed` | Search used | `search_type`, `result_count`, `query_length` |
| `mood_selected` | Mood chosen | `mood` |
| `surprise_me_clicked` | Surprise Me used | — |
| `daily_seruh_viewed` | Daily SeRuh seen | `quote_id`, `category`, `mood` |
| `quote_viewed` | Quote opened | `quote_id`, `category`, `mood` |
| `quote_liked` / `quote_unliked` | Like toggled | `quote_id`, `category`, `mood` |
| `quote_saved` / `quote_unsaved` | Save toggled | `quote_id`, `category`, `mood` |
| `quote_shared` | Quote shared | + `share_method` |
| `quote_copied` | Quote copied | `quote_id`, `category`, `mood` |
| `feeling_started` | Write form opened | — |
| `feeling_submitted` | Submission accepted | `visibility`, `category`, `mood` |
| `feeling_published` | Published to the wall | + `decision` |
| `feeling_rejected` | Blocked by moderation | `decision`, `reason` |
| `feeling_reported` | Content reported | `reason` |
| `feeling_deleted` | Author deleted their own | — |
| `ai_generation_started` | Generation requested | `mood`, `style`, `length` |
| `ai_generation_completed` | Generation returned | `mood`, `style`, `length` |
| `ai_generation_failed` | Generation failed | `error_kind` |
| `share_card_generated` | Share image rendered | `quote_id`, `category`, `mood` |
| `share_clicked` | Share initiated | `share_method` |
| `login_completed` / `sign_up_completed` | Auth succeeded | — |

`share_method` is one of `native_share`, `whatsapp`, `facebook`, `copy_link`, `other`.

### Reading reach and growth from these

- **Reach** — Netlify pageviews and unique visitors; GA4 Users, New vs Returning, Traffic acquisition, Countries.
- **Engagement** — `quote_viewed` vs `quote_liked` / `quote_saved` / `quote_shared` / `quote_copied`; `search_performed`; `mood_selected`; `surprise_me_clicked`.
- **Community** — `feeling_started` → `feeling_submitted` → `feeling_published` as a funnel; `feeling_reported` as a health signal.
- **AI adoption** — `ai_generation_started` → `completed`, with `failed` as the reliability line.
- **Growth channels** — GA4 Traffic acquisition splits direct, organic search, referral and social.

---

## 5. Privacy contract

Parameters pass through an **allowlist** in `analytics.js`. Anything not on it is dropped before the payload is built, so a mistaken caller cannot leak. Values are scalars only, clamped to 60 characters — an object or array would be a route for nested text.

**Never sent, by construction:** feeling or quote text · raw search queries · names · emails · phone numbers · passwords · auth tokens · `user_id` · `visitor_id` · private feelings · anonymous authors' identities.

Reinforcing choices:

- `send_page_view: false` — pageviews are ours, so gtag cannot add an unexpected one.
- `anonymize_ip: true`; `allow_google_signals` and `allow_ad_personalization_signals` both off — no advertising or cross-device identity graph.
- **No `user_id` and no user properties.** A logged-in person is not identified to GA4. `login_completed` is a count.
- A private feeling contributes `visibility: 'PRIVATE'` and nothing more. An anonymous one is indistinguishable from any other in the payload.
- Search sends a **length bucket** (`0`, `1-10`, `11-25`, `26-60`, `60+`) plus `result_count`. The decision is deliberate: on a platform where people search things like *"why do I feel this way"*, the query is emotional content. If a raw-query need ever arises, it needs its own decision and a note here — the default is no.

This matches what the existing first-party tracker already does: its `search` event stores only `{ len }`.

### Keeping admin traffic out of public metrics

`setInternalTraffic(true)` sets GA4's `traffic_type: 'internal'` parameter, and every event from that session carries it. Complete the pair in GA4, which is where the actual exclusion happens:

1. Admin → Data streams → *SeRuh Web* → **Configure tag settings → Define internal traffic** → add a rule matching `traffic_type` = `internal`.
2. Admin → **Data filters** → Internal Traffic → set to **Active** (it ships as *Testing*, which marks but does not exclude).

`page_group` also separates `admin` / `my_seruh` / `public`, so admin activity can be segmented out in reports even before the filter is active.

This is a reporting hint, not a security control — a browser can always choose what to send. Access control stays where it is: `am_i_admin()` inside the database, on all twelve `admin_*` functions.

---

## 6. Testing

```bash
node src/services/analytics.test.mjs
```

No runner and no dependencies. It stubs `window`/`document`, captures what would reach gtag's `dataLayer`, and asserts on the payloads — hash mapping, pageview dedupe under StrictMode, the navigation sequence, back/forward, `page_group`, the privacy allowlist, search bucketing, AI metadata, feeling event ordering, internal-traffic marking, malformed event names, and the unconfigured build.

The privacy sections are the ones that matter: **if someone adds a parameter carrying a person's words, section 6 fails.** Keep it in the pre-deploy path.

Browser-level verification — DebugView, the network panel, mobile share and copy — has to be done by hand against a deploy. See *Known limitations*.

---

## 7. Known limitations

- **Nothing is wired up yet.** `analytics.js` is complete and tested, but no component calls it, because the Phase 4 application source is not in this repository — only the built `index.html`. Section 3 is the map to apply once the source is committed. Before wiring anything into a candidate tree, check it is the right generation:

  ```bash
  node scripts/verify-source-generation.mjs src index.html
  ```

  It compares the Supabase RPC surface and generation markers between the tree and the deployed build, and exits non-zero if they disagree. `seruh-source.zip` fails it — that tree calls `submit_feeling` and is missing twelve RPCs the live build uses, including `publish_feeling`, `report_feeling` and the whole moderation admin. Building from it would roll production back past the DEFECT 2 fix.
- **Netlify Analytics cannot be enabled from code.** It is a dashboard toggle and a paid add-on, and it does not backfill.
- **Netlify unique visitors are IP-based** and are not a count of people.
- **GA4 undercounts.** Ad-blockers and privacy browsers block `gtag.js`; Netlify's edge counting does not miss those visits. Expect GA4 Users to sit below Netlify unique visitors, and do not treat the gap as a bug.
- **No browser, mobile or DebugView verification has been performed.** Those checks need a deploy carrying the wiring.
- **Config mechanisms differ.** Supabase values are injected by build-time placeholder substitution (`__SUPABASE_URL__` in `src/lib/config.js`); GA4 uses `import.meta.env`, as specified. Worth unifying later.
- **No custom analytics dashboard.** Deliberately out of scope. If a *SeRuh Growth Dashboard* is wanted later, it must read the GA4 Data API from a server-side function — GA4 API credentials must never reach the client.
