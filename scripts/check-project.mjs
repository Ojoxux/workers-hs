// Check that workers-wai.project, which other projects import, stays in step
// with cabal.project: the same packages (less the demos and tests), the same
// constraints and the same flags.
//
//   node scripts/check-project.mjs [tag]   # with a tag: also check the pinned tag and the npm version

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
const shared = read("workers-wai.project");
const problems = [];

const own = field(local, "packages").filter((p) => !/\/(demo|test)-/.test(p)).sort();
const pinned = field(shared, "subdir").sort();
if (JSON.stringify(own) !== JSON.stringify(pinned)) {
  problems.push(`packages differ:\n  cabal.project:       ${own.join(" ")}\n  workers-wai.project: ${pinned.join(" ")}`);
}

const norm = (cs) => cs.map((c) => c.replace(/\s+/g, " ")).sort();
const [lc, sc] = [norm(field(local, "constraints")), norm(field(shared, "constraints"))];
if (JSON.stringify(lc) !== JSON.stringify(sc)) {
  problems.push(`constraints differ:\n  cabal.project:       ${lc.join(", ")}\n  workers-wai.project: ${sc.join(", ")}`);
}

const flags = (t) => [...t.matchAll(/^package (\S+)\n\s+flags:(.*)$/gm)].map((m) => `${m[1]}:${m[2].trim()}`).sort();
const [lf, sf] = [flags(local), flags(shared)];
if (JSON.stringify(lf) !== JSON.stringify(sf)) {
  problems.push(`flags differ:\n  cabal.project:       ${lf.join(" ")}\n  workers-wai.project: ${sf.join(" ")}`);
}

const tag = process.argv[2];
const pinnedTag = field(shared, "tag")[0];
if (tag && pinnedTag !== tag) problems.push(`workers-wai.project pins tag ${pinnedTag}, expected ${tag}`);
const npmVersion = JSON.parse(readFileSync(join(root, "runtime/package.json"), "utf8")).version;
if (tag && `v${npmVersion}` !== tag) problems.push(`runtime/package.json is version ${npmVersion}, expected ${tag.slice(1)}`);

if (problems.length) {
  console.log(problems.join("\n"));
  process.exit(1);
}
console.log(`workers-wai.project matches cabal.project (tag ${pinnedTag})`);
