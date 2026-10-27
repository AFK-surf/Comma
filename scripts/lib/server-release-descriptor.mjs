import { createHash } from "node:crypto";
import { lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";

export const DESCRIPTOR_FILENAME = "release-descriptor.json";

export const ARTIFACT_TARGETS = Object.freeze([
  { component: "runner", platform: "darwin-amd64", artifact: "mac-mini-provisioner" },
  { component: "runner", platform: "darwin-arm64", artifact: "mac-mini-provisioner" },
  { component: "salix-connect", platform: "linux-amd64", artifact: "salix-connect" },
  { component: "salix-connect", platform: "linux-arm64", artifact: "salix-connect" },
  { component: "salix-connect", platform: "darwin-amd64", artifact: "salix-connect" },
  { component: "salix-connect", platform: "darwin-arm64", artifact: "salix-connect" },
  { component: "agent-vmm-host", platform: "darwin-arm64", artifact: "Agent-VMM-Host.zip" },
  { component: "agent-vmm-host", platform: "linux-arm64", artifact: "Agent-VMM-Host.tar.gz" },
  { component: "computer-use-helper", platform: "darwin-amd64", artifact: "comma-computer-use.tar.gz" },
  { component: "computer-use-helper", platform: "darwin-arm64", artifact: "comma-computer-use.tar.gz" },
]);

const TARGET_BY_KEY = new Map(
  ARTIFACT_TARGETS.map((target) => [`${target.component}:${target.platform}:${target.artifact}`, target]),
);
const ROOT_FIELDS = new Set(["server_build_id", "artifacts"]);
const ENTRY_FIELDS = new Set([
  "component",
  "platform",
  "artifact",
  "release_id",
  "source",
  "sha256",
  "size",
]);
const SHA256 = /^[0-9a-f]{64}$/;
const BUILD_ID = /^[0-9a-f]{40}$/;
const RELEASE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const PRIMARY_ARTIFACT = new Map(
  ARTIFACT_TARGETS.map(({ component, platform, artifact }) => [`${component}:${platform}`, artifact]),
);
// Missing Linux delivery must not disable an existing Mac installation surface.
const REQUIRED_TARGETS = ARTIFACT_TARGETS.filter(
  ({ component, platform }) => component !== "agent-vmm-host" || platform !== "linux-arm64",
).map(({ component, platform, artifact }) => `${component}:${platform}:${artifact}`);

const assertObject = (value, label) => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
};

const rejectUnknownFields = (value, allowed, label) => {
  for (const field of Object.keys(value)) {
    if (!allowed.has(field)) throw new Error(`${label} has unknown field ${field}`);
  }
};

const artifactPath = (root, target) =>
  resolve(root, target.component, target.platform, target.artifact);

const sha256File = (path) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");

const assertRegularArtifact = (root, path) => {
  if (!lstatSync(path).isFile()) throw new Error("not a regular file");
  const fromRoot = relative(realpathSync(root), realpathSync(path));
  if (fromRoot === ".." || fromRoot.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) || isAbsolute(fromRoot)) {
    throw new Error("artifact path escapes workspace");
  }
};

const validateSource = (source, buildId, target) => {
  if (typeof source !== "string") throw new Error("artifact source must be a string");
  if (source.includes("%")) throw new Error(`artifact source is not the immutable target URL: ${source}`);
  let url;
  try {
    url = new URL(source);
  } catch {
    throw new Error(`artifact source is not a URL: ${source}`);
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new Error(`artifact source must be a plain HTTPS URL: ${source}`);
  }
  const expectedSuffix = `/releases/${buildId}/${target.component}/${target.platform}/${target.artifact}`;
  if (!url.pathname.endsWith(expectedSuffix) || url.pathname.includes("/latest/") || url.pathname.includes("%")) {
    throw new Error(`artifact source is not the immutable target URL: ${source}`);
  }
};

export function readDescriptor(path) {
  let descriptor;
  try {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.size > 262_144) throw new Error("descriptor is not a bounded regular file");
    descriptor = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`cannot read release descriptor: ${error.message}`);
  }
  return validateDescriptor(descriptor);
}

export function validateDescriptor(descriptor) {
  assertObject(descriptor, "release descriptor");
  rejectUnknownFields(descriptor, ROOT_FIELDS, "release descriptor");
  if (!BUILD_ID.test(descriptor.server_build_id ?? "")) {
    throw new Error("server_build_id must be a full lowercase commit SHA");
  }
  if (!Array.isArray(descriptor.artifacts)) {
    throw new Error("release descriptor artifacts must be an array");
  }

  const seen = new Set();
  for (const [index, entry] of descriptor.artifacts.entries()) {
    assertObject(entry, `artifact ${index}`);
    rejectUnknownFields(entry, ENTRY_FIELDS, `artifact ${index}`);
    const key = `${entry.component}:${entry.platform}:${entry.artifact}`;
    const target = TARGET_BY_KEY.get(key);
    if (!target) throw new Error(`unknown artifact target ${key}`);
    if (seen.has(key)) throw new Error(`duplicate artifact target ${key}`);
    seen.add(key);
    validateSource(entry.source, descriptor.server_build_id, target);
    if (!RELEASE_ID.test(entry.release_id ?? "")) throw new Error(`${key} has invalid release_id`);
    if (!SHA256.test(entry.sha256 ?? "")) throw new Error(`${key} has invalid sha256`);
    if (!Number.isSafeInteger(entry.size) || entry.size <= 0) {
      throw new Error(`${key} has invalid size`);
    }
  }
  const missing = REQUIRED_TARGETS.filter((key) => !seen.has(key));
  if (missing.length) {
    throw new Error(`release descriptor is missing targets: ${missing.join(", ")}`);
  }
  return descriptor;
}

export function verifyBundledArtifacts(root, descriptor) {
  validateDescriptor(descriptor);
  for (const entry of descriptor.artifacts) {
    const key = `${entry.component}:${entry.platform}:${entry.artifact}`;
    const target = TARGET_BY_KEY.get(key);
    const path = artifactPath(root, target);
    let size;
    try {
      assertRegularArtifact(root, path);
      size = statSync(path).size;
    } catch (error) {
      throw new Error(`missing bundled artifact ${key}: ${error.message}`);
    }
    if (size !== entry.size) throw new Error(`${key} size mismatch`);
    if (sha256File(path) !== entry.sha256) {
      throw new Error(`${key} sha256 mismatch`);
    }
  }
  return descriptor;
}

export function selectArtifact(descriptor, component, platform, artifact = PRIMARY_ARTIFACT.get(`${component}:${platform}`)) {
  validateDescriptor(descriptor);
  return Object.freeze({ ...findEntry(descriptor, component, platform, artifact) });
}

const findEntry = (descriptor, component, platform, artifact) => {
  const matches = descriptor.artifacts.filter(
    (entry) =>
      entry.component === component && entry.platform === platform && entry.artifact === artifact,
  );
  if (matches.length !== 1) throw new Error(`no exact artifact target ${component}:${platform}`);
  return matches[0];
};

export function publicationEntries(root, descriptor) {
  verifyBundledArtifacts(root, descriptor);
  return descriptor.artifacts.map((entry) => {
    const key = `${entry.component}:${entry.platform}:${entry.artifact}`;
    return { ...entry, path: artifactPath(root, TARGET_BY_KEY.get(key)) };
  });
}

// The darwin connector is reused across server builds while its inputs are unchanged, so it
// reports its own release id; the target must carry that id or every Mac looks out of date.
// The Computer Use helper is reused the same way and carries the id of its stored set.
export function generateDescriptor({
  root,
  serverBuildId,
  agentVMMReleaseId,
  agentVMMLinuxReleaseId,
  darwinSalixConnectReleaseId = serverBuildId,
  computerUseHelperReleaseId = serverBuildId,
  baseUrl,
}) {
  if (!BUILD_ID.test(serverBuildId ?? "")) {
    throw new Error("server build id must be a full lowercase commit SHA");
  }
  if (!RELEASE_ID.test(agentVMMReleaseId ?? "")) {
    throw new Error("Agent VMM release id must be a stable identifier");
  }
  if (!RELEASE_ID.test(agentVMMLinuxReleaseId ?? "")) {
    throw new Error("Linux Agent VMM release id must be a stable identifier");
  }
  if (!RELEASE_ID.test(darwinSalixConnectReleaseId ?? "")) {
    throw new Error("darwin salix-connect release id must be a stable identifier");
  }
  if (!RELEASE_ID.test(computerUseHelperReleaseId ?? "")) {
    throw new Error("Computer Use helper release id must be a stable identifier");
  }
  const releaseId = (target) => {
    if (target.component === "agent-vmm-host") {
      return target.platform === "linux-arm64" ? agentVMMLinuxReleaseId : agentVMMReleaseId;
    }
    if (target.component === "salix-connect" && target.platform.startsWith("darwin-")) return darwinSalixConnectReleaseId;
    if (target.component === "computer-use-helper") return computerUseHelperReleaseId;
    return serverBuildId;
  };
  let base;
  try {
    base = new URL(baseUrl);
  } catch {
    throw new Error("base URL must be a valid URL");
  }
  if (base.protocol !== "https:" || base.search || base.hash) {
    throw new Error("base URL must be HTTPS without query or fragment");
  }
  const prefix = base.toString().replace(/\/$/, "");
  const artifacts = ARTIFACT_TARGETS.map((target) => {
    const path = artifactPath(root, target);
    assertRegularArtifact(root, path);
    const entry = {
      component: target.component,
      platform: target.platform,
      artifact: target.artifact,
      release_id: releaseId(target),
      source: `${prefix}/releases/${serverBuildId}/${target.component}/${target.platform}/${target.artifact}`,
      sha256: sha256File(path),
      size: statSync(path).size,
    };
    return entry;
  });
  return validateDescriptor({ server_build_id: serverBuildId, artifacts });
}
