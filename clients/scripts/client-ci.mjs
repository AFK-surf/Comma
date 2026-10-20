#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import {
  androidCiChanged,
  appleCiChanged,
  clientBuildChanged,
  clientCiChanged,
  computerUseCiChanged,
  electronCiChanged,
  gitChangedFiles,
  storybookChanged,
  synchCiChanged,
  validateClientGate,
  workflowCiChanged,
  writeGitHubOutput,
  websiteChanged,
} from "./client-ci-lib.mjs";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const [command, ...args] = process.argv.slice(2);

if (command === "changes") {
  const options = parseOptions(args);
  const base = options.get("base");
  const head = options.get("head");
  const list = options.get("files");
  const output = process.env.GITHUB_OUTPUT;
  if (!((base && head) || list) || !output) {
    finish(["changes requires --base and --head, or --files, and GITHUB_OUTPUT."]);
  }
  // `--files` names a file listing the changed paths, one per line; `--all
  // true` says the list is incomplete (an API page limit), so all of it runs.
  const all = options.get("all") === "true";
  const files = list
    ? (await readFile(list, "utf8")).split(/\r?\n/).filter(Boolean)
    : gitChangedFiles(base, head, repositoryRoot);
  const changed =
    all ||
    (options.get("scope") === "build"
      ? clientBuildChanged(files)
      : clientCiChanged(files));
  // `--android-files` lists the paths since the last staging release on main,
  // so a run replaced by a newer push still publishes its Android changes.
  const androidList = options.get("android-files");
  const androidFiles = androidList
    ? (await readFile(androidList, "utf8")).split(/\r?\n/).filter(Boolean)
    : files;
  const outputs = {
    client: changed,
    apple: all || appleCiChanged(files),
    android:
      all || options.get("android-all") === "true" || androidCiChanged(androidFiles),
  };
  if (options.get("scope") !== "build") {
    // Pull requests run the mac and cross-platform jobs only for their inputs;
    // main runs them for every client change.
    const full = options.get("event") !== "pull_request" && changed;
    outputs.computer_use = full || computerUseCiChanged(files);
    outputs.electron = full || electronCiChanged(files);
    outputs.synch = full || synchCiChanged(files);
    outputs.storybook = all || full || storybookChanged(files);
    outputs.workflows = all || workflowCiChanged(files);
  }
  outputs.website = all || websiteChanged(files);
  for (const [key, value] of Object.entries(outputs)) {
    await writeGitHubOutput(output, key, String(value));
  }
  console.log(
    `Client CI ${changed ? "required" : "not required"} for ${files.length} changed file(s).`
  );
} else if (command === "gate") {
  let needs;
  try {
    needs = JSON.parse(process.env.CLIENT_CI_NEEDS ?? "");
  } catch {
    finish(["CLIENT_CI_NEEDS must contain the GitHub Actions needs JSON."]);
  }
  finish(
    validateClientGate(needs, { fullE2e: process.env.CLIENT_CI_FULL_E2E !== "false" }),
    "Required Client CI passed."
  );
} else {
  finish(["Usage: client-ci.mjs <changes|gate>."]);
}

function parseOptions(values) {
  const options = new Map();
  for (let index = 0; index < values.length; index += 2) {
    const key = values[index]?.replace(/^--/, "");
    const value = values[index + 1];
    if (key && value) options.set(key, value);
  }
  return options;
}

function finish(failures, successMessage) {
  if (failures.length > 0) {
    console.error("Client CI failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }
  if (successMessage) console.log(successMessage);
}
