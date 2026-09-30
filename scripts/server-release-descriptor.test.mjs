import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  ARTIFACT_TARGETS,
  DESCRIPTOR_FILENAME,
  generateDescriptor,
  readDescriptor,
  selectArtifact,
  validateDescriptor,
  verifyBundledArtifacts,
} from "./lib/server-release-descriptor.mjs";

const BUILD_ID = "a".repeat(40);
const fixture = () => {
  const root = mkdtempSync(join(tmpdir(), "comma-release-descriptor-"));
  for (const target of ARTIFACT_TARGETS) {
    const directory = join(root, target.component, target.platform);
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, target.artifact), `${target.component}:${target.platform}:${target.artifact}\n`);
  }
  const descriptor = generateDescriptor({
    root,
    serverBuildId: BUILD_ID,
    agentVMMReleaseId: "agent-vmm-release-1",
    baseUrl: "https://comma-release.example/server-install-artifacts",
  });
  writeFileSync(join(root, DESCRIPTOR_FILENAME), `${JSON.stringify(descriptor)}\n`);
  return { root, descriptor };
};

test("canonical descriptor verifies exact bundled bytes and selects one target", () => {
  const { root, descriptor } = fixture();
  try {
    assert.deepEqual(verifyBundledArtifacts(root, readDescriptor(join(root, DESCRIPTOR_FILENAME))), descriptor);
    assert.equal(selectArtifact(descriptor, "agent-vmm-host", "darwin-arm64").component, "agent-vmm-host");
    assert.equal(selectArtifact(descriptor, "agent-vmm-host", "darwin-arm64").release_id, "agent-vmm-release-1");
    assert.throws(() => selectArtifact(descriptor, "agent-vmm-host", "linux-arm64"), /no exact artifact/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("reader fails closed on unknown fields, duplicates, malformed values, and mutable URLs", () => {
  const { root, descriptor } = fixture();
  try {
    const cases = [
      [() => ({ ...descriptor, channel: "stable" }), /unknown field channel/],
      [() => ({ ...descriptor, artifacts: [...descriptor.artifacts, descriptor.artifacts[0]] }), /duplicate artifact/],
      [() => ({ ...descriptor, artifacts: descriptor.artifacts.map((entry, index) => index ? entry : { ...entry, platform: "plan9-amd64" }) }), /unknown artifact/],
      [() => ({ ...descriptor, artifacts: descriptor.artifacts.map((entry, index) => index ? entry : { ...entry, source: entry.source.replace(`/releases/${BUILD_ID}/`, "/latest/") }) }), /immutable target URL/],
      [() => ({ ...descriptor, artifacts: descriptor.artifacts.map((entry, index) => index ? entry : { ...entry, size: 0 }) }), /invalid size/],
      [() => ({ ...descriptor, artifacts: descriptor.artifacts.map((entry, index) => index ? entry : { ...entry, sha256: "0" }) }), /invalid sha256/],
      [() => ({ ...descriptor, artifacts: descriptor.artifacts.map((entry, index) => index ? entry : { ...entry, release_id: "" }) }), /invalid release_id/],
    ];
    for (const [mutate, pattern] of cases) assert.throws(() => validateDescriptor(mutate()), pattern);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("bundled byte mutation is detected without consulting transport metadata", () => {
  const { root, descriptor } = fixture();
  try {
    const target = ARTIFACT_TARGETS[0];
    const path = join(root, target.component, target.platform, target.artifact);
    const original = readFileSync(path);
    writeFileSync(path, Buffer.from(original.map((byte) => byte ^ 1)));
    assert.throws(() => verifyBundledArtifacts(root, descriptor), /sha256 mismatch/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("missing descriptor and missing bundled artifact fail closed", () => {
  const { root, descriptor } = fixture();
  try {
    assert.throws(() => readDescriptor(join(root, "missing.json")), /cannot read release descriptor/);
    const target = ARTIFACT_TARGETS.at(-1);
    rmSync(join(root, target.component, target.platform, target.artifact));
    assert.throws(() => verifyBundledArtifacts(root, descriptor), /missing bundled artifact/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("bundled symlinks are rejected even when their target bytes match", () => {
  const { root, descriptor } = fixture();
  try {
    const target = ARTIFACT_TARGETS[0];
    const path = join(root, target.component, target.platform, target.artifact);
    const real = `${path}.real`;
    writeFileSync(real, readFileSync(path));
    rmSync(path);
    symlinkSync(real, path);
    assert.throws(() => verifyBundledArtifacts(root, descriptor), /not a regular file/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("descriptor symlinks are rejected", () => {
  const { root } = fixture();
  try {
    const path = join(root, DESCRIPTOR_FILENAME);
    const real = `${path}.real`;
    writeFileSync(real, readFileSync(path));
    rmSync(path);
    symlinkSync(real, path);
    assert.throws(() => readDescriptor(path), /bounded regular file/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("artifact directory symlinks cannot escape the workspace", () => {
  const { root, descriptor } = fixture();
  const outside = mkdtempSync(join(tmpdir(), "comma-release-outside-"));
  try {
    const target = ARTIFACT_TARGETS.at(-1);
    const platformDirectory = join(root, target.component, target.platform);
    const bytes = readFileSync(join(platformDirectory, target.artifact));
    rmSync(platformDirectory, { recursive: true });
    writeFileSync(join(outside, target.artifact), bytes);
    symlinkSync(outside, platformDirectory);
    assert.throws(() => verifyBundledArtifacts(root, descriptor), /escapes workspace/);
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

test("R2 publication creates new objects and refuses changed existing bytes", () => {
  const { root, descriptor } = fixture();
  const transport = join(root, "fake-r2");
  const fakeBin = join(root, "bin");
  const runnerTemp = join(root, "tmp");
  mkdirSync(fakeBin);
  mkdirSync(transport);
  mkdirSync(runnerTemp);
  const aws = join(fakeBin, "aws");
  writeFileSync(aws, `#!/bin/sh
set -eu
action=""
key=""
body=""
destination=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    head-object|get-object|put-object) action="$1" ;;
    --key) shift; key="$1" ;;
    --body) shift; body="$1" ;;
    --endpoint-url|--bucket|--if-none-match) shift ;;
    s3api) ;;
    *) destination="$1" ;;
  esac
  shift
done
object="$FAKE_R2_ROOT/$key"
case "$action" in
  head-object) test -f "$object" ;;
  get-object)
    cp "$object" "$destination"
    ;;
  put-object) mkdir -p "$(dirname "$object")"; test ! -e "$object"; cp "$body" "$object" ;;
  *) exit 2 ;;
esac
`);
  chmodSync(aws, 0o755);
  const first = descriptor.artifacts[0];
  const file = new URL(first.source).pathname.split("/").at(-1);
  const key = join("server-install-artifacts", "releases", BUILD_ID, first.component, first.platform, file);
  try {
    const env = {
      ...process.env,
      PATH: `${fakeBin}:${process.env.PATH}`,
      RUNNER_TEMP: runnerTemp,
      FAKE_R2_ROOT: transport,
      CLOUDFLARE_R2_ACCOUNT_ID: "test",
      CLOUDFLARE_R2_BUCKET: "test",
      AWS_ACCESS_KEY_ID: "test",
      AWS_SECRET_ACCESS_KEY: "test",
    };
    const descriptorPath = join(root, DESCRIPTOR_FILENAME);
    const escaped = structuredClone(descriptor);
    escaped.artifacts[0].source = escaped.artifacts[0].source.replace("/releases/", "/%2e%2e/releases/");
    writeFileSync(descriptorPath, JSON.stringify(escaped));
    const pathEscape = spawnSync("bash", [join(import.meta.dirname, "publish-server-install-artifacts.sh"), root], {
      encoding: "utf8",
      env,
    });
    assert.notEqual(pathEscape.status, 0);
    assert.match(pathEscape.stderr, /immutable target URL/);
    writeFileSync(descriptorPath, JSON.stringify(descriptor));

    const published = spawnSync("bash", [join(import.meta.dirname, "publish-server-install-artifacts.sh"), root], {
      encoding: "utf8",
      env,
    });
    assert.equal(published.status, 0, published.stderr);

    writeFileSync(join(transport, key), "transport was mutated\n");
    const changed = spawnSync("bash", [join(import.meta.dirname, "publish-server-install-artifacts.sh"), root], {
      encoding: "utf8",
      env,
    });
    assert.notEqual(changed.status, 0);
    assert.match(changed.stderr, /immutable R2 object differs/);

  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
