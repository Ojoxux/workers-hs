# worker-app

A WAI application on Cloudflare Workers, built with
[workers-hs](https://github.com/Ojoxux/workers-hs).

```sh
nix develop         # wasm32-wasi-ghc, wasm32-wasi-cabal, node, pnpm
pnpm install
pnpm run build      # Haskell -> generated/app.wasm (the first build takes a while)
pnpm run dev        # http://localhost:8787
pnpm run deploy     # build, then wrangler deploy
```

- `app/Main.hs`: the application, an ordinary WAI `Application` passed to
  `runCloudflare`.
- `src/index.mjs`: the Worker entry, which boots the wasm module with
  `makeWorker` from the workers-hs runtime.
- The workers-hs release is named in three places: the `workers-hs` input in
  `flake.nix`, the `import:` in `cabal.project`, and `workers-hs` in
  `package.json` (installed from git, hence pnpm). Change all three to upgrade.

The workers-hs repository documents what WAI supports here, Yesod, and the
Workers bindings (`fetch`, D1, KV, R2, the Cache API).
