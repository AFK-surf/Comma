#!/usr/bin/env node

import { appendFileSync } from "node:fs";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const VALID_RELEASE_KINDS = new Set([
  "gateway_only",
  "breaking_connector",
  "breaking_protocol",
  "sandbox_image",
]);
const CANDIDATE_PROPAGATION_ATTEMPTS = 10;
const CANDIDATE_PROPAGATION_INTERVAL_MS = 1_000;

export function inferWorkerReleaseKind(event, fallback = "gateway_only") {
  const inputKind = event?.inputs?.worker_release_kind;
  if (typeof inputKind === "string" && inputKind.length > 0) {
    assertReleaseKind(inputKind);
    return inputKind;
  }

  const files = new Set();
  for (const commit of event?.commits || []) {
    for (const key of ["added", "modified", "removed"]) {
      for (const file of commit?.[key] || []) files.add(file);
    }
  }

  const changedFiles = [...files];
  const hasConnector = changedFiles.some((file) =>
    file.startsWith("systems/connector/salix-connect/"),
  );
  const hasSandboxImage = changedFiles.some(
    (file) =>
      file === "systems/cloudflare/salix-vm-gateway/Dockerfile" ||
      file === "systems/cloudflare/salix-vm-gateway/entrypoint.sh" ||
      file.endsWith("/Dockerfile"),
  );

  if (hasSandboxImage) return "sandbox_image";
  if (hasConnector) return "breaking_connector";
  assertReleaseKind(fallback);
  return fallback;
}

export function resolveReleaseFacts({
  event,
  sha,
  target,
  runId,
  runAttempt,
  fallbackKind = "gateway_only",
  ref,
}) {
  if (!sha) throw new Error("GITHUB_SHA is required");
  if (!target) throw new Error("target is required");
  if (!runId) throw new Error("GITHUB_RUN_ID is required");
  if (!runAttempt) throw new Error("GITHUB_RUN_ATTEMPT is required");

  const shortSha = sha.slice(0, 12);
  const workerReleaseKind = inferWorkerReleaseKind(event, fallbackKind);
  if (event?.inputs) {
    const requiredRef =
      target === "staging" ? "refs/heads/main" : "refs/heads/prod";
    if (ref !== requiredRef) {
      throw new Error(`Manual ${target} release requires ${requiredRef}`);
    }
    if (workerReleaseKind !== "gateway_only") {
      throw new Error(
        "Container release is blocked until the existing Sandbox data is preserved or its exact disposal is approved",
      );
    }
  }
  const publishMode =
    workerReleaseKind === "gateway_only" ? "candidate_worker" : "check_only";
  return {
    gateway_build_id: shortSha,
    connector_image_version: `salix-connect-${shortSha}`,
    tag: `ci-${target}-${runId}-${runAttempt}`,
    worker_release_kind: workerReleaseKind,
    publish_mode: publishMode,
  };
}

export function findVersionIdByTag(payload, tag) {
  if (!tag) throw new Error("tag is required");

  for (const node of walkObjects(payload)) {
    const id = firstString(node.id, node.version_id, node.versionId);
    const versionTag = firstString(node.tag, node.version_tag, node.versionTag);
    if (id && versionTag === tag) return id;
  }

  throw new Error(`Could not find uploaded Worker version with tag ${tag}`);
}

export function findUploadedVersionId(output) {
  const text = String(output || "");
  const uuid =
    "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
  const patterns = [
    new RegExp(`Worker\\s+Version\\s+ID:\\s*(${uuid})`, "i"),
    new RegExp(`Version\\s+ID:\\s*(${uuid})`, "i"),
    new RegExp(`\\b(${uuid})\\b`, "i"),
  ];

  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match) return match[1];
  }

  throw new Error(
    "Could not find uploaded Worker version id in wrangler upload output",
  );
}

export function resolveActiveVersionId(payload) {
  const candidates = [];

  for (const node of walkObjects(payload)) {
    const id = firstString(node.version_id, node.versionId, node.id);
    const percentage = normalizePercentage(
      node.percentage ?? node.percent ?? node.traffic ?? node.weight,
    );
    if (id && Number.isFinite(percentage)) {
      candidates.push({ id, percentage });
    }
  }

  const active =
    candidates.find((candidate) => candidate.percentage === 100) ||
    candidates.find((candidate) => candidate.percentage > 0);
  if (!active) {
    throw new Error(
      "Could not find the currently active Worker version in deployments status JSON",
    );
  }
  return active.id;
}

export function connectorImageVersionFromHealthz(payload, activeId) {
  if (payload?.worker_version_id !== activeId) {
    throw new Error("Active Gateway version changed during release");
  }
  const version = payload.connector_image_version;
  if (typeof version !== "string" || version.length === 0) {
    throw new Error("Active Gateway has no Connector image version");
  }
  return version;
}

export function validateHealthzPayload(payload, expected) {
  const failures = [];
  if (payload.worker_version_id !== expected.candidateId) {
    failures.push(
      `worker_version_id=${payload.worker_version_id}, expected ${expected.candidateId}`,
    );
  }
  if (payload.gateway_build_id !== expected.gatewayBuildId) {
    failures.push(
      `gateway_build_id=${payload.gateway_build_id}, expected ${expected.gatewayBuildId}`,
    );
  }
  if (payload.connector_image_version !== expected.connectorImageVersion) {
    failures.push(
      `connector_image_version=${payload.connector_image_version}, expected ${expected.connectorImageVersion}`,
    );
  }
  return failures;
}

export function salixReleaseRequest(
  configJson,
  { candidateId, releaseId, releaseKind, imageRevision, imageDigest },
) {
  const config = JSON.parse(configJson || "{}");
  const api = stripTrailingSlashes(config?.web?.api_base_url || "");
  const token = config?.web?.api_token || "";
  if (!api || !token) {
    throw new Error(
      "SALIX_CONFIG_JSON must include web.api_base_url and web.api_token",
    );
  }

  assertReleaseKind(releaseKind);
  return {
    api,
    token,
    body: {
      desired_worker_version_id: candidateId,
      worker_release_id: releaseId,
      worker_release_kind: releaseKind,
      ...(imageRevision ? { last_sandbox_image_revision: imageRevision } : {}),
      ...(imageDigest ? { last_sandbox_image_digest: imageDigest } : {}),
    },
  };
}

export function containerApplicationId(applications, expectedName) {
  if (!Array.isArray(applications)) {
    throw new Error("Cloudflare Container application list is not an array");
  }
  const matches = applications.filter((app) => app?.name === expectedName);
  if (matches.length !== 1 || !firstString(matches[0]?.id)) {
    throw new Error(`Expected one Container application named ${expectedName}`);
  }
  return matches[0].id;
}

export function optionalContainerApplicationId(applications, expectedName) {
  if (!Array.isArray(applications)) {
    throw new Error("Cloudflare Container application list is not an array");
  }
  const matches = applications.filter((app) => app?.name === expectedName);
  if (matches.length === 0) return "";
  if (matches.length !== 1 || !firstString(matches[0]?.id)) {
    throw new Error(`Container application ${expectedName} is ambiguous`);
  }
  return matches[0].id;
}

export function containerApplicationDigest(applications, expectedName) {
  const id = containerApplicationId(applications, expectedName);
  const application = applications.find((item) => item.id === id);
  const digest = application.image?.match(/@(?<digest>sha256:[0-9a-f]{64})$/)?.groups?.digest;
  if (!digest) {
    throw new Error(`Container application ${expectedName} has no image digest`);
  }
  return digest;
}

export function checkImageReleasePage(page) {
  if (!Array.isArray(page?.data)) {
    throw new Error("Image release Workload page is invalid");
  }
  for (const record of page.data) {
    if (!firstString(record?.group_id) || !Number.isInteger(record?.gateway_attempt_count)) {
      throw new Error("Image release Workload record is incomplete");
    }
    if (record.provider === "cloudflare" &&
        (!firstString(record.resource_name) || typeof record.archive_recorded !== "boolean" ||
         !["cf-standard-1", "cf-standard-2"].includes(record.profile_key))) {
      throw new Error("Image release Cloudflare Workload record is incomplete");
    }
    if (record.gateway_attempt_count !== 0) {
      throw new Error(
        `Group ${record.group_id} has an unsettled Gateway start`,
      );
    }
    if (record.provider === "cloudflare" && record.status === "archiving") {
      throw new Error(`Group ${record.group_id} has an unfinished archive`);
    }
  }
  if (page.next_cursor !== null && typeof page.next_cursor !== "string") {
    throw new Error("Image release Workload cursor is invalid");
  }
  return page.next_cursor;
}

export function requireInactiveContainerInstances(instances, workloads = [], ownedProbeId = null) {
  if (!Array.isArray(instances)) {
    throw new Error("Cloudflare Container instance list is not an array");
  }
  const owners = new Map(workloads.filter((record) => record.provider === "cloudflare")
    .map((record) => [record.resource_name, record]));
  const objects = instances.filter((instance) => instance.kind === "durable_object");
  const unsafe = instances.filter((instance) => {
    if (instance?.kind === "durable_object") {
      if (instance.state === "inactive") return false;
      if (!["stopped", "failed"].includes(instance.state)) return true;
      if (instance.name === ownedProbeId && instance.state === "stopped") return false;
      return owners.get(instance.name)?.archive_recorded !== true;
    }
    if (instance?.kind !== "instance" || !["stopped", "failed"].includes(instance.state)) {
      return true;
    }
    const matches = objects.filter((object) => object.deployment_id === instance.id);
    if (matches.length === 1 && matches[0].name === ownedProbeId &&
        instance.state === "stopped") return false;
    return matches.length !== 1 || owners.get(matches[0].name)?.archive_recorded !== true;
  });
  if (unsafe.length > 0) {
    const samples = unsafe.slice(0, 8).map((instance) =>
      `${instance?.id || "unknown"}:${instance?.state || "unknown"}`,
    );
    throw new Error(
      `${unsafe.length} active or unknown Container instances remain: ${samples.join(", ")}`,
    );
  }
}

const SANDBOX_RUNTIME_PATHS = [
  ":(top)systems/connector/salix-connect",
  ":(top)systems/cloudflare/salix-vm-gateway/Dockerfile",
  ":(top)systems/cloudflare/salix-vm-gateway/entrypoint.sh",
  ":(top)systems/cloudflare/salix-vm-gateway/wrangler.jsonc",
  ":(top)systems/cloudflare/salix-vm-gateway/scripts/build-connector.sh",
];

export function sameSandboxRuntimeSources(previousRevision, revision, cwd = process.cwd()) {
  if (![previousRevision, revision].every((value) => /^[0-9a-f]{40}$/.test(value || ""))) {
    return false;
  }
  if (previousRevision === revision) return true;
  const git = (args) => spawnSync("git", args, { cwd, encoding: "utf8", maxBuffer: 2_000_000 });
  if (git(["merge-base", "--is-ancestor", previousRevision, revision]).status !== 0) return false;
  const changed = git(["diff", "--name-only", "-z", previousRevision, revision, "--", ...SANDBOX_RUNTIME_PATHS]);
  if (changed.status !== 0) return false;
  if (changed.stdout.split("\0").some((path) => path &&
      !path.endsWith("_test.go") && !path.endsWith(".test.mjs"))) {
    return false;
  }
  return true;
}

export function imageReleasePlan(current, revision, maintenance, maintenanceId, sameRuntimeSources) {
  if (!/^[0-9a-f]{40}$/.test(current.comma_source_revision || "")) {
    throw new Error("Salix did not report its deployed Comma source revision");
  }
  if (current.comma_source_revision !== revision) {
    throw new Error("Selected Comma source revision is no longer serving");
  }
  if (maintenance?.enabled === true) {
    if (maintenance.maintenance_id !== maintenanceId &&
        ["prepared", "deploying"].includes(maintenance.phase) &&
        maintenance.reason === "sandbox_image_release" &&
        current.comma_source_revision === revision) {
      return maintenance.phase === "deploying" ? "takeover" : "takeover-prepared";
    }
    if (maintenance.maintenance_id !== maintenanceId ||
        !["prepared", "deploying"].includes(maintenance.phase)) {
      throw new Error("Another VM maintenance fence owns the Container release");
    }
    return maintenance.phase === "deploying" ? "resume" : "publish";
  }
  return sameRuntimeSources ? "skip" : "publish";
}

// Pinned Wrangler's JSON modes return only the first page for these two commands.
// Read the same Container dashboard endpoints to exhaustion before making a release decision.
export async function fetchContainerPages(path, readPage = cloudflareContainerPage) {
  const startedAt = Date.now();
  const seen = new Set();
  const pages = [];
  let token = "";
  do {
    if (Date.now() - startedAt > 300_000) {
      throw new Error("Cloudflare Container inventory exceeded five minutes");
    }
    const page = await readPage(path, token);
    if (!page || !Object.hasOwn(page, "result") || !page.result_info ||
        typeof page.result_info !== "object") {
      throw new Error("Cloudflare Container inventory response is incomplete");
    }
    pages.push(page.result);
    const next = page.result_info.next_page_token;
    if (next === null || next === undefined || next === "") break;
    if (typeof next !== "string" || seen.has(next)) {
      throw new Error("Cloudflare Container inventory cursor did not advance");
    }
    seen.add(next);
    token = next;
  } while (true);
  return pages;
}

async function cloudflareContainerPage(path, token) {
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
  const apiToken = process.env.CLOUDFLARE_API_TOKEN;
  if (!accountId || !apiToken) {
    throw new Error("Cloudflare account and API token are required");
  }
  maskSecret(apiToken);
  const url = new URL(`https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountId)}/containers/dash/applications${path}`);
  url.searchParams.set("per_page", "100");
  if (token) url.searchParams.set("page_token", token);
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${apiToken}` },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(`Cloudflare Container inventory returned HTTP ${response.status}`);
  }
  const payload = await response.json();
  if (payload.success !== true) {
    throw new Error("Cloudflare Container inventory was not successful");
  }
  return payload;
}

export function flattenContainerInstances(pages) {
  const raw = pages.map((page) => {
    if (!page || !Array.isArray(page.instances) ||
        (page.durable_objects !== undefined && !Array.isArray(page.durable_objects))) {
      throw new Error("Cloudflare Container instance page is incomplete");
    }
    return [page.instances, page.durable_objects || []];
  });
  const instances = raw.flatMap(([items]) => items);
  const objects = raw.flatMap(([, items]) => items);
  const byDeployment = new Map();
  for (const instance of instances) {
    if (!firstString(instance?.id) || byDeployment.has(instance.id)) {
      throw new Error("Cloudflare Container instance identity is missing or duplicated");
    }
    byDeployment.set(instance.id, instance);
  }
  return [
    ...instances.map((instance) => ({ ...instance, kind: "instance", state: containerState(instance) })),
    ...objects.map((object) => ({
      ...object,
      kind: "durable_object",
      state: object?.deployment_id
        ? (byDeployment.has(object.deployment_id)
          ? containerState(byDeployment.get(object.deployment_id)) : "unknown")
        : "inactive",
    })),
  ];
}

function containerState(instance) {
  const status = instance?.current_placement?.status;
  const raw = status?.container_status ?? status?.health;
  if (raw === "placed") return "provisioning";
  return ["running", "failed", "stopping", "stopped", "unhealthy"].includes(raw)
    ? raw : "unknown";
}

export function runningContainerOwners(instances, workloads) {
  const owners = new Map(
    workloads.filter((record) => record.provider === "cloudflare")
      .map((record) => [record.resource_name, record]),
  );
  const objects = instances.filter((instance) => instance.kind === "durable_object");
  const active = instances.filter((instance) => instance.kind === "instance" &&
    !["stopped", "failed"].includes(instance.state));
  return active.map((instance) => {
    const matches = objects.filter((object) => object.deployment_id === instance.id);
    if (matches.length !== 1 || !matches[0].name) {
      throw new Error(`Running Container ${instance.id || "unknown"} has no exact Durable Object owner`);
    }
    const owner = owners.get(matches[0].name);
    if (!owner || !owner.group_id) {
      throw new Error(`Running Container ${matches[0].name} has no Group Workload owner`);
    }
    return owner;
  });
}

export function workloadsForApplication(instances, workloads, gatewayBaseUrl, profileKey) {
  const names = new Set(instances.filter((record) => record.kind === "durable_object")
    .map((record) => record.name).filter(Boolean));
  return workloads.filter((record) => record.profile_key === profileKey &&
    (record.provider === "cloudflare" || record.gateway_attempt_count > 0) &&
    (names.has(record.resource_name) || !record.gateway_base_url ||
      record.gateway_base_url.replace(/\/+$/, "") === gatewayBaseUrl.replace(/\/+$/, "")));
}

async function imageReleaseWorkloads(maintenanceId) {
  const records = [];
  const startedAt = Date.now();
  const seen = new Set();
  let cursor = "";
  do {
    if (Date.now() - startedAt > 300_000) {
      throw new Error("Image release Workload paging exceeded five minutes");
    }
    const page = await imageReleaseApi(maintenanceId, "workloads", cursor);
    if (!Array.isArray(page?.data)) {
      throw new Error("Image release Workload page is invalid");
    }
    records.push(...page.data);
    const next = page.next_cursor;
    if (next === null) break;
    if (!next || seen.has(next)) {
      throw new Error("Image release Workload cursor did not advance");
    }
    seen.add(next);
    cursor = next;
  } while (true);
  return records;
}

async function drainRunningContainers(maintenanceId, applicationId, profileKey) {
  const deadline = Date.now() + 75 * 60_000;
  const release = (await imageReleaseApi(maintenanceId, "status")).maintenance;
  const ownedProbeId = ownedImageProbeId(release, maintenanceId, profileKey);
  while (Date.now() < deadline) {
    const allWorkloads = await imageReleaseWorkloads(maintenanceId);
    for (const record of allWorkloads) {
      if (record.provider === "cloudflare" &&
          !["cf-standard-1", "cf-standard-2"].includes(record.profile_key)) {
        throw new Error(`Group ${record.group_id} has no resolved Container profile`);
      }
    }
    let pages = await fetchContainerPages(`/${encodeURIComponent(applicationId)}/instances`);
    let instances = flattenContainerInstances(pages);
    if (await recoverOwnedImageProbe(release, instances, {
      maintenanceId,
      applicationId,
      profileKey,
      baseUrl: process.env.SALIX_VM_GATEWAY_BASE_URL,
      secret: process.env.SALIX_VM_GATEWAY_SECRET,
    })) {
      pages = await fetchContainerPages(`/${encodeURIComponent(applicationId)}/instances`);
      instances = flattenContainerInstances(pages);
    }
    const workloads = workloadsForApplication(instances, allWorkloads,
      process.env.SALIX_VM_GATEWAY_BASE_URL, profileKey);
    const running = runningContainerOwners(instances, workloads);
    const archiving = workloads.filter((record) =>
      record.provider === "cloudflare" && record.status === "archiving");
    if (running.length === 0 && archiving.length === 0) {
      checkImageReleasePage({ data: workloads, next_cursor: null });
      requireInactiveContainerInstances(instances, workloads, ownedProbeId);
      return;
    }
    const seen = new Set();
    for (const owner of [...running, ...archiving]) {
      if (seen.has(owner.group_id)) continue;
      seen.add(owner.group_id);
      try {
        await imageReleaseApi(maintenanceId, "archive", "", {
          group_id: owner.group_id,
          resource_name: owner.resource_name,
          profile_key: owner.profile_key,
        });
      } catch (error) {
        // Active work may settle during this release. Retry until the bounded
        // release window expires; ownership and instance inventory stay fenced.
        if (!String(error).includes("archive_not_quiet") &&
            !String(error).includes("archive_worker_unavailable")) throw error;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 30_000));
  }
  throw new Error("Running Containers or unfinished archives did not settle within 75 minutes");
}

async function main(argv) {
  const [command, ...rest] = argv;
  const args = parseArgs(rest);

  switch (command) {
    case "resolve-release-facts": {
      const event = await readEventPayload();
      writeOutputs(
        resolveReleaseFacts({
          event,
          sha: process.env.GITHUB_SHA,
          target: requireArg(args, "target"),
          runId: process.env.GITHUB_RUN_ID,
          runAttempt: process.env.GITHUB_RUN_ATTEMPT,
          ref: process.env.GITHUB_REF,
          fallbackKind: args["fallback-kind"] || "gateway_only",
        }),
      );
      return;
    }

    case "active-version-from-deployment": {
      const payload = await readJsonFile(requireArg(args, "file"));
      writeOutputs({ active_id: resolveActiveVersionId(payload) });
      return;
    }

    case "active-connector-image": {
      const activeId = requireArg(args, "active-id");
      const response = await fetch(
        `${stripTrailingSlashes(requireArg(args, "base-url"))}/healthz`,
        {
          headers: {
            "Cloudflare-Workers-Version-Overrides": `${requireArg(args, "worker-name")}="${activeId}"`,
          },
          signal: AbortSignal.timeout(10_000),
        },
      );
      if (!response.ok)
        throw new Error(`Active Gateway healthz returned ${response.status}`);
      writeOutputs({
        connector_image_version: connectorImageVersionFromHealthz(
          await response.json(),
          activeId,
        ),
      });
      return;
    }

    case "version-id-from-list": {
      const payload = await readJsonFile(requireArg(args, "file"));
      writeOutputs({
        candidate_id: findVersionIdByTag(payload, requireArg(args, "tag")),
      });
      return;
    }

    case "upload-version-id-from-output": {
      const output = await readFile(requireArg(args, "file"), "utf8");
      writeOutputs({ candidate_id: findUploadedVersionId(output) });
      return;
    }

    case "verify-healthz": {
      await verifyHealthz({
        baseUrl: requireArg(args, "base-url"),
        workerName: requireArg(args, "worker-name"),
        candidateId: requireArg(args, "candidate-id"),
        gatewayBuildId: requireArg(args, "gateway-build-id"),
        connectorImageVersion: requireArg(args, "connector-image-version"),
      });
      return;
    }

    case "write-salix-release": {
      await writeSalixRelease({
        configJson: args["salix-config-json"] || process.env.SALIX_CONFIG_JSON,
        candidateId: requireArg(args, "candidate-id"),
        releaseId: requireArg(args, "release-id"),
        releaseKind: requireArg(args, "release-kind"),
        imageRevision: args["image-revision"],
        imageDigest: args["image-digest"],
      });
      return;
    }

    case "image-release-needs-publish": {
      const current = await readSalixWorkerRelease();
      const maintenance = (await imageReleaseApi(null, "status")).maintenance;
      const plan = imageReleasePlan(
        current,
        requireArg(args, "image-revision"),
        maintenance,
        requireArg(args, "maintenance-id"),
        sameSandboxRuntimeSources(current.last_sandbox_image_revision, requireArg(args, "image-revision")),
      );
      writeOutputs({
        publish_image: ["publish", "resume", "takeover", "takeover-prepared"].includes(plan) ? "true" : "false",
        resume_deploying: ["resume", "takeover"].includes(plan) ? "true" : "false",
      });
      return;
    }

    case "image-release-assert-source": {
      const current = await readSalixWorkerRelease();
      if (current.comma_source_revision !== requireArg(args, "image-revision")) {
        throw new Error("A different Comma source revision is now serving; skip this image release");
      }
      return;
    }

    case "container-application-id": {
      const applications = await readJsonFile(requireArg(args, "file"));
      const name = requireArg(args, "name");
      if (args.optional === "true") {
        writeOutputs({ application_id: optionalContainerApplicationId(applications, name) });
        return;
      }
      writeOutputs({
        application_id: containerApplicationId(applications, name),
        image_digest: containerApplicationDigest(applications, name),
      });
      return;
    }

    case "cloudflare-applications": {
      const pages = await fetchContainerPages("");
      if (!pages.every(Array.isArray)) {
        throw new Error("Cloudflare Container application page is incomplete");
      }
      await writeFile(requireArg(args, "file"), JSON.stringify(pages.flat()));
      return;
    }

    case "image-release-prepare": {
      const response = await imageReleaseApi(
        requireArg(args, "maintenance-id"),
        "prepare",
      );
      if (response.maintenance_id !== args["maintenance-id"] || response.enabled !== true ||
          !["prepared", "deploying"].includes(response.phase)) {
        throw new Error("Salix did not confirm the image release fence");
      }
      return;
    }

    case "image-release-deploying": {
      const response = await imageReleaseApi(
        requireArg(args, "maintenance-id"),
        "deploying",
      );
      if (response.maintenance_id !== args["maintenance-id"] || response.phase !== "deploying") {
        throw new Error("Salix did not record image deployment start");
      }
      return;
    }

    case "image-release-drain": {
      await drainRunningContainers(
        requireArg(args, "maintenance-id"),
        requireArg(args, "application-id"),
        requireArg(args, "profile-key"),
      );
      return;
    }

    case "image-release-finish": {
      const result = await imageReleaseApi(
        requireArg(args, "maintenance-id"),
        "finish",
      );
      if (result.status !== "released" || result.maintenance_id !== args["maintenance-id"]) {
        throw new Error("Salix did not confirm image release fence removal");
      }
      return;
    }

    case "image-release-cancel": {
      const result = await imageReleaseApi(
        requireArg(args, "maintenance-id"),
        "cancel",
      );
      if (result.status !== "released" || result.maintenance_id !== args["maintenance-id"]) {
        throw new Error("Salix did not confirm pre-deploy fence removal");
      }
      return;
    }

    case "image-release-probe": {
      await probeImageContainer({
        baseUrl: requireArg(args, "base-url"),
        secret: process.env.SALIX_VM_GATEWAY_SECRET,
        maintenanceId: requireArg(args, "maintenance-id"),
        sourceRevision: requireArg(args, "source-revision"),
        profileKey: requireArg(args, "profile-key"),
        applicationId: requireArg(args, "application-id"),
      });
      return;
    }

    default:
      throw new Error(`Unknown command: ${command || "(missing)"}`);
  }
}

async function verifyHealthz({
  baseUrl,
  workerName,
  candidateId,
  gatewayBuildId,
  connectorImageVersion,
}) {
  let failures = [];
  for (
    let attempt = 1;
    attempt <= CANDIDATE_PROPAGATION_ATTEMPTS;
    attempt += 1
  ) {
    const response = await fetch(`${stripTrailingSlashes(baseUrl)}/healthz`, {
      headers: {
        "Cloudflare-Workers-Version-Key": `ci-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}`,
        "Cloudflare-Workers-Version-Overrides": `${workerName}="${candidateId}"`,
      },
    });
    if (!response.ok) {
      throw new Error(
        `Candidate smoke request failed with HTTP ${response.status}`,
      );
    }

    failures = validateHealthzPayload(await response.json(), {
      candidateId,
      gatewayBuildId,
      connectorImageVersion,
    });
    if (!failures.length) return;
    if (attempt < CANDIDATE_PROPAGATION_ATTEMPTS) {
      await new Promise((resolve) =>
        setTimeout(resolve, CANDIDATE_PROPAGATION_INTERVAL_MS),
      );
    }
  }

  throw new Error(`Candidate smoke failed: ${failures.join("; ")}`);
}

async function writeSalixRelease({
  configJson,
  candidateId,
  releaseId,
  releaseKind,
  imageRevision,
  imageDigest,
}) {
  const request = salixReleaseRequest(configJson, {
    candidateId,
    releaseId,
    releaseKind,
    imageRevision,
    imageDigest,
  });
  maskSecret(request.token);

  const response = await fetch(`${request.api}/v1/admin/vm/worker-release`, {
    method: "PUT",
    headers: {
      authorization: `Bearer ${request.token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(request.body),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(
      `Salix worker release request failed with HTTP ${response.status}: ${text}`,
    );
  }

  const payload = JSON.parse(text);
  if (payload.desired_worker_version_id !== candidateId) {
    throw new Error(
      "Salix worker release response did not confirm desired_worker_version_id",
    );
  }
  writeOutputs({ salix_api: request.api });
}

async function imageReleaseApi(maintenanceId, action, cursor = "", body = {}) {
  const config = JSON.parse(process.env.SALIX_CONFIG_JSON || "{}");
  const api = stripTrailingSlashes(config?.web?.api_base_url || "");
  const token = config?.web?.api_token || "";
  if (!api || !token) {
    throw new Error("SALIX_CONFIG_JSON requires web.api_base_url and web.api_token");
  }
  maskSecret(token);
  const path = `/v1/admin/vm/image-release/${action}`;
  const url = new URL(api + path);
  if (action === "workloads") {
    url.searchParams.set("maintenance_id", maintenanceId);
    url.searchParams.set("limit", "100");
    if (cursor) url.searchParams.set("cursor", cursor);
  }
  const response = await fetch(url, {
    method: ["workloads", "status"].includes(action) ? "GET" : "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body:
      ["workloads", "status"].includes(action)
        ? undefined
        : JSON.stringify({ maintenance_id: maintenanceId, ...body }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 500);
    throw new Error(`Salix image release ${action} returned HTTP ${response.status}: ${detail}`);
  }
  return response.json();
}

async function readSalixWorkerRelease() {
  const config = JSON.parse(process.env.SALIX_CONFIG_JSON || "{}");
  const api = stripTrailingSlashes(config?.web?.api_base_url || "");
  const token = config?.web?.api_token || "";
  if (!api || !token) {
    throw new Error("SALIX_CONFIG_JSON requires web.api_base_url and web.api_token");
  }
  maskSecret(token);
  const response = await fetch(`${api}/v1/admin/vm/worker-release`, {
    headers: { authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(`Salix worker release read returned HTTP ${response.status}`);
  }
  const result = await response.json();
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new Error("Salix worker release response is invalid");
  }
  return result;
}

async function probeImageContainer({ baseUrl, secret, maintenanceId, sourceRevision, profileKey, applicationId }) {
  if (!secret) throw new Error("SALIX_VM_GATEWAY_SECRET is required");
  maskSecret(secret);
  const sandboxId = imageProbeSandboxId(maintenanceId, profileKey);
  const basePath = imageProbePath(profileKey, sandboxId);
  let attempted = false;
  try {
    attempted = true;
    const ensured = await signedGatewayRequest(
      baseUrl,
      secret,
      "POST",
      `${basePath}/ensure`,
      { keep_alive: true },
    );
    if (!ensured.ok) {
      throw new Error(`Fresh Sandbox ensure returned HTTP ${ensured.status}`);
    }

    let confirmed = false;
    const deadline = Date.now() + 15 * 60_000;
    while (Date.now() < deadline) {
      const ready = await signedGatewayRequest(
        baseUrl,
        secret,
        "GET",
        `${basePath}/proxy/readyz`,
      );
      if (!ready.ok) {
        await new Promise((resolve) => setTimeout(resolve, 5_000));
        continue;
      }
      const readyBody = await ready.json();
      if (readyBody.connector_build_revision !== sourceRevision) {
        await new Promise((resolve) => setTimeout(resolve, 5_000));
        continue;
      }
      confirmed = true;
      break;
    }
    if (!confirmed) {
      throw new Error("Fresh Sandbox did not serve the expected Connector revision");
    }
  } finally {
    if (attempted) {
      const destroyed = await signedGatewayRequest(
        baseUrl,
        secret,
        "POST",
        `${basePath}/destroy`,
        {},
      );
      if (!destroyed.ok) {
        throw new Error(`Image probe Sandbox destroy returned HTTP ${destroyed.status}`);
      }
      await waitForProbeStop(applicationId, sandboxId);
    }
  }
}

function imageProbeSandboxId(maintenanceId, profileKey) {
  return `image-probe-${maintenanceId.replace(/[^a-zA-Z0-9_-]/g, "-").slice(0, 40)}-${profileKey}`;
}

function ownedImageProbeId(release, maintenanceId, profileKey) {
  return release?.enabled === true && release.reason === "sandbox_image_release" &&
    release.phase === "deploying" && release.maintenance_id === maintenanceId
    ? imageProbeSandboxId(maintenanceId, profileKey) : null;
}

function imageProbePath(profileKey, sandboxId) {
  const prefix = profileKey === "cf-standard-1"
    ? "/internal/v1/profiles/cf-standard-1/sandboxes"
    : profileKey === "cf-standard-2" ? "/internal/v1/sandboxes" : null;
  if (!prefix) throw new Error("Image probe profile is invalid");
  return `${prefix}/${sandboxId}`;
}

export async function recoverOwnedImageProbe(release, instances, {
  maintenanceId, applicationId, profileKey, baseUrl, secret,
}, request = signedGatewayRequest, wait = waitForProbeStop) {
  const sandboxId = ownedImageProbeId(release, maintenanceId, profileKey);
  if (!sandboxId) return false;
  if (probeStopped(instances, sandboxId)) return false;
  if (!secret) throw new Error("SALIX_VM_GATEWAY_SECRET is required");
  maskSecret(secret);
  const destroyed = await request(baseUrl, secret, "POST",
    `${imageProbePath(profileKey, sandboxId)}/destroy`, {});
  if (!destroyed.ok) {
    throw new Error(`Image probe Sandbox destroy returned HTTP ${destroyed.status}`);
  }
  await wait(applicationId, sandboxId);
  return true;
}

async function waitForProbeStop(applicationId, sandboxId) {
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    const pages = await fetchContainerPages(`/${encodeURIComponent(applicationId)}/instances`);
    const instances = flattenContainerInstances(pages);
    if (probeStopped(instances, sandboxId)) return;
    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }
  throw new Error(`Probe ${sandboxId} did not stop in its Container application`);
}

export function probeStopped(instances, sandboxId) {
  const matches = instances.filter((item) =>
    item.kind === "durable_object" && item.name === sandboxId);
  if (matches.length > 1) throw new Error(`Probe ${sandboxId} has duplicate owners`);
  return matches.length === 0 || ["inactive", "stopped"].includes(matches[0].state);
}

export function signedGatewayHeaders(secret, method, path, encoded, timestamp, nonce, requestId) {
  const bodyHash = createHash("sha256").update(encoded).digest("hex");
  const canonical = [method, path, timestamp, nonce, bodyHash].join("\n");
  const signature = `sha256=${createHmac("sha256", secret).update(canonical).digest("hex")}`;
  return {
    "content-type": "application/json",
    "x-salix-request-id": requestId,
    "x-salix-timestamp": timestamp,
    "x-salix-nonce": nonce,
    "x-salix-signature": signature,
  };
}

async function signedGatewayRequest(baseUrl, secret, method, path, body) {
  const encoded = method === "GET" ? "" : JSON.stringify(body);
  const timestamp = Math.floor(Date.now() / 1_000).toString();
  const nonce = randomBytes(16).toString("hex");
  const requestId = randomBytes(16).toString("hex");
  return fetch(stripTrailingSlashes(baseUrl) + path, {
    method,
    headers: signedGatewayHeaders(secret, method, path, encoded, timestamp, nonce, requestId),
    body: method === "GET" ? undefined : encoded,
    signal: AbortSignal.timeout(30_000),
  });
}

function* walkObjects(root) {
  if (!root || typeof root !== "object") return;
  if (Array.isArray(root)) {
    for (const item of root) yield* walkObjects(item);
    return;
  }

  yield root;
  for (const value of Object.values(root)) {
    yield* walkObjects(value);
  }
}

function normalizePercentage(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === "string") return Number(value.replace("%", ""));
  return Number(value);
}

function firstString(...values) {
  return values.find((value) => typeof value === "string" && value.length > 0);
}

function stripTrailingSlashes(value) {
  return String(value).replace(/\/+$/, "");
}

function assertReleaseKind(value) {
  if (!VALID_RELEASE_KINDS.has(value)) {
    throw new Error(`Invalid worker release kind: ${value}`);
  }
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) throw new Error(`Unexpected argument: ${arg}`);
    const key = arg.slice(2);
    const value = argv[i + 1];
    if (!value || value.startsWith("--"))
      throw new Error(`Missing value for --${key}`);
    args[key] = value;
    i += 1;
  }
  return args;
}

function requireArg(args, key) {
  const value = args[key];
  if (!value) throw new Error(`--${key} is required`);
  return value;
}

async function readEventPayload() {
  if (!process.env.GITHUB_EVENT_PATH) return {};
  return readJsonFile(process.env.GITHUB_EVENT_PATH);
}

async function readJsonFile(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

function writeOutputs(outputs) {
  for (const [key, value] of Object.entries(outputs)) {
    console.log(`${key}=${value}`);
    if (process.env.GITHUB_OUTPUT) {
      appendOutput(process.env.GITHUB_OUTPUT, key, value);
    }
  }
}

function appendOutput(path, key, value) {
  appendFileSync(path, `${key}=${value}\n`);
}

function maskSecret(value) {
  if (value) console.log(`::add-mask::${value}`);
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
