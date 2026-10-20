#!/usr/bin/env node
// Moves the Claude Code and Codex CLIs that Compute runtime images install to
// their latest npm releases: systems/runtime-images/runtime-dependencies.lock.json
// and the Claude version the Connector accepts for native login and import
// (runtimeAuthClaudeVersion). Pi is left alone; its releases change the SDK the
// Connector drives and need a reviewed upgrade.
//
// Prints a JSON summary of what changed. `--check` changes nothing and exits 1
// when a newer release exists. The weekly Runtime CLI updates workflow runs this
// and opens a pull request with the result.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const lockPath = join(root, "systems/runtime-images/runtime-dependencies.lock.json");
const claudeAuthPath = join(root, "systems/connector/salix-connect/runtime_auth_claude.go");
const registry = "https://registry.npmjs.org";

/** The lock entries of one CLI: its main package and per-platform packages. */
export const clis = {
  claude: {
    package: "@anthropic-ai/claude-code",
    entries: [
      { key: "claude", field: "", package: "@anthropic-ai/claude-code" },
      { key: "claude", field: "platform", package: "@anthropic-ai/claude-code-linux-arm64" },
      { key: "claudeAmd64", field: "", package: "@anthropic-ai/claude-code-linux-x64" },
    ],
  },
  codex: {
    package: "@openai/codex",
    entries: [{ key: "codex", field: "", package: "@openai/codex" }],
  },
};

const fieldName = (prefix, name) =>
  prefix ? prefix + name[0].toUpperCase() + name.slice(1) : name;

/**
 * The lock with `name` moved to `version`, given each package's npm `dist`
 * ({ tarball, integrity }) for that version.
 */
export function updateLock(lock, name, version, dists) {
  const next = structuredClone(lock);
  for (const entry of clis[name].entries) {
    const dist = dists[entry.package];
    if (!dist?.tarball || !dist.integrity?.startsWith("sha512-"))
      throw new Error(`${entry.package}@${version} has no sha512 tarball`);
    const target = next[entry.key];
    if (!entry.field) target.version = version;
    target[fieldName(entry.field, "tarball")] = dist.tarball;
    target[fieldName(entry.field, "integrity")] = dist.integrity;
  }
  return next;
}

/** The Go source with runtimeAuthClaudeVersion set to `version`. */
export function updateClaudeAuthVersion(source, version) {
  const pattern = /^const runtimeAuthClaudeVersion = "[^"]+"$/m;
  if (!pattern.test(source)) throw new Error("runtimeAuthClaudeVersion not found");
  return source.replace(pattern, `const runtimeAuthClaudeVersion = "${version}"`);
}

async function npm(path) {
  const response = await fetch(`${registry}/${path}`);
  if (!response.ok) throw new Error(`npm ${path}: ${response.status}`);
  return response.json();
}

async function main() {
  const check = process.argv.includes("--check");
  let lock = JSON.parse(readFileSync(lockPath, "utf8"));
  let claudeAuth = readFileSync(claudeAuthPath, "utf8");
  const changes = [];
  for (const [name, cli] of Object.entries(clis)) {
    const latest = (await npm(`${cli.package}/latest`)).version;
    const current = lock[cli.entries[0].key].version;
    if (latest === current) continue;
    changes.push({ name, package: cli.package, from: current, to: latest });
    if (check) continue;
    const dists = {};
    for (const entry of cli.entries) {
      const pkg = entry.package;
      dists[pkg] = (await npm(`${pkg}/${latest}`)).dist;
    }
    lock = updateLock(lock, name, latest, dists);
    if (name === "claude") claudeAuth = updateClaudeAuthVersion(claudeAuth, latest);
  }
  if (!check && changes.length) {
    writeFileSync(lockPath, JSON.stringify(lock, null, 2) + "\n");
    writeFileSync(claudeAuthPath, claudeAuth);
  }
  process.stdout.write(JSON.stringify(changes) + "\n");
  if (check && changes.length) process.exitCode = 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
