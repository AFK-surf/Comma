#!/usr/bin/env bun

import path from "node:path";
import { fileURLToPath } from "node:url";

const experimentRoot = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(experimentRoot, "../../../..");
const connectorRoot = path.join(repositoryRoot, "systems/connector/salix-connect");
const dockerfile = path.join(experimentRoot, "salix-runtime.Dockerfile");
const image = process.env.TEAMBENCH_RUNTIME_IMAGE ?? "evalens-teambench-salix:local";

const processHandle = Bun.spawn(
  ["docker", "build", "--file", dockerfile, "--tag", image, connectorRoot],
  { stdin: "inherit", stdout: "inherit", stderr: "inherit", env: process.env }
);
const exitCode = await processHandle.exited;
if (exitCode !== 0) process.exit(exitCode);
console.log(`Built ${image}`);
