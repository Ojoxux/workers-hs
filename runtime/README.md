# workers-wai

The JavaScript half of [workers-wai](https://github.com/Ojoxux/workers-wai):
it boots a Haskell module compiled with GHC's wasm backend on Cloudflare
Workers and forwards every request to it.

```js
import wasmModule from "./generated/app.wasm";
import jsffi from "./generated/ghc_wasm_jsffi.js";
import { makeWorker } from "workers-wai";

export default makeWorker(wasmModule, jsffi);
```

`app.wasm` is the linked Haskell executable; `ghc_wasm_jsffi.js` is generated
from it by GHC's `post-link.mjs`. Options: `envAsEnviron` (default `true`)
copies the env's string entries into the WASI environment, so
`System.Environment.lookupEnv` sees vars and Secrets; `exposeErrors` (default
`false`) puts exception details in 500 response bodies, for development.

The Haskell side, the project templates and the documentation are in the
[repository](https://github.com/Ojoxux/workers-wai). BSD-3-Clause.
