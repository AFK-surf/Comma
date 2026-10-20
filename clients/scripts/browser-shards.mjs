#!/usr/bin/env node
// Deals the browser component test files to shards of about equal time, one
// line of files for each shard:
//
//   node scripts/browser-shards.mjs <shards>
//
// A file's time is what it took on main's CI (e2e/app-shell/browser-durations.json);
// a file not in it yet counts its size at the seconds per byte of those that
// are. The longest file goes first, each to the shard with the least so far.
// A file's size alone put the layout specs, which take far longer per byte
// than the rest, in one shard that ran 100 s longer than the others.
//
// To measure the files again, run them as CI does with Vitest's JSON report
// and write its times into the table:
//
//   pnpm exec vitest run --project browser --maxWorkers=1 --reporter=json --outputFile=browser-report.json
//   node scripts/browser-shards.mjs --durations browser-report.json
import { globSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { browserTestFiles } from "../e2e/app-shell/browser-files.mjs";

const clients = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const table = resolve(clients, "e2e/app-shell/browser-durations.json");

if (process.argv[2] === "--durations") {
  const report = JSON.parse(readFileSync(resolve(process.argv[3]), "utf8"));
  const seconds = Object.fromEntries(
    report.testResults
      .map((result) => [
        relative(clients, result.name),
        Math.round((result.endTime - result.startTime) / 100) / 10,
      ])
      .toSorted(([a], [b]) => a.localeCompare(b))
  );
  writeFileSync(table, `${JSON.stringify(seconds, null, 2)}\n`);
  process.exit(0);
}

const measured = JSON.parse(readFileSync(table, "utf8"));
const files = globSync(browserTestFiles, {
  cwd: clients,
  exclude: (entry) => (entry.name ?? entry) === "node_modules",
}).map((file) => ({ file, size: statSync(resolve(clients, file)).size }));
const known = files.filter(({ file }) => measured[file] !== undefined);
const perByte =
  known.reduce((sum, { file }) => sum + measured[file], 0) /
  Math.max(
    1,
    known.reduce((sum, { size }) => sum + size, 0)
  );
const timed = files
  .map(({ file, size }) => ({ file, time: measured[file] ?? size * perByte }))
  .toSorted((a, b) => b.time - a.time || a.file.localeCompare(b.file));
const shards = Array.from({ length: Number(process.argv[2] ?? 2) }, () => ({
  time: 0,
  files: [],
}));
for (const { file, time } of timed) {
  const least = shards.reduce((a, b) => (b.time < a.time ? b : a));
  least.time += time;
  least.files.push(file);
}
for (const shard of shards) console.log(shard.files.toSorted().join(" "));
