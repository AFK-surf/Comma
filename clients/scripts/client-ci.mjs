#!/usr/bin/env node
import { resolve } from "node:path";
import {
  clientBuildChanged,
  clientCiChanged,
  computerUseCiChanged,
  gitChangedFiles,
  validateClientGate,
  writeGitHubOutput,
  websiteChanged,
} from "./client-ci-lib.mjs";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const [command, ...args] = process.argv.slice(2);

if (command === "changes") {
  const options = parseOptions(args);
  const base = options.get("base");
  const head = options.get("head");
  const output = process.env.GITHUB_OUTPUT;
  if (!base || !head || !output) {
    finish(["changes requires --base, --head, and GITHUB_OUTPUT."]);
  }
  const files = gitChangedFiles(base, head, repositoryRoot);
  const changed =
    options.get("scope") === "build"
      ? clientBuildChanged(files)
      : clientCiChanged(files);
  await writeGitHubOutput(output, "client", String(changed));
  if (options.get("scope") !== "build") {
    await writeGitHubOutput(
      output,
      "computer_use",
      String(computerUseCiChanged(files))
    );
  }
  await writeGitHubOutput(output, "website", String(websiteChanged(files)));
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
  finish(validateClientGate(needs), "Required Client CI passed.");
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
