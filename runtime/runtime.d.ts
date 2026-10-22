export interface WorkerOptions {
  /** Copy the env's string entries into the WASI environment (default true). */
  envAsEnviron?: boolean;
  /** Put exception details in 500 response bodies, for development (default false). */
  exposeErrors?: boolean;
}

/**
 * A Worker's default export for a Haskell wasm module built against
 * cloudflare-workers: `wasmModule` is its `app.wasm`, `jsffi` the default
 * export of the `ghc_wasm_jsffi.js` that GHC's post-link.mjs generates for it.
 */
export function makeWorker(
  wasmModule: WebAssembly.Module,
  jsffi: (exports: WebAssembly.Exports) => WebAssembly.ModuleImports,
  options?: WorkerOptions,
): ExportedHandler;
