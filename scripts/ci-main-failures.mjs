#!/usr/bin/env node
// Says why `main` went red, without reading logs by hand.
//
//   node scripts/ci-main-failures.mjs [--since DATE] [--until DATE]
//     [--workflow NAME]... [--cache DIR] [--repo OWNER/NAME] [--json]
//
// For each workflow (Client Checks and Systems CI unless --workflow chooses)
// it takes the completed push runs on `main`, downloads the log of every
// failed job once into the cache directory, and sorts each red run into one
// of three classes:
//
//   regression  an item that was red in three or more consecutive runs;
//   runner      a log that matches one of `runnerSignatures`;
//   random      everything else.
//
// An item is (job name without its shard suffix, test file, test title). A
// job that fails without a test is the item (job, first error line). A run
// takes the worst class among its items, in the order above. `gh` must be
// logged in. Logs never change, so a cached log is not downloaded again;
// the run list and the job lists of red runs cost a few API calls.
import { execFile } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

/**
 * The workflows this script reads. `summaryJobs` only repeat the result of
 * other jobs, so their failure says nothing new.
 */
export const workflows = [
  {
    name: "Client Checks",
    file: "client-checks.yml",
    summaryJobs: ["Required Client CI"],
  },
  { name: "Systems CI", file: "systems-ci.yml", summaryJobs: ["test"] },
];

/**
 * Failures of the runner or the network, not of the code. The one place to
 * add a signature: `pattern` is tested against the text of a failing item
 * (its error block, or the job's log when it has none).
 */
export const runnerSignatures = [
  {
    id: "file-exists",
    pattern: /File exists \(os error/,
    label: "Unpacking onto a leftover directory (a runner workspace not cleaned)",
  },
  {
    id: "dynamic-import",
    pattern: /Failed to fetch dynamically imported module/,
    label: "Browser could not load a chunk from the local test server",
  },
  {
    id: "curl-timeout",
    pattern: /curl: \(28\)/,
    label: "curl timed out (network or GitHub API)",
  },
  { id: "emfile", pattern: /\bEMFILE\b/, label: "Too many open files on the runner" },
  { id: "econnreset", pattern: /\bECONNRESET\b/, label: "Connection reset by peer" },
  {
    id: "erl-child-setup",
    pattern: /erl_child_setup closed/,
    label: "BEAM lost its port helper process",
  },
  {
    id: "runner-lost",
    pattern:
      /runner has received a shutdown signal|lost communication with the server|The operation was canceled/,
    label: "Runner shut down, lost contact with GitHub or cancelled the step",
  },
];

/**
 * A job GitHub cancelled inside a red run has no failing test to blame: its
 * runner was lost or its time ran out, and often no log was kept.
 */
export const cancelledSignature = {
  id: "job-cancelled",
  label: "GitHub cancelled the job (runner lost or time limit), often with no log",
};

/** The id of the first signature in `text`, or null. */
export function matchSignature(text) {
  return runnerSignatures.find((signature) => signature.pattern.test(text))?.id ?? null;
}

const labelOf = (id) =>
  [...runnerSignatures, cancelledSignature].find((signature) => signature.id === id)
    .label;

// ---------------------------------------------------------------------------
// Log parsing. Everything here is a pure function of the log text.

const ansi = new RegExp(`${String.fromCharCode(27)}\\[[0-9;?]*[A-Za-z]`, "g");
const timestamp = /^\ufeff?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?/;

/** A job log as lines, without colors and the runner's time stamps. */
export function logLines(text) {
  return text
    .replace(ansi, "")
    .split(/\r?\n/)
    .map((line) => line.replace(timestamp, ""));
}

/** `Browser E2E Test (2/2)` and `test-beam (3/16)` are one job: drop the shard. */
export function shardless(jobName) {
  return jobName.replace(/\s+\([^()]*\)$/, "");
}

const duration = /\s+\((?:retry #\d+, )?\d+(?:\.\d+)?(?:ms|s|m|h)\)$/;
const location = String.raw`(\S+?):\d+:\d+`;
const project = String.raw`(?:\[[^\]]*\]\s+›\s+)?`;
// `  1) [project] › file:1:2 › title` (also `##[error]  1) file:1:2 › title`)
const playwrightNumbered = new RegExp(
  String.raw`^(?:##\[error\])?\s*\d+\)\s+${project}${location}\s+›\s+(.+?)\s*$`
);
// `  ✘  1 [project] › file:1:2 › title (6.6s)`; the only line some jobs print.
const playwrightMark = new RegExp(
  String.raw`^\s*✘\s+\d+\s+${project}${location}\s+›\s+(.+?)\s*$`
);
// The dot reporter's annotation: `::error file=F,title=file:1:2 › title,line=L,col=C::`
const playwrightAnnotation = new RegExp(
  String.raw`::error file=[^,]*,title=${location}\s+›\s+(.+?),line=\d+`
);
// The end of an error block: the next test result or the final counts.
const playwrightEnd =
  /^\s*(?:[✓✘-]\s+\d+\s|\d+ (?:failed|flaky|passed|skipped|did not run)\b)/;

/** Failing Playwright tests: `{file, title, detail}` for each, once. */
export function parsePlaywright(lines) {
  const items = new Map();
  const add = (file, title, detail = "") => {
    title = title
      .replace(/\s*─+$/, "")
      .replace(duration, "")
      .trim();
    const key = `${file}\t${title}`;
    const known = items.get(key);
    if (known) known.detail += detail;
    else items.set(key, { file, title, detail });
  };
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const numbered = playwrightNumbered.exec(line);
    if (numbered) {
      let end = i + 1;
      while (
        end < lines.length &&
        end - i < 200 &&
        !playwrightNumbered.test(lines[end]) &&
        !playwrightEnd.test(lines[end])
      )
        end += 1;
      add(numbered[1], numbered[2], lines.slice(i + 1, end).join("\n"));
      continue;
    }
    const mark = playwrightMark.exec(line);
    if (mark) {
      add(mark[1], mark[2]);
      continue;
    }
    const annotation = playwrightAnnotation.exec(line);
    if (annotation) add(annotation[1], annotation[2], line);
  }
  return [...items.values()];
}

// ` FAIL   node  apps/x/test/a.test.ts > Suite > title`, and
// ` FAIL   browser (chromium)  e2e/a.test.ts [ e2e/a.test.ts ]` for a file that failed to load.
const vitestFail =
  /^\s*FAIL\s+(?:.*?\s{2,})?(\S+\.[cm]?[jt]sx?)(?:\s+>\s+(.+?)|\s+\[.*\])?\s*$/;
const vitestRunError = /^Error: Failed to run the test (\S+?)\.\s*$/;
const vitestEnd = /^\s*(?:FAIL\b|⎯{3,})/;
/** The title of a failure that belongs to a whole file. */
export const fileTitle = "<file failed to load or run>";

/** Paths in the log are the runner's: keep what follows the repository's `clients/`. */
function clientsRelative(path) {
  const at = path.lastIndexOf("/clients/");
  return at === -1 ? path : path.slice(at + "/clients/".length);
}

/** Failing Vitest tests and files: `{file, title, detail}` for each, once. */
export function parseVitest(lines) {
  const items = new Map();
  const add = (file, title, detail) => {
    const key = `${file}\t${title}`;
    const known = items.get(key);
    if (known) known.detail += `\n${detail}`;
    else items.set(key, { file, title, detail });
  };
  for (let i = 0; i < lines.length; i += 1) {
    const fail = vitestFail.exec(lines[i]);
    const runError = fail ? null : vitestRunError.exec(lines[i]);
    if (!fail && !runError) continue;
    let end = i + 1;
    while (end < lines.length && end - i < 200 && !vitestEnd.test(lines[end])) end += 1;
    const detail = lines.slice(i + 1, end).join("\n");
    if (fail) add(fail[1], fail[2]?.trim() ?? fileTitle, detail);
    else add(clientsRelative(runError[1]), fileTitle, detail);
  }
  return [...items.values()];
}

// `  1) test name (Module.Test)` followed by `     path/to/file_test.exs:12`
const exunitHeader =
  /^\s*\d+\) (?:test|doctest|property) (.+?) \(([A-Z][\w.]*)\)(?::.*)?$/;
const exunitFile = /^\s+(\S+\.exs?):\d+\s*$/;
const exunitApp = /^==> (\S+)\s*$/;
const exunitEnd = /^\s*(?:\d+\) |Finished in |\d+ (?:doctests?|properties|tests?),)/;

/** Failing ExUnit tests: `{file, title, detail}` for each, once. */
export function parseExUnit(lines) {
  const items = new Map();
  let app = "";
  for (let i = 0; i < lines.length; i += 1) {
    const appLine = exunitApp.exec(lines[i]);
    if (appLine) app = appLine[1];
    const header = exunitHeader.exec(lines[i]);
    if (!header) continue;
    let file = null;
    for (let at = i + 1; at < Math.min(i + 4, lines.length); at += 1) {
      file = exunitFile.exec(lines[at])?.[1] ?? null;
      if (file) break;
    }
    if (!file) continue;
    let end = i + 1;
    while (end < lines.length && end - i < 200 && !exunitEnd.test(lines[end])) end += 1;
    const path = app && !file.startsWith("apps/") ? `${app}/${file}` : file;
    const title = header[1];
    const key = `${path}\t${title}`;
    const detail = lines.slice(i + 1, end).join("\n");
    const known = items.get(key);
    if (known) known.detail += `\n${detail}`;
    else items.set(key, { file: path, title, detail });
  }
  return [...items.values()];
}

/** Numbers that change between runs (times, ports, ids) must not split an item. */
export function normalizeMessage(message) {
  return message
    .replace(/\(\d+(?:\.\d+)?m?s\)/g, "(T)")
    .replace(/\d{3,}/g, "N")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 160);
}

const boilerplate = [
  /^\s*$/,
  /^##\[/,
  /^Cleaning up/,
  /^make: /,
  /^\s+\(?[\w.]+ [\d.]+\) /, // an Elixir stack frame
  /^\s+\S+:\d+: /,
  /^\s*at /,
  /^\|/,
];
const cause = [/^\*\* \(/, /^--- FAIL: /];

/**
 * The line that says why a job without a failing test failed: its first
 * `##[error]` line. When that only repeats the exit code, the cause is above
 * it: an Elixir exception or a failing Go test, else the last line of output
 * that is not a stack frame or a `make` message.
 */
export function firstErrorLine(lines) {
  const at = lines.findIndex((line) => line.startsWith("##[error]"));
  if (at === -1) return "(no error line in the log)";
  const message = lines[at].slice("##[error]".length);
  if (/^[-=]{2,}.*[-=]{2,}$/.test(message.trim())) {
    // A heading such as `--- failure summary ---`: the next line has the content.
    const next = lines
      .slice(at + 1)
      .find((line) => line.trim() && !line.startsWith("##["));
    if (next) return normalizeMessage(next);
  }
  if (!/^Process completed with exit code \d+\.?$/.test(message))
    return normalizeMessage(message);
  const above = lines.slice(Math.max(0, at - 150), at).toReversed();
  const found =
    above.find((line) => cause.some((pattern) => pattern.test(line))) ??
    above.find((line) => !boilerplate.some((pattern) => pattern.test(line)));
  return normalizeMessage(found ?? message);
}

/**
 * The failing items of one job log. `tests` is false when the log names no
 * test and the item is the job's first error line.
 */
export function parseJobLog(text) {
  const lines = logLines(text);
  const found = [
    ...parsePlaywright(lines),
    ...parseVitest(lines),
    ...parseExUnit(lines),
  ];
  if (found.length > 0) return { tests: true, items: found };
  return {
    tests: false,
    items: [{ file: "", title: firstErrorLine(lines), detail: lines.join("\n") }],
  };
}

// ---------------------------------------------------------------------------
// Classification. Pure as well.

/** The item's identity, the same in every run. */
export const itemKey = (item) => `${item.job}\t${item.file}\t${item.title}`;

/**
 * @param {Array<{id: string, sha: string, createdAt: string, items: Array}>} runs
 *   completed runs in creation order; an item is `{job, file, title, signature}`
 * @param {number} streak consecutive runs that make a regression
 * @returns {{streaks: Array, runs: Array}} every streak and each run's class
 */
export function classify(runs, streak = 3) {
  const seen = new Map();
  runs.forEach((run, index) => {
    for (const key of new Set(run.items.map(itemKey))) {
      if (!seen.has(key)) seen.set(key, []);
      seen.get(key).push(index);
    }
  });
  const streaks = [];
  const inStreak = new Set();
  for (const [key, indexes] of seen) {
    let from = 0;
    for (let at = 1; at <= indexes.length; at += 1) {
      if (at < indexes.length && indexes[at] === indexes[at - 1] + 1) continue;
      if (at - from >= streak) {
        const first = indexes[from];
        const last = indexes[at - 1];
        const [job, file, title] = key.split("\t");
        streaks.push({
          key,
          job,
          file,
          title,
          first,
          last,
          length: last - first + 1,
          ongoing: last === runs.length - 1,
        });
        for (let index = first; index <= last; index += 1)
          inStreak.add(`${key}\t${index}`);
      }
      from = at;
    }
  }
  const classified = runs.map((run, index) => {
    const items = run.items.map((item) => ({
      ...item,
      class: inStreak.has(`${itemKey(item)}\t${index}`)
        ? "regression"
        : item.signature
          ? "runner"
          : "random",
    }));
    const order = ["regression", "runner", "random"];
    const worst =
      order.find((name) => items.some((item) => item.class === name)) ?? null;
    return { ...run, items, class: worst };
  });
  return { streaks, runs: classified };
}

/** UTC+8 calendar day of a time stamp. */
export function dayOf(iso) {
  return new Date(Date.parse(iso) + 8 * 3600_000).toISOString().slice(0, 10);
}

/** The report of one workflow, from its completed runs in creation order. */
export function summarize(runs) {
  const { streaks, runs: classified } = classify(runs);
  const days = new Map();
  for (const run of classified) {
    const day = dayOf(run.createdAt);
    const row = days.get(day) ?? {
      day,
      completed: 0,
      red: 0,
      regression: 0,
      runner: 0,
      random: 0,
    };
    row.completed += 1;
    if (run.class) {
      row.red += 1;
      row[run.class] += 1;
    }
    days.set(day, row);
  }
  const rows = [...days.values()].toSorted((a, b) => a.day.localeCompare(b.day));
  const total = rows.reduce(
    (sum, row) => ({
      completed: sum.completed + row.completed,
      red: sum.red + row.red,
      regression: sum.regression + row.regression,
      runner: sum.runner + row.runner,
      random: sum.random + row.random,
    }),
    { completed: 0, red: 0, regression: 0, runner: 0, random: 0 }
  );

  // Random items: red runs in which the item was random, with the number of
  // distinct random tests of the same file.
  const randomItems = new Map();
  for (const run of classified) {
    for (const item of run.items) {
      if (item.class !== "random") continue;
      const key = itemKey(item);
      const entry = randomItems.get(key) ?? {
        ...item,
        count: 0,
        firstDay: dayOf(run.createdAt),
        lastDay: dayOf(run.createdAt),
      };
      entry.count += 1;
      entry.lastDay = dayOf(run.createdAt);
      randomItems.set(key, entry);
    }
  }
  const titlesPerFile = new Map();
  for (const entry of randomItems.values()) {
    const file = `${entry.job}\t${entry.file}`;
    if (!titlesPerFile.has(file)) titlesPerFile.set(file, new Set());
    titlesPerFile.get(file).add(entry.title);
  }
  const random = [...randomItems.values()]
    .map((entry) => ({
      job: entry.job,
      file: entry.file,
      title: entry.title,
      count: entry.count,
      firstDay: entry.firstDay,
      lastDay: entry.lastDay,
      testsInFile: titlesPerFile.get(`${entry.job}\t${entry.file}`).size,
    }))
    .toSorted(
      (a, b) =>
        b.count - a.count ||
        b.lastDay.localeCompare(a.lastDay) ||
        itemKey(a).localeCompare(itemKey(b))
    );

  const regressions = streaks
    .map((streak) => ({
      job: streak.job,
      file: streak.file,
      title: streak.title,
      length: streak.length,
      ongoing: streak.ongoing,
      began: describeRun(classified[streak.first]),
      lastRed: describeRun(classified[streak.last]),
      // The next completed run: the first one in which the item is no longer red.
      greenAt: classified[streak.last + 1]
        ? describeRun(classified[streak.last + 1])
        : null,
    }))
    .toSorted(
      (a, b) =>
        b.length - a.length || a.began.createdAt.localeCompare(b.began.createdAt)
    );

  const signatures = new Map();
  for (const run of classified) {
    for (const item of run.items) {
      if (!item.signature || item.class === "regression") continue;
      const entry = signatures.get(item.signature) ?? {
        id: item.signature,
        items: 0,
        runs: new Set(),
      };
      entry.items += 1;
      entry.runs.add(run.id);
      signatures.set(item.signature, entry);
    }
  }
  const runner = [...signatures.values()]
    .map((entry) => ({
      id: entry.id,
      label: labelOf(entry.id),
      items: entry.items,
      runs: entry.runs.size,
    }))
    .toSorted((a, b) => b.runs - a.runs || a.id.localeCompare(b.id));

  return { total, days: rows, random, regressions, runner, runs: classified };
}

function describeRun(run) {
  return {
    id: run.id,
    sha: run.sha.slice(0, 9),
    createdAt: run.createdAt,
    message: run.message ?? "",
  };
}

// ---------------------------------------------------------------------------
// Text output.

const pad = (value, width) => String(value).padStart(width);
const clip = (text, width) =>
  text.length > width ? `${text.slice(0, width - 1)}…` : text;
const stamp = (iso) =>
  new Date(Date.parse(iso) + 8 * 3600_000).toISOString().slice(0, 16).replace("T", " ");

/** The terminal report of a workflow's summary. */
export function renderWorkflow(name, summary) {
  const { total } = summary;
  const out = [];
  const ratio = total.completed === 0 ? 0 : total.random / total.completed;
  out.push(
    `== ${name}: ${total.completed} completed, ${total.red} red (${total.regression} regression, ${total.runner} runner, ${total.random} random); random ${total.random}/${total.completed} = ${ratio.toFixed(3)}`
  );
  out.push("");
  out.push("Per day (UTC+8)");
  out.push(
    `  ${"day".padEnd(10)} ${pad("completed", 9)} ${pad("red", 4)} ${pad("regress", 7)} ${pad("runner", 6)} ${pad("random", 6)}`
  );
  for (const row of summary.days)
    out.push(
      `  ${row.day.padEnd(10)} ${pad(row.completed, 9)} ${pad(row.red, 4)} ${pad(row.regression, 7)} ${pad(row.runner, 6)} ${pad(row.random, 6)}`
    );
  out.push(
    `  ${"total".padEnd(10)} ${pad(total.completed, 9)} ${pad(total.red, 4)} ${pad(total.regression, 7)} ${pad(total.runner, 6)} ${pad(total.random, 6)}`
  );

  out.push("");
  out.push(
    `Random failures by item (${summary.random.length} items; "tests" = distinct random tests in the same file)`
  );
  if (summary.random.length === 0) out.push("  none");
  for (const item of summary.random) {
    const where = item.file
      ? `${item.file} > ${item.title}`
      : `(no test) ${item.title}`;
    out.push(
      `  ${pad(item.count, 3)}x  ${item.firstDay}..${item.lastDay}  tests ${pad(item.testsInFile, 2)}  ${item.job}: ${clip(where, 150)}`
    );
  }

  out.push("");
  out.push(`Regressions (${summary.regressions.length} streaks of 3 or more runs)`);
  if (summary.regressions.length === 0) out.push("  none");
  for (const streak of summary.regressions) {
    const where = streak.file
      ? `${streak.file} > ${streak.title}`
      : `(no test) ${streak.title}`;
    out.push(`  ${pad(streak.length, 3)} runs  ${streak.job}: ${clip(where, 150)}`);
    out.push(
      `        began    ${streak.began.sha} ${stamp(streak.began.createdAt)} ${clip(streak.began.message, 70)}`
    );
    out.push(
      `        last red ${streak.lastRed.sha} ${stamp(streak.lastRed.createdAt)} ${clip(streak.lastRed.message, 70)}`
    );
    out.push(
      streak.greenAt
        ? `        green at ${streak.greenAt.sha} ${stamp(streak.greenAt.createdAt)} ${clip(streak.greenAt.message, 70)}`
        : "        still red in the latest run"
    );
  }

  out.push("");
  out.push("Runner or network signatures");
  if (summary.runner.length === 0) out.push("  none");
  for (const signature of summary.runner)
    out.push(
      `  ${pad(signature.runs, 3)} runs ${pad(signature.items, 3)} items  ${signature.id.padEnd(16)} ${signature.label}`
    );
  return out.join("\n");
}

// ---------------------------------------------------------------------------
// GitHub access (not covered by the unit tests).

const maxBuffer = 1024 * 1024 * 1024;
let apiCalls = 0;

function gh(args, { allowFailure = false } = {}) {
  apiCalls += 1;
  return new Promise((done, fail) => {
    execFile(
      "gh",
      ["api", ...args],
      { maxBuffer, encoding: "utf8" },
      (error, stdout, stderr) => {
        if (!error) return done(stdout);
        if (allowFailure) return done(null);
        fail(new Error(`gh api ${args.join(" ")}: ${stderr.trim() || error.message}`));
      }
    );
  });
}

async function pool(values, size, work) {
  const results = Array.from({ length: values.length });
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(size, values.length) }, async () => {
      while (next < values.length) {
        const index = next;
        next += 1;
        results[index] = await work(values[index], index);
      }
    })
  );
  return results;
}

/** Completed push runs on main created in [since, until), oldest first. */
async function listRuns(repo, workflow, since, until) {
  const created = until ? `${since}..${until}` : `>=${since}`;
  const output = await gh([
    "-X",
    "GET",
    "--paginate",
    `repos/${repo}/actions/workflows/${workflow.file}/runs`,
    "-f",
    "branch=main",
    "-f",
    "event=push",
    "-f",
    "status=completed",
    "-f",
    "per_page=100",
    "-f",
    `created=${created}`,
    "--jq",
    '.workflow_runs[] | {id, conclusion, createdAt: .created_at, sha: .head_sha, attempt: .run_attempt, message: (.head_commit.message // "" | split("\\n")[0])}',
  ]);
  const all = output
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  apiCalls += Math.max(0, Math.ceil(all.length / 100) - 1); // one call per page after the first
  return all
    .filter((run) => run.conclusion === "success" || run.conclusion === "failure")
    .toSorted((a, b) => a.createdAt.localeCompare(b.createdAt));
}

/** The jobs of a run (cached: a finished attempt does not change). */
async function jobsOf(repo, run, cache) {
  const file = join(cache, `jobs-${run.id}-${run.attempt}.json`);
  if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8"));
  const output = await gh([
    "-X",
    "GET",
    "--paginate",
    `repos/${repo}/actions/runs/${run.id}/jobs`,
    "-f",
    "per_page=100",
    "-f",
    "filter=latest",
    "--jq",
    ".jobs[] | {id, name, conclusion}",
  ]);
  const jobs = output
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  apiCalls += Math.max(0, Math.ceil(jobs.length / 100) - 1);
  writeFileSync(file, `${JSON.stringify(jobs)}\n`);
  return jobs;
}

/** A job's log text (cached forever), or null when GitHub no longer has it. */
async function logOf(repo, job, cache) {
  const file = join(cache, `log-${job.id}.txt`);
  if (existsSync(file)) return readFileSync(file, "utf8");
  if (existsSync(`${file}.missing`)) return null;
  const text = await gh([`repos/${repo}/actions/jobs/${job.id}/logs`], {
    allowFailure: true,
  });
  if (text === null) {
    writeFileSync(`${file}.missing`, "");
    return null;
  }
  const partial = `${file}.part`;
  writeFileSync(partial, text);
  renameSync(partial, file);
  return text;
}

// A job cancelled inside a red run was lost with its runner or cut off by a limit.
const failedConclusions = new Set(["failure", "timed_out", "cancelled"]);

async function collect(repo, workflow, since, until, cache) {
  const listed = await listRuns(repo, workflow, since, until);
  const runs = await pool(listed, 4, async (run) => {
    const base = {
      id: String(run.id),
      conclusion: run.conclusion,
      sha: run.sha,
      createdAt: run.createdAt,
      message: run.message,
      items: [],
    };
    if (run.conclusion !== "failure") return base;
    const jobs = (await jobsOf(repo, run, cache)).filter(
      (job) =>
        failedConclusions.has(job.conclusion) &&
        !workflow.summaryJobs.includes(job.name)
    );
    if (jobs.length === 0) {
      base.items.push({
        job: "(run)",
        file: "",
        title: "red run with no failed job",
        signature: null,
      });
      return base;
    }
    for (const job of jobs) {
      const text = await logOf(repo, job, cache);
      const name = shardless(job.name);
      const cancelled = job.conclusion === "cancelled" ? cancelledSignature.id : null;
      if (text === null) {
        base.items.push({
          job: name,
          file: "",
          title: cancelled ? "(job cancelled, no log)" : "(log no longer available)",
          signature: cancelled,
        });
        continue;
      }
      for (const item of parseJobLog(text).items) {
        // A test is judged by its own error block; a file that failed to load, or a job without a test, by the whole log.
        const evidence = item.title === fileTitle || !item.detail ? text : item.detail;
        base.items.push({
          job: name,
          file: item.file,
          title: item.title,
          signature: matchSignature(evidence) ?? cancelled,
        });
      }
    }
    return base;
  });
  return runs;
}

// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const options = {
    workflows: [],
    since: null,
    until: null,
    cache: join(homedir(), ".cache", "cue-ci-main-failures"),
    repo: "AFK-surf/Cue",
    json: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`${flag} needs a value`);
      return argv[i];
    };
    if (flag === "--since") options.since = value();
    else if (flag === "--until") options.until = value();
    else if (flag === "--workflow") options.workflows.push(value());
    else if (flag === "--cache") options.cache = resolve(value());
    else if (flag === "--repo") options.repo = value();
    else if (flag === "--json") options.json = true;
    else throw new Error(`unknown option ${flag}\n${usage}`);
  }
  if (!options.since) {
    const week = new Date(Date.now() - 7 * 24 * 3600_000);
    options.since = week.toISOString().slice(0, 10);
  }
  return options;
}

const usage =
  "usage: ci-main-failures.mjs [--since DATE] [--until DATE] [--workflow NAME]... [--cache DIR] [--repo OWNER/NAME] [--json]\n" +
  "  DATE is a UTC date or time (2026-10-08, 2026-10-12T08:36:28Z); --until is exclusive.\n" +
  `  workflows: ${workflows.map((workflow) => workflow.name).join(", ")} (default: both)`;

async function main(argv) {
  const options = parseArgs(argv);
  const chosen =
    options.workflows.length === 0
      ? workflows
      : options.workflows.map((name) => {
          const workflow = workflows.find(
            (candidate) => candidate.name.toLowerCase() === name.toLowerCase()
          );
          if (!workflow)
            throw new Error(
              `unknown workflow ${name}; known: ${workflows.map((candidate) => candidate.name).join(", ")}`
            );
          return workflow;
        });
  mkdirSync(options.cache, { recursive: true });

  const reports = [];
  for (const workflow of chosen) {
    const runs = await collect(
      options.repo,
      workflow,
      options.since,
      options.until,
      options.cache
    );
    reports.push({ name: workflow.name, ...summarize(runs) });
  }
  const completed = reports.reduce((sum, report) => sum + report.total.completed, 0);
  const random = reports.reduce((sum, report) => sum + report.total.random, 0);
  const ratio = completed === 0 ? 0 : random / completed;

  if (options.json) {
    const slim = reports.map(({ runs, ...report }) => ({
      ...report,
      runs: runs.map(({ items, ...run }) => ({
        ...run,
        items: items.map(({ detail: _detail, ...item }) => item),
      })),
    }));
    console.log(
      JSON.stringify(
        {
          since: options.since,
          until: options.until,
          workflows: slim,
          completed,
          random,
          randomRatio: ratio,
          apiCalls,
        },
        null,
        2
      )
    );
    return;
  }
  for (const report of reports) {
    console.log(renderWorkflow(report.name, report));
    console.log("");
  }
  console.error(`GitHub API calls: ${apiCalls}`);
  console.log(ratio.toFixed(3));
}

if (
  process.argv[1] &&
  existsSync(process.argv[1]) &&
  resolve(process.argv[1]) === import.meta.filename
) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exit(2);
  });
}
