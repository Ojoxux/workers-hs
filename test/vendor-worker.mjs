// test-vendor under wrangler dev. Build with scripts/test.sh first.
import wasmModule from "../.test-build/test-vendor/app.wasm";
import jsffi from "../.test-build/test-vendor/ghc_wasm_jsffi.js";
import { makeWorker } from "../runtime/runtime.mjs";

export default makeWorker(wasmModule, jsffi, { exposeErrors: true });
