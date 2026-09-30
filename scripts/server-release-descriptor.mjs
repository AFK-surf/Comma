#!/usr/bin/env node
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  DESCRIPTOR_FILENAME,
  generateDescriptor,
  publicationEntries,
  readDescriptor,
  selectArtifact,
  verifyBundledArtifacts,
} from "./lib/server-release-descriptor.mjs";

const fail = (message) => {
  process.stderr.write(`server-release-descriptor: ${message}\n`);
  process.exit(1);
};

const options = new Map();
for (let index = 3; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith("--") || value === undefined) fail("invalid arguments");
  options.set(key.slice(2), value);
}

try {
  const command = process.argv[2];
  const root = resolve(options.get("root") ?? "");
  const descriptorPath = resolve(options.get("descriptor") ?? root, options.has("descriptor") ? "" : DESCRIPTOR_FILENAME);
  if (command === "generate") {
    const descriptor = generateDescriptor({
      root,
      serverBuildId: options.get("server-build-id"),
      agentVMMReleaseId: options.get("agent-vmm-release-id"),
      baseUrl: options.get("base-url"),
    });
    writeFileSync(descriptorPath, `${JSON.stringify(descriptor, null, 2)}\n`);
    verifyBundledArtifacts(root, descriptor);
    process.stdout.write(`${descriptorPath}\n`);
  } else if (command === "verify") {
    verifyBundledArtifacts(root, readDescriptor(descriptorPath));
    process.stdout.write("server-release-descriptor-valid\n");
  } else if (command === "select") {
    const descriptor = readDescriptor(descriptorPath);
    process.stdout.write(`${JSON.stringify(selectArtifact(descriptor, options.get("component"), options.get("platform"), options.get("artifact")))}\n`);
  } else if (command === "publication-list") {
    const descriptor = readDescriptor(descriptorPath);
    for (const entry of publicationEntries(root, descriptor)) {
      process.stdout.write(`${entry.source}\t${entry.sha256}\t${entry.path}\n`);
    }
  } else if (command === "server-build-id") {
    process.stdout.write(`${readDescriptor(descriptorPath).server_build_id}\n`);
  } else {
    fail("command must be generate, verify, select, publication-list, or server-build-id");
  }
} catch (error) {
  fail(error.message);
}
