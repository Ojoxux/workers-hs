// The next release tag, from the commits since the last one (Conventional
// Commits), or nothing when they hold nothing to release.
//
//   node scripts/next-version.mjs [rev]   # default rev: HEAD
//
// A breaking change (`type!:` or a `BREAKING CHANGE:` footer) bumps the
// major version (the minor one before 1.0), feat / fix / perf the patch
// version, anything else (docs, chore, test, ci, ...) nothing. With no tag
// yet, the first release is v0.1.0.

import { execFileSync } from "node:child_process";

const git = (...args) =>
  execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
const rev = process.argv[2] ?? "HEAD";

// A release tag points at a commit made off main (main plus the version filled
// in), so the last release is the highest tag, and its parent is where main was.
const last =
  git("tag", "--list", "v*.*.*", "--sort=-v:refname").split("\n").filter(Boolean)[0] ?? null;
const range = last ? `${last}^..${rev}` : rev;
// One record per commit: subject, then body, separated by NUL; records by \x1e.
const log = git("log", "--no-merges", "--format=%s%x00%b%x1e", range);
const commits = log.split("\x1e").map((c) => c.trim()).filter(Boolean).map((c) => {
  const [subject, body = ""] = c.split("\x00");
  return { subject, body };
});

const breaking = commits.some(
  (c) => /^[a-z]+(\([^)]*\))?!:/.test(c.subject) || /^BREAKING[ -]CHANGE:/m.test(c.body),
);
const releasable = commits.some((c) => /^(feat|fix|perf)(\([^)]*\))?:/.test(c.subject));

if (!last) {
  if (commits.length > 0) console.log("v0.1.0");
} else if (breaking || releasable) {
  const [major, minor, patch] = last.slice(1).split(".").map(Number);
  const next = !breaking
    ? [major, minor, patch + 1]
    : major === 0
      ? [0, minor + 1, 0]
      : [major + 1, 0, 0];
  console.log(`v${next.join(".")}`);
}
