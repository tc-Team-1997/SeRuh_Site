#!/usr/bin/env bash
# Assemble the publish directory.
#
# Without this, Netlify serves the repository root, which means every
# migration, test and document in it is downloadable from the live
# site. That is how seruh-setup.sql came to be readable at
# seruh.netlify.app/seruh-setup.sql — and the newer migrations carry
# moderate_text in full, so publishing them hands anyone the exact
# patterns and thresholds to write underneath.
#
# Only what the browser needs is copied. Edge functions are read by
# Netlify from netlify/edge-functions in the repo, not from here.
set -euo pipefail

OUT="${1:-_site}"
rm -rf "$OUT"
mkdir -p "$OUT/next"

# the deployed application, unchanged
cp index.html "$OUT/"

# crawler files
cp robots.txt sitemap.xml "$OUT/"

# deep-link rewrites
cp _redirects "$OUT/"

# the new front end — page and its one module, no tests
cp next/index.html next/analytics.js "$OUT/next/"

# the comments widget, bolted onto the existing site at its root path
cp next/seruh-comments.js "$OUT/seruh-comments.js"

echo "published $(find "$OUT" -type f | wc -l | tr -d ' ') files:"
find "$OUT" -type f | sort | sed 's|^|  |'
