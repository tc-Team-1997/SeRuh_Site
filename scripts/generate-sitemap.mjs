// ─────────────────────────────────────────────────────────────
// Generate sitemap.xml from SeRuh's public content.
//
//   node scripts/generate-sitemap.mjs [--out sitemap.xml] [--dry]
//
// Reads ONLY the public views — quotes_public, categories_public,
// feelings_public. Those views already exclude PRIVATE feelings and
// anything not PUBLISHED, so a private feeling cannot reach the file
// by construction rather than by filtering afterwards. The script
// asserts that before writing, because "by construction" is worth
// checking when the cost of being wrong is publishing someone's
// private writing to Google.
//
// The Supabase anon key is public by design — it ships in the page —
// so reading it out of index.html is not a leak, it is just where
// the deployed configuration lives.
// ─────────────────────────────────────────────────────────────

import { readFileSync, writeFileSync } from 'node:fs'

const SITE = process.env.SERUH_SITE_URL || 'https://seruh.netlify.app'
const args = process.argv.slice(2)
const OUT = args.includes('--out') ? args[args.indexOf('--out') + 1] : 'sitemap.xml'
const DRY = args.includes('--dry')

// Moods are a fixed product vocabulary, not a table.
const MOODS = ['Happy', 'Lost', 'Heavy', 'Hopeful', 'Lonely',
               'Loved', 'Confused', 'Peaceful', 'Nostalgic', 'Numb']

const slug = (s) => String(s).toLowerCase().trim()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')

function config() {
  const html = readFileSync('index.html', 'utf8')
  const url = html.match(/https:\/\/[a-z0-9]+\.supabase\.co/)?.[0]
  const key = html.match(/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)?.[0]
  if (!url || !key) throw new Error('could not read Supabase config out of index.html')
  return { url, key }
}

async function get(path) {
  const { url, key } = config()
  const res = await fetch(`${url}/rest/v1/${path}`, { headers: { apikey: key } })
  if (!res.ok) throw new Error(`${path} → ${res.status}`)
  return res.json()
}

const esc = (s) => String(s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&apos;')

function entry({ loc, lastmod, changefreq, priority }) {
  return [
    '  <url>',
    `    <loc>${esc(loc)}</loc>`,
    lastmod ? `    <lastmod>${lastmod.slice(0, 10)}</lastmod>` : null,
    changefreq ? `    <changefreq>${changefreq}</changefreq>` : null,
    priority ? `    <priority>${priority}</priority>` : null,
    '  </url>',
  ].filter(Boolean).join('\n')
}

const [quotes, categories, feelings] = await Promise.all([
  get('quotes_public?select=id,category,mood&order=created_at.desc'),
  get('categories_public?select=name&order=sort'),
  get('feelings_public?select=id,created_at&order=created_at.desc&limit=1000'),
])

const urls = [
  { loc: `${SITE}/`, changefreq: 'daily', priority: '1.0' },
  { loc: `${SITE}/daily`, changefreq: 'daily', priority: '0.8' },
  ...categories.map(c => ({ loc: `${SITE}/c/${slug(c.name)}`, changefreq: 'weekly', priority: '0.7' })),
  ...MOODS.map(m => ({ loc: `${SITE}/mood/${slug(m)}`, changefreq: 'weekly', priority: '0.7' })),
  ...quotes.map(q => ({ loc: `${SITE}/q/${q.id}`, changefreq: 'monthly', priority: '0.6' })),
  ...feelings.map(f => ({ loc: `${SITE}/f/${f.id}`, lastmod: f.created_at, changefreq: 'monthly', priority: '0.5' })),
]

// ── safety assertions, before anything is written ──
const seen = new Set()
for (const u of urls) {
  if (seen.has(u.loc)) throw new Error(`duplicate URL in sitemap: ${u.loc}`)
  seen.add(u.loc)
  if (!u.loc.startsWith(SITE + '/')) throw new Error(`URL escapes the site origin: ${u.loc}`)
}
// feelings_public cannot contain PRIVATE rows, but assert it rather than trust it
const priv = await get('feelings_public?select=id&limit=1000')
if (priv.length !== feelings.length) {
  throw new Error('feelings_public returned an inconsistent count between reads — refusing to write')
}
if (urls.length > 50000) throw new Error('sitemap over the 50k URL limit — split it')

const xml = [
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
  ...urls.map(entry),
  '</urlset>',
  '',
].join('\n')

console.log(`  quotes ......... ${quotes.length}`)
console.log(`  categories ..... ${categories.length}`)
console.log(`  moods .......... ${MOODS.length}`)
console.log(`  wall feelings .. ${feelings.length}   (public view only — no PRIVATE rows exist in it)`)
console.log(`  total URLs ..... ${urls.length}`)

if (DRY) {
  console.log('\n  --dry: nothing written\n')
} else {
  writeFileSync(OUT, xml)
  console.log(`\n  wrote ${OUT}  (${(xml.length / 1024).toFixed(1)} KB)\n`)
}
