// Check that workers-hs.project, which other projects import, stays in step
// with cabal.project: the same packages (less the demos and tests), the same
// constraints and the same flags; and that versions are still placeholders.
//
//   node scripts/check-project.mjs

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => readFileSync(join(root, f), "utf8").replace(/^\s*--.*$/gm, "");

// The indented lines following `field:` (and any on the same line).
function field(text, name) {
  const m = text.match(new RegExp(`^\\s*${name}:(.*)\\n((?:[ \\t]+\\S.*\\n?)*)`, "m"));
  if (!m) return [];
  return (m[1] + "\n" + m[2]).split(/[,\n]/).map((s) => s.trim()).filter(Boolean);
}

const local = read("cabal.project");
const shared = read("workers-hs.project");
const problems = [];

const own = field(local, "packages").filter((p) => !/\/(demo|test)-/.test(p)).sort();
const pinned = field(shared, "subdir").sort();
if (JSON.stringify(own) !== JSON.stringify(pinned)) {
  problems.push(`packages differ:\n  cabal.project:       ${own.join(" ")}\n  workers-hs.project: ${pinned.join(" ")}`);
}

const norm = (cs) => cs.map((c) => c.replace(/\s+/g, " ")).sort();
const [lc, sc] = [norm(field(local, "constraints")), norm(field(shared, "constraints"))];
if (JSON.stringify(lc) !== JSON.stringify(sc)) {
  problems.push(`constraints differ:\n  cabal.project:       ${lc.join(", ")}\n  workers-hs.project: ${sc.join(", ")}`);
}

const flags = (t) => [...t.matchAll(/^package (\S+)\n\s+flags:(.*)$/gm)].map((m) => `${m[1]}:${m[2].trim()}`).sort();
const [lf, sf] = [flags(local), flags(shared)];
if (JSON.stringify(lf) !== JSON.stringify(sf)) {
  problems.push(`flags differ:\n  cabal.project:       ${lf.join(" ")}\n  workers-hs.project: ${sf.join(" ")}`);
}

// main keeps the version as a placeholder; scripts/fill-version.mjs fills it in
// on the release commit.
for (const f of ["workers-hs.project", "templates/wai/cabal.project", "templates/wai/flake.nix", "templates/wai/package.json"]) {
  if (!readFileSync(join(root, f), "utf8").includes("@VERSION@")) problems.push(`${f} names a version instead of @VERSION@`);
}

if (problems.length) {
  console.log(problems.join("\n"));
  process.exit(1);
}
console.log("workers-hs.project matches cabal.project; versions are placeholders");
