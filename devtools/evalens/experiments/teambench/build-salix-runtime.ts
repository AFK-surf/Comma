#!/usr/bin/env bun

import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const experimentRoot = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(experimentRoot, "../../../..");
const dockerfile = path.join(experimentRoot, "salix-runtime.Dockerfile");
const image = process.env.TEAMBENCH_RUNTIME_IMAGE ?? "evalens-teambench-salix:local";
// The container runs the station release for Linux on this machine's architecture.
const platform = process.arch === "arm64" ? "linux-arm64" : "linux-x64";

async function run(command: string[]) {
  const handle = Bun.spawn(command, {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
    env: process.env,
  });
  const exitCode = await handle.exited;
  if (exitCode !== 0) process.exit(exitCode);
}

const station = mkdtempSync(path.join(os.tmpdir(), "evalens-teambench-station-"));
try {
  await run([
    "sh",
    path.join(repositoryRoot, "systems/station/scripts/bundle.sh"),
    station,
    platform,
  ]);
  await run(["docker", "build", "--file", dockerfile, "--tag", image, station]);
} finally {
  rmSync(station, { recursive: true, force: true });
}
console.log(`Built ${image}`);
