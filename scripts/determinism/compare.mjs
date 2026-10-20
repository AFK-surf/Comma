#!/usr/bin/env node
// Compares the execution records of the runs of the files in a manifest.
//
//   node scripts/determinism/compare.mjs MANIFEST RECORD.jsonl...
//
// A manifest line "@<suite> <list>" names a whole suite: every file the runs
// named <suite>-<perturbation> recorded, except the files <list> (beside the
// manifest) names: the suite's files not yet proven, a list that only shrinks.
//
// A test skipped in every run (skipIf, ctx.skip) agrees; a file whose every
// test was skipped proves nothing.
//
// Each record line is one test of one run:
//   {"file", "test", "status", "events", "digest"}
// A file is proven when every run recorded the same tests, each passed with
// at least one event, and each test's digest is equal in all runs. Prints a
// Markdown table and exits 1 when a file of the manifest is not proven.
import { readFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";

const [manifestPath, ...recordPaths] = process.argv.slice(2);
if (!manifestPath || recordPaths.length < 2) {
  console.error("usage: compare.mjs MANIFEST RECORD.jsonl RECORD.jsonl...");
  process.exit(2);
}

const listed = (path) =>
  readFileSync(path, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));

// run -> file -> test -> record
const runs = recordPaths.map((path) => {
  const files = new Map();
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    const record = JSON.parse(line);
    if (!files.has(record.file)) files.set(record.file, new Map());
    files.get(record.file).set(record.test, record);
  }
  return { name: basename(path, ".jsonl"), files };
});

const manifest = listed(manifestPath).flatMap((line) => {
  const suite = /^@(\S+)\s+(\S+)$/.exec(line);
  if (!suite) return [line];
  const [, name, list] = suite;
  const outside = new Set(listed(resolve(dirname(manifestPath), list)));
  const files = new Set(
    runs
      .filter((run) => run.name.startsWith(`${name}-`))
      .flatMap((run) => [...run.files.keys()]),
  );
  return [...files].filter((file) => !outside.has(file)).sort();
});

const rows = [];
let failed = false;

for (const file of manifest) {
  const perRun = runs.map((run) => run.files.get(file) ?? new Map());
  const tests = [
    ...new Set(perRun.flatMap((tests) => [...tests.keys()])),
  ].sort();
  let problem = null;

  if (tests.length === 0) problem = "no records";

  for (const test of tests) {
    if (problem) break;
    const records = perRun.map((t) => t.get(test));
    const missing = records.findIndex((r) => !r);
    if (missing >= 0) problem = `${test}: not run in ${runs[missing].name}`;
    // A test every run skipped (skipIf, ctx.skip) agrees: it ran nowhere.
    else if (records.every((r) => r.status === "skipped")) continue;
    else if (records.some((r) => r.status !== "passed"))
      problem = `${test}: ${records.map((r, i) => `${runs[i].name}=${r.status}`).join(" ")}`;
    else if (records.some((r) => r.events === 0))
      problem = `${test}: records no execution`;
    else if (new Set(records.map((r) => r.digest)).size > 1)
      problem = `${test}: ${records.map((r, i) => `${runs[i].name}=${r.digest.slice(0, 8)}`).join(" ")}`;
  }

  // A file whose every test was skipped proves nothing.
  if (
    !problem &&
    tests.every((test) =>
      perRun.every((t) => t.get(test)?.status === "skipped"),
    )
  )
    problem = "every test skipped";
  if (problem) failed = true;
  rows.push(
    `| ${file} | ${tests.length} | ${problem ? "no" : "yes"} | ${problem ?? ""} |`,
  );
}

const proven = rows.filter((row) => row.includes("| yes |")).length;
console.log(
  `Proven deterministic: ${proven} / ${manifest.length} manifest files (runs: ${runs.map((r) => r.name).join(", ")})\n`,
);
console.log("| File | Tests | Same in every run | First difference |");
console.log("| --- | --- | --- | --- |");
for (const row of rows) console.log(row);
process.exit(failed ? 1 : 0);
