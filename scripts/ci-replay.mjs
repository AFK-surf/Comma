#!/usr/bin/env node
// Records how a CI test command ran, and replays a failed one locally.
//
// In CI, a test step runs its command through `record`:
//
//   node scripts/ci-replay.mjs record NAME -- mix test ... --seed 0
//
// It writes .ci-replay/NAME/replay.json in the workspace (commit, working directory, argv
// and the environment that decides the result) and output.log, then exits
// with the command's status. A failed job uploads the directory as the
// `ci-replay-*` artifact.
//
// Locally, with the services a suite needs running:
//
//   node scripts/ci-replay.mjs RUN_ID_OR_URL [NAME_FILTER] [--checkout]
//
// downloads those artifacts and runs each recorded command again in this
// checkout. The checkout must be at the recorded commit; `--checkout` fetches
// it and detaches HEAD there.
import { spawn, spawnSync } from "node:child_process";
import {
  createWriteStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
} from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");

/**
 * Variables that change a test result without being part of the command.
 * Values from the CI secret store never belong here.
 */
export const recordedEnv = [
  /^CI$/,
  /^TZ$/,
  /^LANG$/,
  /^LC_ALL$/,
  /^MIX_ENV$/,
  /^ERL_FLAGS$/,
  /^ELIXIR_ERL_OPTIONS$/,
  /^NODE_OPTIONS$/,
  /^REDIS(_TEST)?_URL$/,
  /^DATABASE_URL$/,
  /^COMMA_[A-Z0-9_]+$/,
  /^E2E_[A-Z0-9_]+$/,
  /^PLAYWRIGHT_[A-Z0-9_]+$/,
];

/** Environment entries that `recordedEnv` keeps. */
export function pickEnv(env) {
  return Object.fromEntries(
    Object.entries(env)
      .filter(([key]) => recordedEnv.some((pattern) => pattern.test(key)))
      .toSorted(([a], [b]) => a.localeCompare(b))
  );
}

/** The replay record for `argv` run in `cwd`. */
export function replayRecord({ name, argv, cwd, env }) {
  return {
    name,
    sha: env.GITHUB_SHA ?? git(["rev-parse", "HEAD"]),
    run: env.GITHUB_RUN_ID
      ? `${env.GITHUB_SERVER_URL}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}`
      : null,
    job: env.GITHUB_JOB ?? null,
    cwd: relative(repoRoot, cwd) || ".",
    argv,
    env: pickEnv(env),
  };
}

function git(args) {
  const result = spawnSync("git", args, { cwd: repoRoot, encoding: "utf8" });
  if (result.status !== 0)
    throw new Error(`git ${args.join(" ")}: ${result.stderr.trim()}`);
  return result.stdout.trim();
}

async function record(name, argv) {
  if (!/^[\w.-]+$/.test(name))
    throw new Error(`replay name must be a file name: ${name}`);
  // GITHUB_WORKSPACE holds the right path inside a job container too.
  const dir = join(
    process.env.CI_REPLAY_DIR ??
      join(process.env.GITHUB_WORKSPACE ?? tmpdir(), ".ci-replay"),
    name
  );
  mkdirSync(dir, { recursive: true });
  const entry = replayRecord({
    name,
    argv,
    cwd: process.cwd(),
    env: process.env,
  });
  await writeFile(join(dir, "replay.json"), `${JSON.stringify(entry, null, 2)}\n`);

  const log = createWriteStream(join(dir, "output.log"));
  const child = spawn(argv[0], argv.slice(1), {
    stdio: ["inherit", "pipe", "pipe"],
  });
  child.stdout.on("data", (chunk) => {
    process.stdout.write(chunk);
    log.write(chunk);
  });
  child.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
    log.write(chunk);
  });
  const status = await new Promise((done) =>
    child.on("close", (code, signal) => done(code ?? (signal ? 128 : 1)))
  );
  await new Promise((done) => log.end(done));
  return status;
}

function replay(target, filter, checkout) {
  const runId = /(\d+)\/?(?:attempts\/\d+)?\/?$/.exec(target.split("/job/")[0])?.[1];
  if (!runId) throw new Error(`not a run id or run URL: ${target}`);
  const dir = mkdtempSync(join(tmpdir(), `ci-replay-${runId}-`));
  const download = spawnSync(
    "gh",
    ["run", "download", runId, "--pattern", "ci-replay-*", "--dir", dir],
    { cwd: repoRoot, stdio: "inherit" }
  );
  if (download.status !== 0) throw new Error(`no ci-replay artifacts in run ${runId}`);

  const entries = findRecords(dir)
    .map((file) => JSON.parse(readFileSync(file, "utf8")))
    .filter((entry) => !filter || entry.name.includes(filter));
  if (entries.length === 0)
    throw new Error(`no recorded command matches ${filter ?? "the run"}`);

  const shas = new Set(entries.map((entry) => entry.sha));
  if (shas.size !== 1)
    throw new Error(`records span several commits: ${[...shas].join(", ")}`);
  const [sha] = shas;
  if (git(["rev-parse", "HEAD"]) !== sha) {
    if (!checkout) {
      throw new Error(
        `HEAD is not ${sha}; rerun with --checkout or check it out first`
      );
    }
    git(["fetch", "origin", sha]);
    git(["switch", "--detach", sha]);
  }

  let failed = 0;
  for (const entry of entries) {
    const cwd = join(repoRoot, entry.cwd);
    console.log(`\n== ${entry.name} (${entry.cwd}): ${entry.argv.join(" ")}`);
    const result = spawnSync(entry.argv[0], entry.argv.slice(1), {
      cwd,
      env: { ...process.env, ...entry.env },
      stdio: "inherit",
    });
    if (result.status !== 0) failed += 1;
  }
  return failed === 0 ? 0 : 1;
}

function findRecords(dir) {
  return readdirSync(dir, { withFileTypes: true, recursive: true })
    .filter((entry) => entry.isFile() && entry.name === "replay.json")
    .map((entry) => join(entry.parentPath, entry.name));
}

async function main(args) {
  if (args[0] === "record") {
    const separator = args.indexOf("--");
    const name = args[1];
    const argv = args.slice(separator + 1);
    if (separator !== 2 || argv.length === 0) {
      throw new Error("usage: ci-replay.mjs record NAME -- COMMAND...");
    }
    return record(name, argv);
  }
  const checkout = args.includes("--checkout");
  const [target, filter] = args.filter((arg) => arg !== "--checkout");
  if (!target)
    throw new Error("usage: ci-replay.mjs RUN_ID_OR_URL [NAME_FILTER] [--checkout]");
  return replay(target, filter, checkout);
}

if (
  process.argv[1] &&
  existsSync(process.argv[1]) &&
  resolve(process.argv[1]) === import.meta.filename
) {
  main(process.argv.slice(2)).then(
    (status) => process.exit(status),
    (error) => {
      console.error(error.message);
      process.exit(2);
    }
  );
}
