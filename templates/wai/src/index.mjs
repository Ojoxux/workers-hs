// The Worker's entry point. ./build.sh writes the two generated files.
import wasmModule from "../generated/app.wasm";
import jsffi from "../generated/ghc_wasm_jsffi.js";
import { makeWorker } from "workers-hs";

export default makeWorker(wasmModule, jsffi);
