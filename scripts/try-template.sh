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

echo "==> template in $DIR (workers-wai $REV)"
mkdir -p "$DIR"
cd "$DIR"
nix flake init -t "path:$ROOT"

# The release the template names does not exist for this commit: use the
# checkout for the flake input, the cabal packages and the runtime.
sed "s|location: https://github.com/Ojoxux/workers-wai|location: $ROOT|; s|  tag: v[0-9.]*|  tag: $REV|" \
  "$ROOT/workers-wai.project" > workers-wai.project
sed -i.bak "s|^import: https://.*|import: ./workers-wai.project|" cabal.project
sed -i.bak "s|\"workers-wai\": \"[^\"]*\"|\"workers-wai\": \"file:$ROOT/runtime\"|" package.json
rm -f ./*.bak
DEV=(nix develop --override-input workers-wai "path:$ROOT" --command)

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
