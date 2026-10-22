# workers-hs runtime

The JavaScript half of [workers-hs](https://github.com/Ojoxux/workers-hs):
it boots a Haskell module compiled with GHC's wasm backend on Cloudflare
Workers and forwards every request to it.

It is not published on npm. Install it from a release tag with pnpm, which can
take a subdirectory of a git repository:

```json
"dependencies": {
  "workers-hs": "github:Ojoxux/workers-hs#v0.1.0&path:/runtime"
}
```

```js
import wasmModule from "./generated/app.wasm";
import jsffi from "./generated/ghc_wasm_jsffi.js";
import { makeWorker } from "workers-hs";

export default makeWorker(wasmModule, jsffi);
```

`app.wasm` is the linked Haskell executable; `ghc_wasm_jsffi.js` is generated
from it by GHC's `post-link.mjs`. Options: `envAsEnviron` (default `true`)
copies the env's string entries into the WASI environment, so
`System.Environment.lookupEnv` sees vars and Secrets; `exposeErrors` (default
`false`) puts exception details in 500 response bodies, for development.

BSD-3-Clause.
