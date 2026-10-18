# Releasing

A release is a git tag, `vX.Y.Z`. Projects pin it in one place, the URL they
import:

```cabal
import: https://raw.githubusercontent.com/Ojoxux/workers-wai/vX.Y.Z/workers-wai.project
```

`workers-wai.project` fetches the libraries, shims and patched packages with
`source-repository-package` at the same tag, so the file pins itself: the
tagged commit's `workers-wai.project` must name that tag.

## Steps

1. Pick the version. Until 1.0, a change that breaks a project bumps the minor
   version.
2. On a branch, set `tag: vX.Y.Z` in `workers-wai.project` and the version in
   the import line at its top.
3. Check that the file still matches `cabal.project` and pins the new tag:

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
