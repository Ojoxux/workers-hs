# Releasing

A release is a git tag, `vX.Y.Z`. Projects pin it where they import the Haskell
packages:

```cabal
import: https://raw.githubusercontent.com/Ojoxux/workers-wai/vX.Y.Z/workers-wai.project
```

and where they install the JavaScript runtime, from the same tag (pnpm can
install a subdirectory of a git repository; the package is not on npm):

```json
"workers-wai": "github:Ojoxux/workers-wai#vX.Y.Z&path:/runtime"
```

`workers-wai.project` fetches the libraries, shims and patched packages with
`source-repository-package` at the same tag, so the file pins itself: the
tagged commit's `workers-wai.project` must name that tag.

## Steps

1. Pick the version. Until 1.0, a change that breaks a project bumps the minor
   version.
2. On a branch, set `tag: vX.Y.Z` in `workers-wai.project` and the version in
   the import line at its top, and `"version": "X.Y.Z"` in
   `runtime/package.json`.
3. Check that the file still matches `cabal.project`, pins the new tag, and
   that the npm version matches:

   ```sh
   node scripts/check-project.mjs vX.Y.Z
   ```

4. Merge, then tag the merge commit on `main` and push the tag:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

Between releases, `main`'s `workers-wai.project` still names the last tag, so
importing it from `main` builds the last release, not `main`.

## Keeping workers-wai.project in step

`cabal.project` builds this repository from local packages;
`workers-wai.project` gives other projects the same packages from GitHub. A
package, constraint or flag added to one must be added to the other.
`node scripts/check-project.mjs` compares them: the packages (less the demos
and tests), the constraints and the flags.
