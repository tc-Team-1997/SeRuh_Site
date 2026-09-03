// ─────────────────────────────────────────────────────────────
// Does this source tree actually correspond to the deployed build?
//
//   node scripts/verify-source-generation.mjs [srcDir] [buildFile]
//   defaults: ./src  ./index.html
//
// Why this exists: seruh-source.zip looks like the source and is not
// — it is the Phase 3 generation, one release behind the deployed
// index.html. Wiring anything into the wrong generation and building
// it would roll production back. This compares the Supabase RPC
// surface and a few UI markers between the two and refuses to agree
// they match unless they do.
//
// It is a generation check, not a proof of identity. Passing means
// "this tree speaks to the same backend as the deployed build";
// it does not mean the bundle would come out byte-identical.
// ─────────────────────────────────────────────────────────────

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, extname } from 'node:path'

const srcDir = process.argv[2] || 'src'
const buildFile = process.argv[3] || 'index.html'

if (!existsSync(srcDir) || !existsSync(buildFile)) {
  console.error(`missing input — srcDir=${srcDir} exists=${existsSync(srcDir)}, buildFile=${buildFile} exists=${existsSync(buildFile)}`)
  process.exit(2)
}

const CODE = new Set(['.js', '.jsx', '.ts', '.tsx'])

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.')) continue
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (CODE.has(extname(name))) out.push(p)
  }
  return out
}

const files = walk(srcDir)
const source = files.map(f => readFileSync(f, 'utf8')).join('\n')
const build = readFileSync(buildFile, 'utf8')

// rpc(`name`) in the minified build, rpc('name') in source
const rpcsIn = (s) => new Set([...s.matchAll(/rpc\(\s*[`'"]([a-z_0-9]+)[`'"]/g)].map(m => m[1]))
const fnsIn = (s) => new Set([...s.matchAll(/functions\.invoke\(\s*[`'"]([a-z-]+)[`'"]/g)].map(m => m[1]))

const buildRpcs = rpcsIn(build)
const srcRpcs = rpcsIn(source)

const missing = [...buildRpcs].filter(r => !srcRpcs.has(r)).sort()
const extra = [...srcRpcs].filter(r => !buildRpcs.has(r)).sort()

// markers that separate the generations
const PHASE4_ONLY = ['publish_feeling', 'report_feeling', 'set_feeling_visibility', 'delete_my_feeling', 'admin_flagged_feelings']
const SUPERSEDED = ['submit_feeling']

const pad = (s, n) => String(s).padEnd(n)
console.log(`\n  source tree ....... ${srcDir}  (${files.length} code files)`)
console.log(`  deployed build .... ${buildFile}  (${(build.length / 1024).toFixed(0)} KB)`)
console.log(`  RPCs in build ..... ${buildRpcs.size}`)
console.log(`  RPCs in source .... ${srcRpcs.size}`)
console.log(`  edge functions .... build=${[...fnsIn(build)].join(',') || '—'}  source=${[...fnsIn(source)].join(',') || '—'}\n`)

let fatal = 0

console.log('  generation markers')
for (const m of PHASE4_ONLY) {
  const inB = build.includes(m), inS = source.includes(m)
  const verdict = inB === inS ? 'ok' : (inB && !inS ? '*** MISSING FROM SOURCE ***' : 'source-only')
  if (inB && !inS) fatal++
  console.log(`    ${pad(m, 26)} build=${inB ? 'yes' : 'no '}  source=${inS ? 'yes' : 'no '}  ${verdict}`)
}
for (const m of SUPERSEDED) {
  const inB = build.includes(m), inS = source.includes(m)
  if (!inB && inS) {
    console.log(`    ${pad(m, 26)} build=no   source=yes  *** SOURCE IS AN OLDER GENERATION ***`)
    fatal++
  }
}

if (missing.length) {
  console.log(`\n  RPCs the build calls but the source does not (${missing.length}):`)
  for (const r of missing) console.log(`    - ${r}`)
  fatal++
}
if (extra.length) {
  console.log(`\n  RPCs the source calls but the build does not (${extra.length}) — source may be NEWER than the deploy:`)
  for (const r of extra) console.log(`    + ${r}`)
}

if (fatal) {
  console.log(`\n  RESULT: MISMATCH — this tree is not the source of ${buildFile}.`)
  console.log('  Do not wire changes into it or build from it; deploying would regress the live site.\n')
  process.exit(1)
}

console.log(`\n  RESULT: MATCH — same backend surface as the deployed build.`)
console.log('  Safe to wire analytics into this tree.\n')
