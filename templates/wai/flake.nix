{
  description = "A WAI application on Cloudflare Workers";

  inputs = {
    workers-wai.url = "github:Ojoxux/workers-wai/v0.1.0";
    # The wasm toolchain workers-wai is built and tested with.
    ghc-wasm-meta.follows = "workers-wai/ghc-wasm-meta";
    nixpkgs.follows = "workers-wai/ghc-wasm-meta/nixpkgs";
    flake-utils.follows = "workers-wai/ghc-wasm-meta/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ghc-wasm-meta,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          # wasm32-wasi-ghc 9.12, wasm32-wasi-cabal and node; pnpm installs the
          # workers-wai runtime from git.
          packages = [
            ghc-wasm-meta.packages.${system}.all_9_12
            pkgs.pnpm
          ];
        };
      }
    );
}
