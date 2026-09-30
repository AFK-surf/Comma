import { describe, expect, test } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  checkImageReleasePage,
  containerApplicationDigest,
  containerApplicationId,
  optionalContainerApplicationId,
  probeStopped,
  recoverOwnedImageProbe,
  connectorImageVersionFromHealthz,
  findVersionIdByTag,
  findUploadedVersionId,
  inferWorkerReleaseKind,
  imageReleasePlan,
  sameSandboxRuntimeSources,
  fetchContainerPages,
  flattenContainerInstances,
  resolveActiveVersionId,
  resolveReleaseFacts,
  requireInactiveContainerInstances,
  runningContainerOwners,
  workloadsForApplication,
  salixReleaseRequest,
  signedGatewayHeaders,
  validateHealthzPayload,
} from "../scripts/release-ci.mjs";
import { signRequest } from "../src/auth";

describe("release CI helpers", () => {
  test("Worker-only changes reuse the Container image while Connector changes require release", () => {
    const root = mkdtempSync(join(tmpdir(), "comma-image-inputs-"));
    const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
    const write = (path, value) => {
      const target = join(root, path);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, value);
    };
    const commit = (message) => {
      git("add", ".");
      git("commit", "-qm", message);
      return git("rev-parse", "HEAD");
    };
    try {
      git("init", "-q");
      git("config", "user.email", "release-test@example.invalid");
      git("config", "user.name", "Release Test");
      write(".github/workflows/salix-vm-gateway-image.yml", "image job\n");
      write("systems/connector/salix-connect/main.go", "package main\n");
      const published = commit("published image");
      write("docs/release.md", "operator note\n");
      write("systems/connector/salix-connect/main_test.go", "package main\n");
      const docs = commit("docs and tests");
      expect(sameSandboxRuntimeSources(published, docs, root)).toBe(true);
      write("systems/cloudflare/salix-vm-gateway/src/index.ts", "export const worker = true;\n");
      write("systems/cloudflare/salix-vm-gateway/package.json", "{}\n");
      const worker = commit("Worker-only change");
      expect(sameSandboxRuntimeSources(published, worker, root)).toBe(true);
      write("systems/connector/salix-connect/main.go", "package main\n// runtime change\n");
      const runtime = commit("runtime change");
      expect(sameSandboxRuntimeSources(published, runtime, root)).toBe(false);
      write(".github/workflows/salix-vm-gateway-image.yml", "changed image job\n");
      const job = commit("image job change");
      expect(sameSandboxRuntimeSources(runtime, job, root)).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a same-run deploying fence resumes even after its image fact was recorded", () => {
    const current = {
      comma_source_revision: "a".repeat(40),
      last_sandbox_image_revision: "a".repeat(40),
    };
    const revision = current.last_sandbox_image_revision;
    expect(imageReleasePlan(current, revision, null, "release-1", true)).toBe("skip");
    const nextRevision = "c".repeat(40);
    expect(imageReleasePlan({ ...current, comma_source_revision: nextRevision },
      nextRevision, null, "release-1", true)).toBe("skip");
    expect(imageReleasePlan({ ...current, comma_source_revision: nextRevision },
      nextRevision, null, "release-1", false)).toBe("publish");
    expect(imageReleasePlan({ ...current, comma_source_revision: nextRevision },
      nextRevision, { enabled: true, maintenance_id: "release-1", phase: "deploying" },
      "release-1", true)).toBe("resume");
    expect(() => imageReleasePlan({ ...current, comma_source_revision: "c".repeat(40) },
      revision, null, "release-1", true)).toThrow("no longer serving");
    expect(() => imageReleasePlan({ ...current, comma_source_revision: null },
      revision, null, "release-1", true)).toThrow("did not report");
    expect(imageReleasePlan(current, revision, {
      enabled: true, maintenance_id: "release-1", phase: "deploying",
    }, "release-1", true)).toBe("resume");
    expect(imageReleasePlan(current, revision, {
      enabled: true, maintenance_id: "release-1", phase: "prepared",
    }, "release-1", true)).toBe("publish");
    expect(() => imageReleasePlan(current, revision, {
      enabled: true, maintenance_id: "release-2", phase: "deploying",
    }, "release-1", true)).toThrow("Another VM maintenance fence");
    expect(imageReleasePlan(current, revision, {
      enabled: true, maintenance_id: "release-2", phase: "deploying",
      reason: "sandbox_image_release",
    }, "release-1", true)).toBe("takeover");
    expect(imageReleasePlan(current, revision, {
      enabled: true, maintenance_id: "release-2", phase: "prepared",
      reason: "sandbox_image_release",
    }, "release-1", true)).toBe("takeover-prepared");
    expect(() => imageReleasePlan({ ...current, comma_source_revision: "c".repeat(40) },
      revision, { enabled: true, maintenance_id: "release-1", phase: "deploying" },
      "release-1", true)).toThrow("no longer serving");
  });

  test("Container inventory consumes every cursor and retains inactive instance rows", async () => {
    const requested = [];
    const pages = await fetchContainerPages("/id/instances", async (path, token) => {
      requested.push([path, token]);
      return token ? {
        result: { instances: [], durable_objects: [{ id: "stopped-do" }] },
        result_info: { next_page_token: null },
      } : {
        result: { instances: [{ id: "running", current_placement: { status: { container_status: "running" } } }], durable_objects: [] },
        result_info: { next_page_token: "next" },
      };
    });
    expect(requested).toEqual([["/id/instances", ""], ["/id/instances", "next"]]);
    expect(() => requireInactiveContainerInstances(flattenContainerInstances(pages))).toThrow("1 active or unknown Container instances remain");
    expect(() => requireInactiveContainerInstances(flattenContainerInstances([{
      instances: [], durable_objects: [{ id: "old-do" }, { id: "stopped-do" }],
    }]))).not.toThrow();
    expect(() => requireInactiveContainerInstances([
      { id: "unknown-do", kind: "durable_object", state: "starting" },
    ])).toThrow("1 active or unknown Container instances remain");
    await expect(fetchContainerPages("", async () => ({
      result: [], result_info: { next_page_token: "repeat" },
    }))).rejects.toThrow("cursor did not advance");
  });

  test("running instance maps to exactly one Group owner before archive", () => {
    const inventory = flattenContainerInstances([{
      instances: [{ id: "deployment-1", current_placement: { status: { container_status: "running" } } }],
      durable_objects: [{ id: "do-1", name: "salix-owned", deployment_id: "deployment-1" }],
    }]);
    const owner = { group_id: "group-one", provider: "cloudflare", resource_name: "salix-owned" };
    expect(runningContainerOwners(inventory, [owner])).toEqual([owner]);
    expect(() => runningContainerOwners(inventory, [])).toThrow("no Group Workload owner");
    expect(() => runningContainerOwners(inventory.filter((record) => record.kind === "instance"), [owner]))
      .toThrow("no exact Durable Object owner");
  });

  test("probe cleanup checks the exact application's Container state", () => {
    const active = flattenContainerInstances([{
      instances: [{ id: "running-probe", current_placement: { status: { container_status: "running" } } }],
      durable_objects: [{ name: "owned-probe", deployment_id: "running-probe" }],
    }]);
    expect(probeStopped(active, "owned-probe")).toBe(false);
    expect(probeStopped(active, "another-probe")).toBe(true);

    const stopped = flattenContainerInstances([{
      instances: [{ id: "stopped-probe", current_placement: { status: { container_status: "stopped" } } }],
      durable_objects: [{ name: "owned-probe", deployment_id: "stopped-probe" }],
    }]);
    expect(probeStopped(stopped, "owned-probe")).toBe(true);
  });

  test("a resumed release destroys only its running probe in the exact application", async () => {
    const maintenanceId = "release-1";
    const sandboxId = "image-probe-release-1-cf-standard-2";
    const active = flattenContainerInstances([{
      instances: [{ id: "probe-deployment", current_placement: { status: { container_status: "running" } } }],
      durable_objects: [{ name: sandboxId, deployment_id: "probe-deployment" }],
    }]);
    const context = {
      maintenanceId, applicationId: "app-standard-2", profileKey: "cf-standard-2",
      baseUrl: "https://gateway.example.test", secret: "test-secret",
    };
    const calls = [];
    const request = async (...args) => { calls.push(args); return { ok: true }; };
    const wait = async (...args) => { calls.push(args); };
    const release = {
      enabled: true, reason: "sandbox_image_release", phase: "deploying",
      maintenance_id: maintenanceId,
    };

    expect(() => runningContainerOwners(active, [])).toThrow("no Group Workload owner");
    expect(await recoverOwnedImageProbe(release, active, context, request, wait)).toBe(true);
    expect(calls).toEqual([
      [context.baseUrl, context.secret, "POST", `/internal/v1/sandboxes/${sandboxId}/destroy`, {}],
      [context.applicationId, sandboxId],
    ]);
    const stopped = flattenContainerInstances([{
      instances: [{ id: "probe-deployment", current_placement: { status: { container_status: "stopped" } } }],
      durable_objects: [{ name: sandboxId, deployment_id: "probe-deployment" }],
    }]);
    expect(() => requireInactiveContainerInstances(stopped)).toThrow("2 active or unknown");
    expect(() => requireInactiveContainerInstances(stopped, [], sandboxId)).not.toThrow();
    expect(await recoverOwnedImageProbe(release, stopped, context, request, wait)).toBe(false);
    calls.length = 0;
    expect(await recoverOwnedImageProbe({ ...release, phase: "prepared" }, active,
      context, request, wait)).toBe(false);
    expect(await recoverOwnedImageProbe({ ...release, maintenance_id: "another" }, active,
      context, request, wait)).toBe(false);
    expect(await recoverOwnedImageProbe(release, active,
      { ...context, profileKey: "cf-standard-1", applicationId: "app-standard-1" },
      request, wait)).toBe(false);
    expect(calls).toEqual([]);
  });

  test("release drain requires an owner for every running instance", () => {
    const inventory = flattenContainerInstances([{
      instances: ["old", "other", "business"].map((id) => ({
        id, current_placement: { status: { container_status: "running" } },
      })),
      durable_objects: [
        { name: "image-probe-sandbox-image-123-staging", deployment_id: "old" },
        { name: "image-probe-sandbox-image-456-stable", deployment_id: "other" },
        { name: "salix-business", deployment_id: "business" },
      ],
    }]);
    expect(() => runningContainerOwners(inventory, [])).toThrow("no Group Workload owner");
    expect(workloadsForApplication(inventory, [
      { provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-business", gateway_base_url: "https://other" },
      { provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-pending", gateway_base_url: "https://staging" },
      { provider: "cloudflare", profile_key: "cf-standard-1", resource_name: "salix-business", gateway_base_url: "https://staging" },
      { provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-other-environment", gateway_base_url: "https://other" },
      { provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-unresolved" },
    ], "https://staging/", "cf-standard-2")).toEqual([
      { provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-business", gateway_base_url: "https://other" },
      { provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-pending", gateway_base_url: "https://staging" },
      { provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-unresolved" },
    ]);
  });
  test("infers worker release kind from dispatch input and changed files", () => {
    expect(
      inferWorkerReleaseKind({
        inputs: { worker_release_kind: "breaking_protocol" },
      }),
    ).toBe("breaking_protocol");
    expect(
      inferWorkerReleaseKind({
        commits: [
          { modified: ["systems/cloudflare/salix-vm-gateway/Dockerfile"] },
        ],
      }),
    ).toBe("sandbox_image");
    expect(
      inferWorkerReleaseKind({
        commits: [{ modified: ["systems/connector/salix-connect/main.go"] }],
      }),
    ).toBe("breaking_connector");
    expect(
      inferWorkerReleaseKind({
        commits: [
          { modified: ["systems/cloudflare/salix-vm-gateway/src/app.ts"] },
        ],
      }),
    ).toBe("gateway_only");
  });

  test("resolves stable release metadata from GitHub facts", () => {
    expect(
      resolveReleaseFacts({
        event: {},
        sha: "1234567890abcdef",
        target: "staging",
        runId: "42",
        runAttempt: "3",
      }),
    ).toEqual({
      gateway_build_id: "1234567890ab",
      connector_image_version: "salix-connect-1234567890ab",
      tag: "ci-staging-42-3",
      worker_release_kind: "gateway_only",
      publish_mode: "candidate_worker",
    });

    expect(
      resolveReleaseFacts({
        event: {
          commits: [{ modified: ["systems/connector/salix-connect/main.go"] }],
        },
        sha: "1234567890abcdef",
        target: "staging",
        runId: "42",
        runAttempt: "3",
      }).publish_mode,
    ).toBe("check_only");

    expect(() =>
      resolveReleaseFacts({
        event: { inputs: { worker_release_kind: "sandbox_image" } },
        sha: "1234567890abcdef",
        target: "staging",
        runId: "42",
        runAttempt: "3",
        ref: "refs/heads/main",
      }),
    ).toThrow("Container release is blocked");

    expect(() =>
      resolveReleaseFacts({
        event: { inputs: { worker_release_kind: "sandbox_image" } },
        sha: "1234567890abcdef",
        target: "staging",
        runId: "42",
        runAttempt: "3",
        ref: "refs/heads/darksky/feature",
      }),
    ).toThrow("requires refs/heads/main");
  });

  test("finds active and uploaded versions from nested Wrangler payloads", () => {
    expect(
      resolveActiveVersionId({
        latest: {
          versions: [
            { versionId: "candidate", percentage: "0%" },
            { version_id: "active", percentage: "100%" },
          ],
        },
      }),
    ).toBe("active");

    expect(
      findVersionIdByTag(
        {
          result: {
            versions: [
              { id: "old", tag: "ci-old" },
              { version_id: "new", version_tag: "ci-target" },
            ],
          },
        },
        "ci-target",
      ),
    ).toBe("new");
  });

  test("keeps the active Container image identity for a Worker-only candidate", () => {
    expect(
      connectorImageVersionFromHealthz(
        {
          worker_version_id: "active",
          connector_image_version: "salix-connect-old",
        },
        "active",
      ),
    ).toBe("salix-connect-old");
    expect(() =>
      connectorImageVersionFromHealthz(
        {
          worker_version_id: "different",
          connector_image_version: "salix-connect-old",
        },
        "active",
      ),
    ).toThrow("Active Gateway version changed");
  });

  test("finds uploaded version id from wrangler upload output", () => {
    expect(
      findUploadedVersionId(`
      Uploaded salix-vm-gateway-staging (2.77 sec)
      Worker Version ID: 96939cf4-4ab4-4498-bd68-f39415cfb1d4
      To deploy this version to production traffic use the command wrangler versions deploy
    `),
    ).toBe("96939cf4-4ab4-4498-bd68-f39415cfb1d4");
  });

  test("validates healthz payload metadata", () => {
    expect(
      validateHealthzPayload(
        {
          worker_version_id: "version-1",
          gateway_build_id: "build-1",
          connector_image_version: "connector-1",
        },
        {
          candidateId: "version-1",
          gatewayBuildId: "build-1",
          connectorImageVersion: "connector-1",
        },
      ),
    ).toEqual([]);

    expect(
      validateHealthzPayload(
        {
          worker_version_id: "wrong",
          gateway_build_id: "build-1",
          connector_image_version: "connector-1",
        },
        {
          candidateId: "version-1",
          gatewayBuildId: "build-1",
          connectorImageVersion: "connector-1",
        },
      ),
    ).toHaveLength(1);
  });

  test("builds Salix release request from config JSON", () => {
    expect(
      salixReleaseRequest(
        JSON.stringify({
          web: {
            api_base_url: "https://salix.example.com///",
            api_token: "secret",
          },
        }),
        {
          candidateId: "version-1",
          releaseId: "ci-staging-42-3",
          releaseKind: "gateway_only",
        },
      ),
    ).toEqual({
      api: "https://salix.example.com",
      token: "secret",
      body: {
        desired_worker_version_id: "version-1",
        worker_release_id: "ci-staging-42-3",
        worker_release_kind: "gateway_only",
      },
    });
  });

  test("image release stops on unsettled starts and unprotected Container disks", () => {
    const digest = `sha256:${"a".repeat(64)}`;
    const applications = [
      { id: "unrelated", name: "another-app" },
      {
        id: "gateway-app",
        name: "salix-vm-gateway-staging-sandbox-staging",
        image: `registry.cloudflare.com/account/image@${digest}`,
      },
    ];
    expect(
      containerApplicationId(
        applications,
        "salix-vm-gateway-staging-sandbox-staging",
      ),
    ).toBe("gateway-app");
    expect(
      containerApplicationDigest(
        applications,
        "salix-vm-gateway-staging-sandbox-staging",
      ),
    ).toBe(digest);
    expect(optionalContainerApplicationId(
      applications,
      "salix-vm-gateway-staging-sandboxstandard1-staging",
    )).toBe("");
    expect(optionalContainerApplicationId([
      ...applications,
      { id: "new-app", name: "salix-vm-gateway-staging-sandboxstandard1-staging" },
    ], "salix-vm-gateway-staging-sandboxstandard1-staging")).toBe("new-app");

    expect(
      checkImageReleasePage({
        data: [{ group_id: "group-one", gateway_attempt_count: 0 }],
        next_cursor: "cursor-two",
      }),
    ).toBe("cursor-two");
    expect(() =>
      checkImageReleasePage({
        data: [{ group_id: "group-one", gateway_attempt_count: 1 }],
        next_cursor: null,
      }),
    ).toThrow("unsettled Gateway start");
    expect(() => checkImageReleasePage({
      data: [{ group_id: "group-one", provider: "cloudflare", profile_key: "cf-standard-2", resource_name: "salix-owned", status: "archiving", archive_recorded: false, gateway_attempt_count: 0 }],
      next_cursor: null,
    })).toThrow("unfinished archive");
    expect(() =>
      requireInactiveContainerInstances([{ id: "instance-one", kind: "instance", state: "inactive" }]),
    ).toThrow("1 active or unknown Container instances remain");
  });

  test("stopped Container needs one exact owner with a recorded archive", () => {
    const inventory = flattenContainerInstances([{
      instances: [{ id: "deployment-1", current_placement: { status: { health: "stopped" } } }],
      durable_objects: [],
    }, {
      instances: [],
      durable_objects: [{ id: "do-1", name: "salix-owned", deployment_id: "deployment-1" }],
    }]);
    const owner = { group_id: "group-one", provider: "cloudflare", resource_name: "salix-owned", status: "archived", archive_recorded: true };
    expect(runningContainerOwners(inventory, [owner])).toEqual([]);
    expect(() => requireInactiveContainerInstances(inventory, [owner])).not.toThrow();
    expect(() => requireInactiveContainerInstances(inventory, [{ ...owner, archive_recorded: false }]))
      .toThrow("2 active or unknown Container instances remain");
    const failed = flattenContainerInstances([{
      instances: [{ id: "deployment-failed", current_placement: { status: { container_status: "failed" } } }],
      durable_objects: [{ id: "do-failed", name: "salix-owned", deployment_id: "deployment-failed" }],
    }]);
    expect(() => requireInactiveContainerInstances(failed, [owner])).not.toThrow();
    expect(() => requireInactiveContainerInstances(flattenContainerInstances([{
      instances: [],
      durable_objects: [{ id: "orphan", name: "salix-owned", deployment_id: "missing" }],
    }]))).toThrow("1 active or unknown Container instances remain");
  });

  test("image probe signature matches Gateway authorization", async () => {
    const encoded = JSON.stringify({ operation: "probe-1", action: "status" });
    const path = "/internal/v1/sandboxes/probe-1/proxy/archive";
    const headers = signedGatewayHeaders(
      "test-secret",
      "POST",
      path,
      encoded,
      "1780000000",
      "nonce-one",
      "request-one",
    );
    const expected = await signRequest(
      "test-secret",
      "POST",
      path,
      "1780000000",
      "nonce-one",
      new TextEncoder().encode(encoded).buffer,
    );
    expect(headers["x-salix-signature"]).toBe(expected);
  });
});
