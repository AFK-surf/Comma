#!/usr/bin/env node
// Writes this workflow run's job times and flaky tests to the job summary,
// so a slow job or a test that only passed on retry shows up on the run page
// instead of in a log nobody opens.
//
//   GITHUB_TOKEN=... node scripts/ci-timing-summary.mjs
//
// Reads GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_JOB_NAME_SELF (the calling
// job, left out) and appends to GITHUB_STEP_SUMMARY. Reporting never fails
// the job.
import { appendFile } from "node:fs/promises";

/** Jobs over this many seconds are marked as over the budget. */
export const budgetSeconds = 180;

const seconds = (from, to) =>
  Math.round((new Date(to).getTime() - new Date(from).getTime()) / 1000);

/**
 * @param {Array<{name: string, conclusion: string | null, started_at: string | null,
 *   completed_at: string | null}>} jobs
 * @param {Map<string, string[]>} flakyByJob test titles Playwright reported flaky
 */
export function summarize(jobs, flakyByJob = new Map()) {
  const timed = jobs
    .filter((job) => job.started_at && job.completed_at && job.conclusion !== "skipped")
    .map((job) => ({
      name: job.name,
      conclusion: job.conclusion,
      duration: seconds(job.started_at, job.completed_at),
    }))
    .toSorted((a, b) => b.duration - a.duration);
  const minutes = (value) => `${Math.floor(value / 60)}m${String(value % 60).padStart(2, "0")}s`;
  const lines = [
    "### Job times",
    "",
    `| Job | Time | Result |`,
    `| --- | --- | --- |`,
    ...timed.map(
      (job) =>
        `| ${job.name} | ${minutes(job.duration)}${job.duration > budgetSeconds ? " ⚠️ over 3m" : ""} | ${job.conclusion} |`
    ),
  ];
  const flaky = [...flakyByJob].filter(([, titles]) => titles.length > 0);
  if (flaky.length > 0) {
    lines.push("", "### Flaky tests (passed only on retry)", "");
    for (const [job, titles] of flaky) {
      for (const title of titles) lines.push(`- ${job}: ${title}`);
    }
  }
  return `${lines.join("\n")}\n`;
}

/**
 * Test titles under the "N flaky" heading of Playwright's run summary
 * annotation; the summary also lists failed tests under their own heading.
 */
export function flakyTitles(annotations) {
  const titles = [];
  for (const annotation of annotations) {
    let inFlaky = false;
    for (const raw of (annotation.message ?? "").split("\n")) {
      const line = raw.trim();
      if (/^\d+ \w/.test(line)) inFlaky = /^\d+ flaky$/.test(line);
      else if (inFlaky && line.startsWith("[")) titles.push(line);
    }
  }
  return titles;
}

async function main() {
  const { GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_TOKEN, GITHUB_STEP_SUMMARY } =
    process.env;
  if (!GITHUB_REPOSITORY || !GITHUB_RUN_ID || !GITHUB_TOKEN || !GITHUB_STEP_SUMMARY) {
    console.log("No run to summarize.");
    return;
  }
  const api = async (path) => {
    const response = await fetch(`https://api.github.com/repos/${GITHUB_REPOSITORY}${path}`, {
      headers: { authorization: `Bearer ${GITHUB_TOKEN}`, accept: "application/vnd.github+json" },
    });
    if (!response.ok) throw new Error(`${path}: ${response.status}`);
    return response.json();
  };
  const { jobs } = await api(`/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100`);
  const others = jobs.filter((job) => job.name !== process.env.GITHUB_JOB_NAME_SELF);
  const flakyByJob = new Map();
  for (const job of others) {
    if (job.conclusion !== "success" && job.conclusion !== "failure") continue;
    const annotations = await api(`/check-runs/${job.id}/annotations?per_page=100`);
    flakyByJob.set(job.name, flakyTitles(annotations));
  }
  await appendFile(GITHUB_STEP_SUMMARY, summarize(others, flakyByJob));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => console.log(`Could not summarize the run: ${error.message}`));
}
