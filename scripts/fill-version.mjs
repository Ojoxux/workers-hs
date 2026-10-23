// Fill in the release version where a project names it: main keeps the
// placeholder, and the release workflow commits the filled-in files on a
// commit of their own, off main, which the tag points at.
//
//   node scripts/fill-version.mjs vX.Y.Z

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tag = process.argv[2];
if (!/^v\d+\.\d+\.\d+$/.test(tag ?? "")) {
  console.error("usage: node scripts/fill-version.mjs vX.Y.Z");
  process.exit(1);
}

const placeholder = "@VERSION@";
const files = [
  "workers-hs.project",
  "templates/wai/cabal.project",
  "templates/wai/flake.nix",
  "templates/wai/package.json",
];

for (const f of files) {
  const path = join(root, f);
  const text = readFileSync(path, "utf8");
  if (!text.includes(placeholder)) {
    console.error(`${f} has no ${placeholder}`);
    process.exit(1);
  }
  writeFileSync(path, text.replaceAll(placeholder, tag));
}

// npm rejects a placeholder as a version, so main has 0.0.0 there.
const pkg = join(root, "runtime/package.json");
writeFileSync(pkg, readFileSync(pkg, "utf8").replace('"version": "0.0.0"', `"version": "${tag.slice(1)}"`));

console.log(`filled in ${tag}`);
