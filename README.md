# workers-wai

Run a WAI `Application` — and Yesod on top of it — on Cloudflare Workers.

Nothing here modifies Yesod or WAI: a WAI `Application` is a function, and a
Cloudflare Worker's `fetch` handler is also a function, so a small adapter
connects them. GHC's wasm backend compiles the Haskell side to WebAssembly.

This is an experiment and the base the author's own sites run on, shared
together with what it took: the packages that had to be replaced or patched
for wasm, the platform's limits, and measurements. It is not published on
Hackage or npm, and makes no compatibility promises beyond its release tags.

```
        normal deployment              this project

        Yesod                          Yesod
          |                              |
        WAI Application                WAI Application
          |                              |
        Warp                           Network.Wai.Handler.Cloudflare
          |                              |
        TCP / HTTP server              fetch(Request) -> Response
                                         |
                                       Cloudflare Workers runtime
```

The Haskell code is compiled to a wasm32-wasi reactor module. The Worker's
entry delegates to `makeWorker` from the runtime package `workers-wai`
(`runtime/`), which instantiates the module once per isolate and then calls it
for every fetch event.

## Trying it

Requires [Nix](https://nixos.org/) with flakes enabled; it provides GHC 9.12's
wasm backend, `wasm32-wasi-cabal`, Node and pnpm.

```sh
mkdir my-app && cd my-app
nix flake init -t github:Ojoxux/workers-wai
nix develop
pnpm install
pnpm run build       # the first build compiles the dependencies for wasm: slow
pnpm run dev         # http://localhost:8787
```

The template is a WAI application; [docs/yesod.md](docs/yesod.md) and
`haskell/demo-yesod` show Yesod.

## Using it from a project

Projects pin a release tag in two places:

- `cabal.project` imports [workers-wai.project](workers-wai.project), which
  brings the libraries, the packages patched for wasm and the constraints they
  need:

  ```cabal
  import: https://raw.githubusercontent.com/Ojoxux/workers-wai/v0.1.0/workers-wai.project
  ```

- `package.json` installs the runtime from git with pnpm, and the Worker's
  entry is `export default makeWorker(wasmModule, jsffi)`:

  ```json
  "workers-wai": "github:Ojoxux/workers-wai#v0.1.0&path:/runtime"
  ```

The executable is built with `-no-hs-main -optl-mexec-model=reactor` and
exports its `main` (`foreign export javascript "workerMain" main :: IO ()`);
`templates/wai` has the build script that turns it into the two files the
entry imports.

## What works

- WAI: requests, responses, streamed bodies both ways, the `ExecutionContext`
  ([docs/wai-support.md](docs/wai-support.md),
  [docs/streaming.md](docs/streaming.md)).
- Yesod: routing, Template Haskell, sessions in an encrypted cookie, static
  files through Workers Static Assets ([docs/yesod.md](docs/yesod.md)).
- Workers bindings in `cloudflare-workers`: `fetch`, D1, KV, R2, the Cache
  API, `waitUntil`, env and Secrets; persistent on D1; an `http-client`
  `Manager` over `fetch`.

Measured under `wrangler dev`:

| | `demo-wai` | `demo-yesod` |
|---|---|---|
| `app.wasm` | 2.3 MiB | 4.1 MiB |
| cold start, incl. instantiation + `main` | 37 ms | 27 ms |
| warm request | 3 ms | 2 ms |

The limit is 64 MiB uncompressed, so size is not a constraint. Getting Yesod to
*build* was the hard part — see [docs/shims.md](docs/shims.md).

## Layout

```
haskell/wai-handler-cloudflare   the handler: Network.Wai.Handler.Cloudflare
haskell/yesod-cloudflare         Yesod integrations: WebCrypto session backend, static files via Static Assets
haskell/cloudflare-workers       typed Workers bindings: Fetch, Env, D1, KV, R2, Cache, Context, runWorker
haskell/test-worker              a Worker that exercises cloudflare-workers, for the tests
haskell/persistent-d1            a persistent backend for D1: Database.Persist.D1
haskell/test-yesod               a Yesod app that exercises sessions, static files, persistent-d1 and streaming, for the tests
haskell/demo-wai                 a bare WAI Application
haskell/demo-yesod               a minimal Yesod application
haskell/http-client-cloudflare   http-client Manager over fetch
haskell/test-vendor              checks the vendored crypto stack against published vectors
haskell/vendor/                  Hackage packages patched to build for wasm (crypton, memory, ...)
haskell/shims/                   stand-ins for packages with no wasm build (network, entropy)
runtime/                         the JS runtime package workers-wai: makeWorker and the WASI shim
worker/                          the demo Worker (wrangler.toml and its entry point)
scripts/                         build, test, inspect and wrangler-check helpers
```

## Developing workers-wai

Building this repository's demos and tests also takes Nix with flakes. The dev
shell provides `wasm32-wasi-ghc` 9.12, `wasm32-wasi-cabal`, `wasi-sdk`, Node,
and `wasm-opt`.

```sh
nix develop
wasm32-wasi-cabal update        # first time only

scripts/build.sh demo-wai       # Stage 1
scripts/build.sh demo-yesod     # Stage 2
```

`scripts/build.sh` compiles the executable as a wasm reactor module, copies it to
`worker/generated/app.wasm`, and runs GHC's `post-link.mjs` to emit
`worker/generated/ghc_wasm_jsffi.js`. Both demos deploy through the same
unchanged `worker/`; switching between them is just a rebuild.

GHC **9.12** is pinned deliberately: it is the first release whose wasm backend
supports Template Haskell, without which `mkYesod`, `parseRoutes` and `whamlet`
cannot run.

### Running the demos

```sh
cd worker
npm install
npm run dev          # wrangler dev, serves on http://localhost:8787
```

```console
$ curl http://localhost:8787/
Hello from WAI on Cloudflare Workers

$ curl 'http://localhost:8787/echo?x=1&y=2' -H 'X-Demo: yes'
requestMethod: GET
rawPathInfo: /echo
pathInfo: ["echo"]
rawQueryString: ?x=1&y=2
queryString: [("x",Just "1"),("y",Just "2")]
...
```

To deploy:

```sh
cd worker
npm run deploy       # wrangler deploy
```

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How the Worker, the WASI shim and the Haskell handler fit together, and how a request crosses the FFI boundary |
| [docs/wai-support.md](docs/wai-support.md) | Which parts of WAI this handler implements, and which it does not |
| [docs/shims.md](docs/shims.md) | The replaced packages, why the real ones cannot be built, how faithful each replacement is, and how patched packages differ |
| [docs/constraints.md](docs/constraints.md) | Platform limits and the traps found along the way |
| [docs/d1.md](docs/d1.md) | The D1 bindings: configuration, API, how values map, batches and errors |
| [docs/kv.md](docs/kv.md) | The KV bindings: usage, options, listing, consistency, limits and errors |
| [docs/r2.md](docs/r2.md) | The R2 bindings: usage, ranges and conditions, streams of known length, listing, limits and errors |
| [docs/cache.md](docs/cache.md) | The Cache API bindings: usage, what gets stored, errors and limits |
| [docs/streaming.md](docs/streaming.md) | Streamed response and request bodies: `bodyStream`, `bodyReader`, WAI and Yesod, errors |
| [docs/persistent-d1.md](docs/persistent-d1.md) | persistent on D1: usage, no transactions, the parameter limit, values and migrations |
| [docs/yesod.md](docs/yesod.md) | The steps from a working WAI handler to a running Yesod application |
| [docs/development.md](docs/development.md) | Inspecting the wasm module and the fast test loop |
| [docs/releasing.md](docs/releasing.md) | Cutting a release: the tag, workers-wai.project, and keeping it in step with cabal.project |

## License

BSD-3-Clause; see [LICENSE](LICENSE). The patched packages under
`haskell/vendor/` keep their own licenses, in each package's directory.
