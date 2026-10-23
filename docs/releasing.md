# Releasing

Releases are automatic. Every push to `main` (a merged pull request) runs the
Release workflow (`.github/workflows/release.yml`), which:

1. picks the next version from the commits since the last release
   (`scripts/next-version.mjs`), or stops when there is nothing to release;
2. makes a commit **off `main`** that fills the version in
   (`scripts/fill-version.mjs`) and tags it `vX.Y.Z`;
3. creates a GitHub Release for the tag, with notes generated from the merged
   pull requests.

Nothing on `main` names a version, and no commit bumps one.

## The version

Commit subjects follow Conventional Commits, and decide the next version:

| Commits since the last release | Next version |
|---|---|
| a breaking change: `type!:` (`feat!:`, `fix(wai)!:`, ...) or a `BREAKING CHANGE:` footer | the major version; the minor one before 1.0 (`v0.1.4` → `v0.2.0`) |
| `feat:`, `fix:` or `perf:` | the patch version (`v0.1.4` → `v0.1.5`) |
| only `docs:`, `chore:`, `test:`, `ci:`, `refactor:`, ... | no release |

With no tag yet, the first release is `v0.1.0`. Merge commits are ignored;
the commits they bring in count.

```sh
node scripts/next-version.mjs     # what merging main as it is would release
```

## Why the tag is off main

A project pins a release in three places: the `import:` of `workers-hs.project`
in its `cabal.project`, the runtime in `package.json`, and, when made from the
template, the `workers-hs` flake input. `workers-hs.project` fetches the
packages from the same tag, so the file has to name the tag it is in.

On `main` those places hold `@VERSION@` (and `runtime/package.json` has version
`0.0.0`, as npm accepts no placeholder). The release commit replaces them with
the version, and the tag points at that commit, so at a tag everything is
consistent:

- `import: https://raw.githubusercontent.com/Ojoxux/workers-hs/vX.Y.Z/workers-hs.project`
- `"workers-hs": "github:Ojoxux/workers-hs#vX.Y.Z&path:/runtime"`
- `nix flake init -t github:Ojoxux/workers-hs/vX.Y.Z`

The release commit is never merged back. The next release starts from the
parent of the last tag, which is where `main` was.

## Keeping workers-hs.project in step

`cabal.project` builds this repository from local packages;
`workers-hs.project` gives other projects the same packages from GitHub. A
package, constraint or flag added to one must be added to the other.
`node scripts/check-project.mjs` compares them (the packages less the demos
and tests, the constraints, the flags) and checks that the versions are still
placeholders.

Before a release that touches the template or the packages, run the Template
workflow by hand: it builds the template against the current commit.
