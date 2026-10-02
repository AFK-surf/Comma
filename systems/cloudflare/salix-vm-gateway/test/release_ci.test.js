import { describe, expect, test, vi } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  checkImageReleasePage,
  containerApplicationDigest,
  containerApplicationId,
  optionalContainerApplicationId,
  businessContainerInstances,
  probeImageContainer,
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
      let previous = docs;
      for (const path of [
        "systems/runtime-images/runtime-dependencies.lock.json",
        "systems/cloudflare/salix-vm-gateway/scripts/install-harnesses.mjs",
        "systems/cloudflare/salix-vm-gateway/scripts/build-connector.sh",
      ]) {
        write(path, "changed harness material\n");
        const revision = commit("update harness material");
        const sameSources = sameSandboxRuntimeSources(previous, revision, root);
        expect(imageReleasePlan({ comma_source_revision: revision }, revision, {}, "release-1", sameSources)).toBe("publish");
        expect(inferWorkerReleaseKind({ commits: [{ modified: [path] }] })).toBe("sandbox_image");
        previous = revision;
      }
      write("systems/cloudflare/salix-vm-gateway/src/index.ts", "export const worker = true;\n");
      write("systems/cloudflare/salix-vm-gateway/package.json", "{}\n");
      const worker = commit("Worker-only change");
      expect(sameSandboxRuntimeSources(previous, worker, root)).toBe(true);
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

  test("release drain waits only for Containers associated with business Workloads", () => {
    const businessName = "image-probe-sandbox-image-123-staging-cf-standard-2";
    const unrelated = ["image-probe-sandbox-image-36680743976-staging-cf-standard-2", "manual-test", "unknown-container"];
    const inventory = flattenContainerInstances([{
      instances: [businessName, ...unrelated].map((id) => ({
        id, current_placement: { status: { container_status: "running" } },
      })),
      durable_objects: [businessName, ...unrelated].map((name) => ({ name, deployment_id: name })),
    }]);
    const owner = { provider: "cloudflare", group_id: "business", resource_name: businessName };
    const business = businessContainerInstances(inventory, [owner]);
    expect(runningContainerOwners(business, [owner])).toEqual([owner]);
    expect(() => requireInactiveContainerInstances(business, [owner])).toThrow("active or unknown");
    expect(businessContainerInstances(inventory, [{ ...owner, provider: "sprites" }])).toEqual(business);
    const orphanOnly = businessContainerInstances(inventory, []);
    expect(runningContainerOwners(orphanOnly, [])).toEqual([]);
    expect(() => requireInactiveContainerInstances(orphanOnly)).not.toThrow();
  });

  test("business Containers still need a recorded archive and an exact instance owner", () => {
    const owner = { provider: "cloudflare", group_id: "business", resource_name: "salix-business" };
    const stopped = flattenContainerInstances([{
      instances: [{ id: "business", current_placement: { status: { container_status: "stopped" } } },
        { id: "orphan", current_placement: { status: { container_status: "running" } } }],
      durable_objects: [{ name: owner.resource_name, deployment_id: "business" }],
    }]);
    const business = businessContainerInstances(stopped, [owner]);
    expect(() => requireInactiveContainerInstances(business, [owner])).toThrow("active or unknown");
    expect(() => requireInactiveContainerInstances(business, [{ ...owner, archive_recorded: true }])).not.toThrow();
    const ambiguous = flattenContainerInstances([{
      instances: [{ id: "shared", current_placement: { status: { container_status: "running" } } }],
      durable_objects: [{ name: owner.resource_name, deployment_id: "shared" },
        { name: "manual-test", deployment_id: "shared" }],
    }]);
    expect(() => runningContainerOwners(businessContainerInstances(ambiguous, [owner]), [owner]))
      .toThrow("no exact Durable Object owner");
    const unknown = flattenContainerInstances([{
      instances: [], durable_objects: [{ name: owner.resource_name, deployment_id: "missing" }],
    }]);
    expect(() => requireInactiveContainerInstances(businessContainerInstances(unknown, [owner]), [owner]))
      .toThrow("active or unknown");
  });

  test("the release drain command ignores an unassociated running Container", () => {
    const root = mkdtempSync(join(tmpdir(), "comma-business-drain-"));
    const preload = join(root, "provider.mjs");
    writeFileSync(preload, `
      globalThis.fetch = async (input, options = {}) => {
        const url = new URL(input);
        console.log(JSON.stringify({ path: url.pathname, method: options.method || "GET" }));
        let payload;
        if (url.pathname.endsWith("/image-release/status")) {
          payload = { maintenance: { enabled: true, reason: "sandbox_image_release",
            phase: "prepared", maintenance_id: "sandbox-image-123-staging" } };
        } else if (url.pathname.endsWith("/image-release/workloads")) {
          payload = { data: [], next_cursor: null };
        } else if (url.pathname.endsWith("/applications/app-staging/instances")) {
          payload = { success: true, result_info: { next_page_token: null }, result: {
            instances: [{ id: "unrelated", current_placement: { status: { container_status: "running" } } }],
            durable_objects: [{ name: "manual-test-with-no-business", deployment_id: "unrelated" }],
          } };
        } else {
          throw new Error("Unexpected provider request: " + url.pathname);
        }
        return Response.json(payload);
      };
    `);
    try {
      const output = execFileSync(process.execPath, ["--import", preload,
        new URL("../scripts/release-ci.mjs", import.meta.url).pathname,
        "image-release-drain", "--maintenance-id", "sandbox-image-123-staging",
        "--application-id", "app-staging", "--profile-key", "cf-standard-2",
        "--deadline-ms", String(Date.now() + 75 * 60_000)], {
        encoding: "utf8", timeout: 10_000,
        env: { ...process.env, CLOUDFLARE_ACCOUNT_ID: "test-account", CLOUDFLARE_API_TOKEN: "test-token",
          SALIX_VM_GATEWAY_BASE_URL: "https://gateway.test", SALIX_VM_GATEWAY_SECRET: "test-secret",
          SALIX_CONFIG_JSON: JSON.stringify({ web: { api_base_url: "https://salix.test", api_token: "test-token" } }) },
      });
      const requests = output.split("\n").filter((line) => line.startsWith("{")).map((line) => JSON.parse(line));
      expect(requests).toEqual([
        { path: "/v1/admin/vm/image-release/workloads", method: "GET" },
        { path: "/client/v4/accounts/test-account/containers/dash/applications/app-staging/instances", method: "GET" },
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("a verified image probe disables keepAlive and does not wait for cleanup", async () => {
    const calls = [];
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      await probeImageContainer({
        baseUrl: "https://gateway.test", secret: "test-secret", profileKey: "cf-standard-2",
        maintenanceId: "sandbox-image-123-staging", sourceRevision: "a".repeat(40),
      }, async (...args) => {
        calls.push(args);
        const path = new URL(args[3], args[0]).pathname;
        if (path.endsWith("/keepalive")) throw new Error("request timeout");
        if (path.endsWith("/destroy")) return { ok: false, status: 500 };
        return { ok: true, json: async () => ({ status: "ready", connector_build_revision: "a".repeat(40) }) };
      });
      const action = (call) => new URL(call[3], call[0]).pathname.split("/").pop();
      expect(calls.map(action)).toEqual(["control", "ensure", "status", "readyz", "control", "keepalive", "destroy"]);
      expect(calls[4][4].action).toBe("seal");
      expect(calls[5][4]).toEqual({ keep_alive: false });
      expect(calls.every((call) => JSON.parse(new URL(call[3], call[0]).searchParams.get("salix_control")).owner_id === "sandbox-image-123-staging")).toBe(true);
      const failedRequest = vi.fn(async (...call) => action(call) === "ensure"
        ? { ok: false, status: 401 } : { ok: true });
      await expect(probeImageContainer({
        baseUrl: "https://gateway.test", secret: "test-secret", profileKey: "cf-standard-2",
        maintenanceId: "sandbox-image-456-staging", sourceRevision: "a".repeat(40),
      }, failedRequest)).rejects.toThrow("Fresh Sandbox ensure returned HTTP 401");
      expect(failedRequest.mock.calls.map(action))
        .toEqual(["control", "ensure", "control", "keepalive", "destroy"]);
    } finally {
      warning.mockRestore();
    }
  });

  test("an issued probe start waits for readiness after the first port refusal", async () => {
    const calls = [];
    await probeImageContainer({ baseUrl: "https://gateway.test", secret: "test-secret",
      profileKey: "cf-standard-1", maintenanceId: "release-cold-start", sourceRevision: "b".repeat(40) },
      async (...call) => {
        const action = new URL(call[3], call[0]).pathname.split("/").pop();
        calls.push(action);
        return action === "ensure" ? { ok: false, status: 503 } :
          { ok: true, json: async () => ({ status: "ready", connector_build_revision: "b".repeat(40) }) };
      });
    expect(calls).toEqual(["control", "ensure", "status", "readyz", "control", "keepalive", "destroy"]);
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
