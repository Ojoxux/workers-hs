#!/usr/bin/env bash
# Generate a project from the template, point it at this checkout instead of
# the release it names, build it, serve it with wrangler dev and fetch /.
#
#   scripts/try-template.sh [dir]   # default: a new temp directory
#
# Needs nix with flakes. Builds this checkout's committed HEAD: the Haskell
# packages are fetched from it with git.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-$(mktemp -d)}"
REV="$(git -C "$ROOT" rev-parse HEAD)"

echo "==> template in $DIR (workers-hs $REV)"
mkdir -p "$DIR"
cd "$DIR"
nix flake init -t "path:$ROOT"

# The template names @VERSION@, which a release fills in: use this checkout
# instead for the flake input, the cabal packages and the runtime.
sed "s|location: https://github.com/Ojoxux/workers-hs|location: $ROOT|; s|  tag: @VERSION@|  tag: $REV|" \
  "$ROOT/workers-hs.project" > workers-hs.project
sed -i.bak "s|github:Ojoxux/workers-hs/@VERSION@|path:$ROOT|" flake.nix
sed -i.bak "s|^import: https://.*|import: ./workers-hs.project|" cabal.project
sed -i.bak "s|\"workers-hs\": \"[^\"]*\"|\"workers-hs\": \"file:$ROOT/runtime\"|" package.json
rm -f ./*.bak
DEV=(nix develop --command)

"${DEV[@]}" pnpm install
"${DEV[@]}" pnpm run build

PORT="${PORT:-8790}"
"${DEV[@]}" pnpm exec wrangler dev --port "$PORT" > wrangler.log 2>&1 &
WRANGLER=$!
trap 'kill $WRANGLER 2>/dev/null || true; pkill -P $WRANGLER 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if BODY="$(curl -sf "http://127.0.0.1:$PORT/")"; then
    echo "==> GET / -> $BODY"
    exit 0
  fi
  sleep 1
done
echo "==> no answer on / after 120s; wrangler log:"
cat wrangler.log
exit 1
