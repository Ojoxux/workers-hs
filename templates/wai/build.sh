#!/usr/bin/env bash
# Build the Haskell app to wasm and generate its JavaScript glue into generated/.
# Run inside `nix develop`.
set -euo pipefail
cd "$(dirname "$0")"

# A fresh machine has no package index yet.
[ -d "${CABAL_DIR:-$HOME/.ghc-wasm/.cabal}/packages/hackage.haskell.org" ] || wasm32-wasi-cabal update

wasm32-wasi-cabal build exe:worker-app
mkdir -p generated
# tail: on a first build, list-bin also prints git's output from fetching workers-hs.
cp "$(wasm32-wasi-cabal list-bin exe:worker-app | tail -n 1)" generated/app.wasm
"$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" \
  -i generated/app.wasm -o generated/ghc_wasm_jsffi.js
