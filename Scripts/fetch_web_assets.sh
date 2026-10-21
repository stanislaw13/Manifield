#!/bin/bash
# Downloads the pinned web assets bundled into Manifield (KaTeX, marked, DOMPurify, d3-force).
# Re-run to refresh; bump the versions below deliberately.
set -euo pipefail

KATEX_VERSION="0.17.0"
MARKED_VERSION="18.0.5"
DOMPURIFY_VERSION="3.2.7"
# d3-force and its three runtime dependencies, as minified UMD builds (all ISC).
D3_FORCE_VERSION="3.0.0"
D3_DISPATCH_VERSION="3.0.1"
D3_QUADTREE_VERSION="3.0.1"
D3_TIMER_VERSION="3.0.1"

# The npm packages this script owns. Used twice below — to scope the rebuild, and to copy each
# package's upstream LICENSE — so the two can never drift apart.
WEB_PKGS=(katex marked dompurify d3-force d3-dispatch d3-quadtree d3-timer)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Manifield/Resources/web/vendor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # name version
  curl -fsSL "https://registry.npmjs.org/$1/-/$1-$2.tgz" -o "$TMP/$1.tgz"
  mkdir -p "$TMP/$1"
  tar -xzf "$TMP/$1.tgz" -C "$TMP/$1" --strip-components=1
}

echo "Fetching katex $KATEX_VERSION, marked $MARKED_VERSION, dompurify $DOMPURIFY_VERSION, d3-force $D3_FORCE_VERSION ..."
fetch katex "$KATEX_VERSION"
fetch marked "$MARKED_VERSION"
fetch dompurify "$DOMPURIFY_VERSION"
fetch d3-force "$D3_FORCE_VERSION"
fetch d3-dispatch "$D3_DISPATCH_VERSION"
fetch d3-quadtree "$D3_QUADTREE_VERSION"
fetch d3-timer "$D3_TIMER_VERSION"

# Rebuild only what this script owns. `licenses/` also holds three files that are NOT fetched
# here and must survive a re-run: sparkle-LICENSE.txt and swiftmath-LICENSE.txt (both arrive as
# SwiftPM dependencies, and neither ships a licence of its own inside the built product) and
# OFL-1.1.txt (the SIL Open Font License, for the 12 maths fonts in SwiftMath's resource bundle).
# The whole directory is copied into the .app, and MIT/ISC/OFL all require the notice to travel
# with the copy — so a blanket `rm -rf "$VENDOR"` here would silently drop three licences the
# build is legally obliged to ship.
rm -rf "$VENDOR/katex"
rm -f "$VENDOR/marked.min.js" "$VENDOR/purify.min.js" \
      "$VENDOR/d3-force.min.js" "$VENDOR/d3-dispatch.min.js" \
      "$VENDOR/d3-quadtree.min.js" "$VENDOR/d3-timer.min.js"
for pkg in "${WEB_PKGS[@]}"; do
  rm -f "$VENDOR/licenses/$pkg-LICENSE.txt"
done
mkdir -p "$VENDOR/katex/contrib" "$VENDOR/katex/fonts" "$VENDOR/licenses"
cp "$TMP/katex/dist/katex.min.css" "$VENDOR/katex/"
cp "$TMP/katex/dist/katex.min.js" "$VENDOR/katex/"
cp "$TMP/katex/dist/contrib/auto-render.min.js" "$VENDOR/katex/contrib/"
cp "$TMP/katex/dist/fonts/"*.woff2 "$VENDOR/katex/fonts/"
cp "$TMP/marked/lib/marked.umd.js" "$VENDOR/marked.min.js"
cp "$TMP/dompurify/dist/purify.min.js" "$VENDOR/purify.min.js"
cp "$TMP/d3-force/dist/d3-force.min.js" "$VENDOR/"
cp "$TMP/d3-dispatch/dist/d3-dispatch.min.js" "$VENDOR/"
cp "$TMP/d3-quadtree/dist/d3-quadtree.min.js" "$VENDOR/"
cp "$TMP/d3-timer/dist/d3-timer.min.js" "$VENDOR/"

# Attribution ships with the code: MIT/Apache-2.0/MPL-2.0 all require the license
# text to travel with redistributed copies, and Resources/web is copied wholesale
# into the .app bundle. Missing upstream LICENSE is a hard error, not a warning.
for pkg in "${WEB_PKGS[@]}"; do
  if [ ! -f "$TMP/$pkg/LICENSE" ]; then
    echo "error: $pkg tarball has no LICENSE file — attribution would be lost" >&2
    exit 1
  fi
  cp "$TMP/$pkg/LICENSE" "$VENDOR/licenses/$pkg-LICENSE.txt"
done

# The three licences this script does not fetch. Absent means either a re-run deleted them (it
# should no longer be able to) or someone removed them by hand; either way the next build ships
# without attribution it owes, so say so loudly rather than exiting 0 on a quiet regression.
for extra in sparkle-LICENSE.txt swiftmath-LICENSE.txt OFL-1.1.txt; do
  if [ ! -f "$VENDOR/licenses/$extra" ]; then
    echo "warning: $VENDOR/licenses/$extra is missing — restore it before shipping a build" \
         "(canonical sources are in THIRD_PARTY_NOTICES.md)" >&2
  fi
done

echo "Done. Vendor assets in $VENDOR"
echo "Licenses refreshed in $VENDOR/licenses — if you bumped a version, update THIRD_PARTY_NOTICES.md too."
